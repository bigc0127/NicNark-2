import Foundation
import CoreData
import os.log

private let WIDGET_ABSORPTION_FRACTION: Double = 0.30

private func widgetAbsorptionFraction(forBrand brand: String?) -> Double {
    guard let raw = brand?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else {
        return WIDGET_ABSORPTION_FRACTION
    }
    let cleaned = raw
        .replacingOccurrences(of: "\u00ae", with: "")
        .replacingOccurrences(of: "\u2122", with: "")
        .replacingOccurrences(of: "+", with: " plus ")
        .replacingOccurrences(of: "-", with: " ")
        .replacingOccurrences(of: "_", with: " ")
    let key = cleaned.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "!" }).joined(separator: " ")
    if key.contains("zyn ultra") || key.contains("zynultra") { return 0.32 }
    if key.contains("velo plus") || key.contains("veloplus") { return 0.30 }
    if key.contains("on plus") || key.contains("on! plus") || key.contains("onplus") { return 0.34 }
    if key == "zyn" || key.hasPrefix("zyn ") { return 0.38 }
    if key == "velo" || key.hasPrefix("velo ") { return 0.24 }
    if key == "fre" || key.hasPrefix("fre ") { return 0.36 }
    if key == "alp" || key.hasPrefix("alp ") { return 0.34 }
    if key == "clue" || key.hasPrefix("clue ") { return 0.33 }
    if key == "on" || key == "on!" || key.hasPrefix("on ") || key.hasPrefix("on! ") { return 0.42 }
    return WIDGET_ABSORPTION_FRACTION
}

private var WIDGET_FULL_RELEASE_TIME: TimeInterval {
    let groupDefaults = UserDefaults(suiteName: "group.ConnorNeedling.nicnark-2")
    let savedValue = groupDefaults?.integer(forKey: "selectedTimerDuration") ?? 0
    switch savedValue {
    case 45: return 45 * 60
    case 60: return 60 * 60
    default: return 30 * 60
    }
}

private let WIDGET_NICOTINE_HALF_LIFE: TimeInterval = 2 * 3600

class WidgetNicotineCalculator {
    private let logger = Logger(subsystem: "com.nicnark.nicnark-2", category: "WidgetNicotineCalculator")

    func calculateTotalNicotineLevel(context: NSManagedObjectContext, at timestamp: Date = Date()) -> Double {
        do {
            let pouches = try fetchRecentPouches(context: context, endingAt: timestamp)
            return levelFromPouches(pouches, at: timestamp)
        } catch {
            logger.error("[Widget] Failed to calculate nicotine level: \(error.localizedDescription)")
            return 0
        }
    }

    func fetchRecentPouches(context: NSManagedObjectContext, endingAt timestamp: Date = Date()) throws -> [PouchLog] {
        let lookbackTime = timestamp.addingTimeInterval(-10 * 3600)
        let request: NSFetchRequest<PouchLog> = PouchLog.fetchRequest()
        request.predicate = NSPredicate(format: "insertionTime >= %@", lookbackTime as NSDate)
        request.sortDescriptors = [NSSortDescriptor(keyPath: \PouchLog.insertionTime, ascending: true)]
        return try context.fetch(request)
    }

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
            fullReleaseTime: duration,
            absorptionFraction: widgetAbsorptionFraction(forBrand: pouch.can?.brand)
        )
    }

    private func calculatePlasmaLevel(
        nicotineContent: Double,
        timeSinceInsertion: TimeInterval,
        timeInMouth: TimeInterval,
        fullReleaseTime: TimeInterval,
        absorptionFraction: Double = WIDGET_ABSORPTION_FRACTION
    ) -> Double {
        let t = max(0, timeSinceInsertion)
        let T = max(1, fullReleaseTime)
        let tMouth = min(max(0, timeInMouth), t)
        let tInput = min(tMouth, T)
        let deliverable = max(0, nicotineContent) * max(0, absorptionFraction)
        guard deliverable > 0, tInput > 0 else { return 0 }
        let ke = log(2.0) / WIDGET_NICOTINE_HALF_LIFE
        let infusionRate = deliverable / T
        let levelAtInputEnd = (infusionRate / ke) * (1 - exp(-ke * tInput))
        let tAfterInput = t - tInput
        if tAfterInput <= 0 { return max(0, levelAtInputEnd) }
        return max(0, levelAtInputEnd * exp(-ke * tAfterInput))
    }
}
