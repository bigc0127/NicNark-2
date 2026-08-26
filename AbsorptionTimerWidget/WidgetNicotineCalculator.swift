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

/// Absorption fraction — estimated ~30% of stated mg reaches the bloodstream (a conservative
/// product/population average, not an exact constant). Must match ABSORPTION_FRACTION in the
/// main app's AbsorptionConstants.swift. See NICOTINE_CALCULATION_FORMULA.md for the derivation.
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
        let duration = pouch.timerDuration > 0
            ? TimeInterval(pouch.timerDuration) * 60
            : WIDGET_FULL_RELEASE_TIME
        let t = timestamp.timeIntervalSince(insertionTime)
        let tMouth: TimeInterval
        if let removalTime = pouch.removalTime {
            tMouth = removalTime.timeIntervalSince(insertionTime)
        } else {
            tMouth = t
        }
        return calculatePlasmaLevel(
            nicotineContent: pouch.nicotineAmount,
            timeSinceInsertion: t,
            timeInMouth: tMouth,
            fullReleaseTime: duration
        )
    }

    /// Mirror of AbsorptionConstants.calculatePlasmaLevel (widget cannot import main-app types).
    private func calculatePlasmaLevel(
        nicotineContent: Double,
        timeSinceInsertion: TimeInterval,
        timeInMouth: TimeInterval,
        fullReleaseTime: TimeInterval
    ) -> Double {
        let t = max(0, timeSinceInsertion)
        let T = max(1, fullReleaseTime)
        let tMouth = min(max(0, timeInMouth), t)
        let tInput = min(tMouth, T)
        let deliverable = max(0, nicotineContent) * WIDGET_ABSORPTION_FRACTION
        guard deliverable > 0, tInput > 0 else { return 0 }

        let ke = log(2.0) / WIDGET_NICOTINE_HALF_LIFE
        let infusionRate = deliverable / T
        let levelAtInputEnd = (infusionRate / ke) * (1 - exp(-ke * tInput))
        let tAfterInput = t - tInput
        if tAfterInput <= 0 {
            return max(0, levelAtInputEnd)
        }
        return max(0, levelAtInputEnd * exp(-ke * tAfterInput))
    }
}
