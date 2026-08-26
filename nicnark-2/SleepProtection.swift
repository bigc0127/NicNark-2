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

        let absorption = AbsorptionConstants.shared
        var plannedContribution = 0.0

        for pouch in plannedPouches {
            let t = targetTime.timeIntervalSince(now)
            plannedContribution += absorption.calculatePlasmaLevel(
                nicotineContent: pouch.nicotineAmount,
                timeSinceInsertion: t,
                timeInMouth: min(max(0, t), pouch.duration),
                fullReleaseTime: pouch.duration
            )
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
