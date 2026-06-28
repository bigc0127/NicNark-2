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

/// Dynamic absorption time based on user preference.
/// Read from the shared App Group suite (NOT UserDefaults.standard): the widget runs
/// in a separate process whose `.standard` domain is the extension's own and never
/// sees the user's setting. The app mirrors `selectedTimerDuration` into this suite
/// (see TimerSettings), so both processes agree.
private var WIDGET_FULL_RELEASE_TIME: TimeInterval {
    let groupDefaults = UserDefaults(suiteName: "group.ConnorNeedling.nicnark-2")
    let savedValue = groupDefaults?.integer(forKey: "selectedTimerDuration") ?? 0
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
        do {
            let pouches = try fetchRecentPouches(context: context, endingAt: timestamp)
            return levelFromPouches(pouches, at: timestamp)
        } catch {
            logger.error("[Widget] Failed to calculate nicotine level: \(error.localizedDescription)")
            return 0
        }
    }

    /// Fetches pouches that could still contribute nicotine at `timestamp` (inserted within
    /// the last 10 hours). Lets callers fetch ONCE and sample many points in memory.
    func fetchRecentPouches(context: NSManagedObjectContext, endingAt timestamp: Date = Date()) throws -> [PouchLog] {
        let lookbackTime = timestamp.addingTimeInterval(-10 * 3600)
        let request: NSFetchRequest<PouchLog> = PouchLog.fetchRequest()
        request.predicate = NSPredicate(format: "insertionTime >= %@", lookbackTime as NSDate)
        request.sortDescriptors = [NSSortDescriptor(keyPath: \PouchLog.insertionTime, ascending: true)]
        return try context.fetch(request)
    }

    /// Pure, fetch-free total-level computation from an already-fetched pouch array,
    /// applying the same 10-hour window as the single-shot path so a timeline can fetch
    /// once and sample every chart point in memory.
    func levelFromPouches(_ pouches: [PouchLog], at timestamp: Date) -> Double {
        let lookbackTime = timestamp.addingTimeInterval(-10 * 3600)
        var totalLevel = 0.0
        for pouch in pouches {
            guard let insertionTime = pouch.insertionTime else { continue }
            guard insertionTime >= lookbackTime else { continue }
            guard insertionTime <= timestamp else { continue }
            totalLevel += calculatePouchContribution(pouch: pouch, at: timestamp, insertionTime: insertionTime)
        }
        return max(0, totalLevel)
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
