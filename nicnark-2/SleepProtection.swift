import Foundation
import CoreData

enum SleepProtectionKeys {
    static let enabled = "sleepProtectionEnabled"
    /// Seconds from midnight local time (0...86399)
    static let bedtimeSecondsFromMidnight = "sleepProtectionBedtimeSecondsFromMidnight"
    static let targetMg = "sleepProtectionTargetMg"
}

struct PlannedPouch {
    let nicotineAmount: Double
    let duration: TimeInterval

    init(nicotineAmount: Double, duration: TimeInterval) {
        self.nicotineAmount = nicotineAmount
        self.duration = duration
    }
}

enum SleepProtectionHelper {
    static func secondsFromMidnight(for date: Date, calendar: Calendar = .current) -> Int {
        let comps = calendar.dateComponents([.hour, .minute, .second], from: date)
        let h = comps.hour ?? 0
        let m = comps.minute ?? 0
        let s = comps.second ?? 0
        return max(0, min(86399, h * 3600 + m * 60 + s))
    }

    static func dateForTimePicker(secondsFromMidnight: Int, now: Date = .now, calendar: Calendar = .current) -> Date {
        let startOfDay = calendar.startOfDay(for: now)
        return startOfDay.addingTimeInterval(TimeInterval(max(0, min(86399, secondsFromMidnight))))
    }

    static func nextBedtimeDate(now: Date = .now, bedtimeSecondsFromMidnight: Int, calendar: Calendar = .current) -> Date {
        let startOfToday = calendar.startOfDay(for: now)
        let bedtimeToday = startOfToday.addingTimeInterval(TimeInterval(max(0, min(86399, bedtimeSecondsFromMidnight))))
        if now <= bedtimeToday {
            return bedtimeToday
        }
        return calendar.date(byAdding: .day, value: 1, to: bedtimeToday) ?? bedtimeToday.addingTimeInterval(24 * 3600)
    }
}

@MainActor
enum SleepProtectionAnalyzer {
    /// Predicts total nicotine level at a specific time, including planned pouches (assumed inserted at `now`).
    static func predictTotalLevel(
        context: NSManagedObjectContext,
        now: Date = .now,
        at targetTime: Date,
        plannedPouches: [PlannedPouch]
    ) async -> (time: Date, predictedLevel: Double, baselineLevel: Double) {
        // Baseline: whatever is already in the system (active + decaying pouches) at targetTime.
        let calculator = NicotineCalculator()
        let baseline = await calculator.calculateTotalNicotineLevel(context: context, at: targetTime)

        // Planned contributions: model each planned pouch with the same two-phase absorption/decay model.
        let absorption = AbsorptionConstants.shared
        var plannedContribution = 0.0

        for pouch in plannedPouches {
            let insertionTime = now
            let removalTime = insertionTime.addingTimeInterval(pouch.duration)

            if targetTime <= removalTime {
                // Still absorbing at targetTime.
                let elapsed = max(0, targetTime.timeIntervalSince(insertionTime))
                plannedContribution += absorption.calculateCurrentNicotineLevel(
                    nicotineContent: pouch.nicotineAmount,
                    elapsedTime: elapsed,
                    fullReleaseTime: pouch.duration
                )
            } else {
                // Fully absorbed (or removed) before targetTime; decay after removal.
                let totalAbsorbed = absorption.calculateAbsorbedNicotine(
                    nicotineContent: pouch.nicotineAmount,
                    useTime: pouch.duration,
                    fullReleaseTime: pouch.duration
                )
                let timeSinceRemoval = max(0, targetTime.timeIntervalSince(removalTime))
                plannedContribution += absorption.calculateDecayedNicotine(
                    initialLevel: totalAbsorbed,
                    timeSinceRemoval: timeSinceRemoval
                )
            }
        }

        return (time: targetTime, predictedLevel: max(0, baseline + plannedContribution), baselineLevel: max(0, baseline))
    }

    /// Predicts total nicotine level at the user's next bedtime, including the planned pouches (assumed inserted at `now`).
    static func predictTotalLevelAtNextBedtime(
        context: NSManagedObjectContext,
        now: Date = .now,
        bedtimeSecondsFromMidnight: Int,
        plannedPouches: [PlannedPouch]
    ) async -> (bedtime: Date, predictedLevel: Double, baselineLevel: Double) {
        let bedtime = SleepProtectionHelper.nextBedtimeDate(now: now, bedtimeSecondsFromMidnight: bedtimeSecondsFromMidnight)
        let result = await predictTotalLevel(context: context, now: now, at: bedtime, plannedPouches: plannedPouches)
        return (bedtime: bedtime, predictedLevel: result.predictedLevel, baselineLevel: result.baselineLevel)
    }
}
