//
//  NicotineCalculator.swift
//  nicnark-2
//
//  Comprehensive nicotine level calculator that properly handles:
//  - Active pouch absorption (linear model up to FULL_RELEASE_TIME)
//  - Post-removal decay (exponential decay with 2-hour half-life)
//  - Future projection for scheduling threshold-crossing notifications
//
//  This fixes the bug where nicotine-level-based reminders only considered
//  active pouches and didn't account for residual nicotine from previously
//  removed pouches that are still decaying in the bloodstream.
//

import Foundation
import CoreData
import os.log

// MARK: - Data Models

/// Represents a point in time with its corresponding nicotine level
struct NicotineLevelPoint {
    let timestamp: Date
    let level: Double
}

/// Result from nicotine level calculation and projection
struct NicotineLevelProjection {
    let currentLevel: Double
    let projectedPoints: [NicotineLevelPoint]
    let lowBoundaryCrossing: Date?
    let highBoundaryCrossing: Date?
}

// MARK: - Nicotine Calculator

/// Comprehensive nicotine level calculator that accounts for both active absorption and decay
@MainActor
class NicotineCalculator {
    private let logger = Logger(subsystem: "com.nicnark.nicnark-2", category: "NicotineCalculator")
    private let absorptionConstants = AbsorptionConstants.shared
    
    /// Calculates comprehensive nicotine levels including decay from removed pouches
    /// 
    /// Unlike the previous implementation that only considered active pouches, this method:
    /// 1. Fetches all pouches from the last 10 hours (5 half-lives for complete decay)
    /// 2. For each pouch, calculates contribution based on its phase:
    ///    - Absorption phase: linear absorption while pouch is in mouth
    ///    - Decay phase: exponential decay after pouch removal
    /// 3. Sums all contributions to get total current nicotine level
    ///
    /// - Parameters:
    ///   - context: Core Data context for fetching pouch logs
    ///   - timestamp: Point in time to calculate level for (defaults to now)
    /// - Returns: Total nicotine level in bloodstream at the specified time
    func calculateTotalNicotineLevel(context: NSManagedObjectContext, at timestamp: Date = Date()) async -> Double {
        // Fetch pouches from the last 10 hours (5 half-lives = 99.97% decay)
        let lookbackTime = timestamp.addingTimeInterval(-10 * 3600) // 10 hours
        
        let request: NSFetchRequest<PouchLog> = PouchLog.fetchRequest()
        request.predicate = NSPredicate(format: "insertionTime >= %@", lookbackTime as NSDate)
        request.sortDescriptors = [NSSortDescriptor(keyPath: \PouchLog.insertionTime, ascending: true)]
        
        do {
            let pouches = try context.fetch(request)
            var totalLevel = 0.0
            
            for pouch in pouches {
                guard let insertionTime = pouch.insertionTime else { continue }
                
                // Only consider pouches that were inserted before our calculation timestamp
                guard insertionTime <= timestamp else { continue }
                
                let contribution = calculatePouchContribution(
                    pouch: pouch,
                    at: timestamp,
                    insertionTime: insertionTime
                )
                totalLevel += contribution
                
                logger.debug("Pouch \(pouch.nicotineAmount)mg: contribution = \(String(format: "%.4f", contribution))mg")
            }
            
            logger.info("Total nicotine level at \(timestamp): \(String(format: "%.3f", totalLevel))mg from \(pouches.count) pouches")
            return max(0, totalLevel) // Ensure non-negative
            
        } catch {
            logger.error("Failed to calculate nicotine level: \(error.localizedDescription)")
            return 0
        }
    }
    
