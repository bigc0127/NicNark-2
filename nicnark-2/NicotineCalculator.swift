//
//  NicotineCalculator.swift
//  nicnark-2
//
//  Comprehensive nicotine level calculator that properly handles:
//  - Duration-limited zero-order input of A×D plus first-order elimination
//  - Decay after input stops (timer end or recorded removal)
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
        do {
            let pouches = try fetchRecentPouches(context: context, endingAt: timestamp)
            return levelFromPouches(pouches, at: timestamp)
        } catch {
            logger.error("Failed to calculate nicotine level: \(error.localizedDescription)")
            return 0
        }
    }

    /// Fetches pouches that could still contribute nicotine at `timestamp` — those inserted
    /// within the last 10 hours (≈5 half-lives = 99.97% decayed). Sorted ascending.
    func fetchRecentPouches(context: NSManagedObjectContext, endingAt timestamp: Date = Date()) throws -> [PouchLog] {
        let lookbackTime = timestamp.addingTimeInterval(-10 * 3600) // 10 hours
        let request: NSFetchRequest<PouchLog> = PouchLog.fetchRequest()
        request.predicate = NSPredicate(format: "insertionTime >= %@", lookbackTime as NSDate)
        request.sortDescriptors = [NSSortDescriptor(keyPath: \PouchLog.insertionTime, ascending: true)]
        return try context.fetch(request)
    }

    /// Pure, fetch-free computation of total bloodstream nicotine at `timestamp` from an
    /// already-fetched pouch array. Applies the SAME 10-hour lookback window that the
    /// single-shot fetch path uses, so callers can fetch ONCE and sample many timestamps
    /// in memory (projection/graph/watch loops) with byte-identical results — instead of
    /// re-fetching the same rows per sample point.
    ///
    /// `lookbackFloor` pins the lower bound of the contributing window. Leave it `nil`
    /// (default) to match the single-shot path (`timestamp - 10h`). Forward-projection
    /// callers that sample many future timestamps from one fetched set should pass a FIXED
    /// floor so a pouch isn't dropped from the sum as the sample time advances past its
    /// 10h age-out — that moving window injects a small downward step in the decay tail.
    func levelFromPouches(_ pouches: [PouchLog], at timestamp: Date, lookbackFloor: Date? = nil) -> Double {
        let lookbackTime = lookbackFloor ?? timestamp.addingTimeInterval(-10 * 3600)
        var totalLevel = 0.0
        for pouch in pouches {
            guard let insertionTime = pouch.insertionTime else { continue }
            // Same window + ordering guards as the single-shot fetch path.
            guard insertionTime >= lookbackTime else { continue }
            guard insertionTime <= timestamp else { continue }
            totalLevel += calculatePouchContribution(pouch: pouch, at: timestamp, insertionTime: insertionTime)
        }
        return max(0, totalLevel) // Ensure non-negative
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
        
        // Fetch the full window ONCE, then sample it in memory. Previously this loop called
        // calculateTotalNicotineLevel() per 5-min sample → ~121 identical Core Data fetches
        // on the main actor on every reschedule/slider tick. The window must start 10h before
        // the FIRST sample so early samples still see their full decay tail.
        let windowStart = startTime.addingTimeInterval(-10 * 3600)
        let windowRequest: NSFetchRequest<PouchLog> = PouchLog.fetchRequest()
        windowRequest.predicate = NSPredicate(format: "insertionTime >= %@", windowStart as NSDate)
        windowRequest.sortDescriptors = [NSSortDescriptor(keyPath: \PouchLog.insertionTime, ascending: true)]
        let windowPouches = (try? context.fetch(windowRequest)) ?? []

        var currentTime = startTime
        var previousLevel: Double?

        while currentTime <= endTime {
            // Pin the floor to windowStart so the SAME pouch set contributes at every
            // sample. windowPouches were fetched with `insertionTime >= windowStart`, so
            // only the `insertionTime <= currentTime` guard governs and no pouch is ever
            // dropped mid-projection — preventing a spurious downward step that could
            // latch a false low-boundary crossing.
            let level = levelFromPouches(windowPouches, at: currentTime, lookbackFloor: windowStart)
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
    
    /// One pouch's plasma contribution at `timestamp`.
    /// Zero-order input of A×D over the pouch timer + first-order elimination throughout.
    /// Input stops at min(time in mouth, timer); after that only ke applies — including
    /// still-in-mouth after the timer (empty pouch, liver still clearing).
    private func calculatePouchContribution(
        pouch: PouchLog,
        at timestamp: Date,
        insertionTime: Date
    ) -> Double {
        let duration = pouch.timerDuration > 0
            ? TimeInterval(pouch.timerDuration) * 60
            : FULL_RELEASE_TIME
        let t = timestamp.timeIntervalSince(insertionTime)
        let tMouth: TimeInterval
        if let removalTime = pouch.removalTime {
            tMouth = removalTime.timeIntervalSince(insertionTime)
        } else {
            tMouth = t
        }
        return absorptionConstants.calculatePlasmaLevel(
            nicotineContent: pouch.nicotineAmount,
            timeSinceInsertion: t,
            timeInMouth: tMouth,
            fullReleaseTime: duration
        )
    }
}
