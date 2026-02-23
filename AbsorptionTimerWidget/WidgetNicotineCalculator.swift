//
//  WidgetNicotineCalculator.swift
//  nicnark-2
//
//  Widget-specific nicotine calculator that mirrors the exact logic from the main app's
//  NicotineCalculator without complex dependencies like NotificationSettings.
//
//  This ensures the widget and main app show identical nicotine levels while keeping
//  the widget target self-contained and buildable.
//

import Foundation
import CoreData
import os.log

// MARK: - Widget Constants (mirrored from main app)

/// Absorption fraction - 30% of nicotine gets absorbed
private let WIDGET_ABSORPTION_FRACTION: Double = 0.30

/// Dynamic absorption time based on user preference
private var WIDGET_FULL_RELEASE_TIME: TimeInterval {
    let savedValue = UserDefaults.standard.integer(forKey: "selectedTimerDuration")
    switch savedValue {
    case 45: return 45 * 60  // 45 minutes in seconds
    case 60: return 60 * 60  // 60 minutes in seconds
    default: return 30 * 60  // 30 minutes in seconds (default)
    }
}

/// Nicotine half-life: 2 hours for decay calculations
private let WIDGET_NICOTINE_HALF_LIFE: TimeInterval = 2 * 3600

// MARK: - Widget Nicotine Calculator

/// Simplified nicotine calculator for widget use that mirrors main app calculations exactly
class WidgetNicotineCalculator {
    private let logger = Logger(subsystem: "com.nicnark.nicnark-2", category: "WidgetNicotineCalculator")
    
    /// Calculates comprehensive nicotine levels including decay from removed pouches
    /// This mirrors NicotineCalculator.calculateTotalNicotineLevel() exactly
    func calculateTotalNicotineLevel(context: NSManagedObjectContext, at timestamp: Date = Date()) -> Double {
        // Fetch pouches from the last 10 hours (≈5 half-lives)
        let lookbackTime = timestamp.addingTimeInterval(-10 * 3600)
        
        let request: NSFetchRequest<PouchLog> = PouchLog.fetchRequest()
        request.predicate = NSPredicate(format: "insertionTime >= %@", lookbackTime as NSDate)
        request.sortDescriptors = [NSSortDescriptor(keyPath: \PouchLog.insertionTime, ascending: true)]
        
        do {
            let pouches = try context.fetch(request)
            var totalLevel = 0.0
            
            for pouch in pouches {
                guard let insertionTime = pouch.insertionTime else { continue }
                guard insertionTime <= timestamp else { continue }
                
                let contribution = calculatePouchContribution(
                    pouch: pouch,
                    at: timestamp,
                    insertionTime: insertionTime
                )
                totalLevel += contribution
                logger.debug("[Widget] Pouch \(pouch.nicotineAmount)mg -> +\(String(format: "%.4f", contribution))mg")
            }
            
            logger.info("[Widget] Total nicotine at \(timestamp): \(String(format: "%.3f", totalLevel))mg from \(pouches.count) pouches")
            return max(0, totalLevel)
        } catch {
            logger.error("[Widget] Failed to calculate nicotine level: \(error.localizedDescription)")
            return 0
        }
    }
    
    // MARK: - Private helpers (mirrored from main app)
    
    private func calculatePouchContribution(
        pouch: PouchLog,
        at timestamp: Date,
        insertionTime: Date
    ) -> Double {
        let nicotineContent = pouch.nicotineAmount
        let duration = pouch.timerDuration > 0
            ? TimeInterval(pouch.timerDuration) * 60
            : WIDGET_FULL_RELEASE_TIME
        let modeledRemovalTime = insertionTime.addingTimeInterval(duration)
        let removalTime = pouch.removalTime ?? modeledRemovalTime
        
        if timestamp <= removalTime {
            // Absorption phase
            let timeInMouth = timestamp.timeIntervalSince(insertionTime)
            return calculateCurrentNicotineLevel(
                nicotineContent: nicotineContent,
                elapsedTime: max(0, timeInMouth),
                fullReleaseTime: duration
            )
        } else {
            // Decay phase
            let actualTimeInMouth = removalTime.timeIntervalSince(insertionTime)
            let totalAbsorbed = calculateAbsorbedNicotine(
                nicotineContent: nicotineContent,
                useTime: actualTimeInMouth,
                fullReleaseTime: duration
            )
            let timeSinceRemoval = timestamp.timeIntervalSince(removalTime)
            return calculateDecayedNicotine(
                initialLevel: totalAbsorbed,
                timeSinceRemoval: timeSinceRemoval
            )
        }
    }
    
    private func calculateAbsorbedNicotine(nicotineContent: Double, useTime: TimeInterval, fullReleaseTime: TimeInterval) -> Double {
        let release = max(1, fullReleaseTime)
        let fractionalTime = useTime / release
        let absorbedFraction = min(WIDGET_ABSORPTION_FRACTION * fractionalTime, WIDGET_ABSORPTION_FRACTION)
        return nicotineContent * absorbedFraction
    }
    
    private func calculateCurrentNicotineLevel(nicotineContent: Double, elapsedTime: TimeInterval, fullReleaseTime: TimeInterval) -> Double {
        return calculateAbsorbedNicotine(nicotineContent: nicotineContent, useTime: elapsedTime, fullReleaseTime: fullReleaseTime)
    }
    
    /**
     * Calculates nicotine decay after pouch removal using half-life formula.
     * 
     * Formula: N_i(t) = absorbed × 0.5^((t-t_i)/T_1/2)
     * Where:
     * - absorbed = initial nicotine level at removal (mg)
     * - t - t_i = elapsed time since pouch removal (in seconds)
     * - T_1/2 = nicotine half-life (7200 seconds = 2 hours)
     * 
     * This matches the formula in AbsorptionConstants.calculateDecayedNicotine
     * to ensure widget and main app show identical levels.
     */
    private func calculateDecayedNicotine(initialLevel: Double, timeSinceRemoval: TimeInterval) -> Double {
        // Using pow(0.5, x) form to match published scientific model
        let decayFactor = pow(0.5, timeSinceRemoval / WIDGET_NICOTINE_HALF_LIFE)
        return initialLevel * decayFactor
    }
}