    /// Projects future nicotine levels and identifies boundary crossings
    ///
    /// This method samples nicotine levels every 5 minutes for the next 10 hours
    /// to find when the user's nicotine level will cross their target range boundaries.
    /// This enables scheduling notifications to fire exactly when thresholds are crossed.
    ///
    /// - Parameters:
    ///   - context: Core Data context
    ///   - settings: User's notification settings containing target range
    ///   - startTime: Starting time for projection (defaults to now)
    ///   - duration: How far into the future to project (defaults to 10 hours)
    /// - Returns: Projection results with current level and crossing times
    func projectNicotineLevels(
        context: NSManagedObjectContext,
        settings: NotificationSettings,
        startTime: Date = Date(),
        duration: TimeInterval = 10 * 3600 // 10 hours
    ) async -> NicotineLevelProjection {
        
        let endTime = startTime.addingTimeInterval(duration)
        let sampleInterval: TimeInterval = 5 * 60 // 5 minutes
        
        var projectedPoints: [NicotineLevelPoint] = []
        var lowBoundaryCrossing: Date? = nil
        var highBoundaryCrossing: Date? = nil
        
        let lowBoundary = settings.effectiveLowBoundary
        let highBoundary = settings.effectiveHighBoundary
        
        var currentTime = startTime
        var previousLevel: Double?
        
        while currentTime <= endTime {
            let level = await calculateTotalNicotineLevel(context: context, at: currentTime)
            projectedPoints.append(NicotineLevelPoint(timestamp: currentTime, level: level))
            
            // Check for boundary crossings
            if let prevLevel = previousLevel {
                // Crossing low boundary (going down)
                if lowBoundaryCrossing == nil && prevLevel > lowBoundary && level <= lowBoundary {
                    lowBoundaryCrossing = currentTime
                    logger.info("Projected low boundary crossing at \(currentTime): \(String(format: "%.3f", level))mg")
                }
                
                // Crossing high boundary (going up)
                if highBoundaryCrossing == nil && prevLevel <= highBoundary && level > highBoundary {
                    highBoundaryCrossing = currentTime
                    logger.info("Projected high boundary crossing at \(currentTime): \(String(format: "%.3f", level))mg")
                }
            }
            
            previousLevel = level
            currentTime = currentTime.addingTimeInterval(sampleInterval)
        }
        
        let currentLevel = projectedPoints.first?.level ?? 0
        
        return NicotineLevelProjection(
            currentLevel: currentLevel,
            projectedPoints: projectedPoints,
            lowBoundaryCrossing: lowBoundaryCrossing,
            highBoundaryCrossing: highBoundaryCrossing
        )
    }
    
    // MARK: - Private Helpers
    
    /// Calculates a single pouch's contribution to nicotine level at a specific time
    ///
    /// - Parameters:
    ///   - pouch: The pouch log entry
    ///   - timestamp: Point in time to calculate contribution for
    ///   - insertionTime: When the pouch was inserted
    /// - Returns: Nicotine contribution from this pouch in mg
    private func calculatePouchContribution(
        pouch: PouchLog,
        at timestamp: Date,
        insertionTime: Date
    ) -> Double {
        let nicotineContent = pouch.nicotineAmount
        
        // Determine when the pouch was/will be removed
        let removalTime = pouch.removalTime ?? insertionTime.addingTimeInterval(FULL_RELEASE_TIME)
        
        if timestamp <= removalTime {
            // ABSORPTION PHASE: Pouch is still in mouth at this timestamp
            let timeInMouth = timestamp.timeIntervalSince(insertionTime)
            return absorptionConstants.calculateCurrentNicotineLevel(
                nicotineContent: nicotineContent,
                elapsedTime: max(0, timeInMouth)
            )
        } else {
            // DECAY PHASE: Pouch was removed before this timestamp
            let actualTimeInMouth = removalTime.timeIntervalSince(insertionTime)
            let totalAbsorbed = absorptionConstants.calculateAbsorbedNicotine(
                nicotineContent: nicotineContent,
                useTime: actualTimeInMouth
            )
            
            let timeSinceRemoval = timestamp.timeIntervalSince(removalTime)
            return absorptionConstants.calculateDecayedNicotine(
                initialLevel: totalAbsorbed,
                timeSinceRemoval: timeSinceRemoval
            )
        }
    }
}
