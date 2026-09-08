// NicotineCalculator.swift — see repo history for full header comments.
import Foundation
import CoreData
import os.log

struct NicotineLevelPoint {
    let timestamp: Date
    let level: Double
}

struct NicotineLevelProjection {
    let currentLevel: Double
    let projectedPoints: [NicotineLevelPoint]
    let lowBoundaryCrossing: Date?
    let highBoundaryCrossing: Date?
}

@MainActor
class NicotineCalculator {
    private let logger = Logger(subsystem: "com.nicnark.nicnark-2", category: "NicotineCalculator")
    private let absorptionConstants = AbsorptionConstants.shared

    func calculateTotalNicotineLevel(context: NSManagedObjectContext, at timestamp: Date = Date()) async -> Double {
        do {
            let pouches = try fetchRecentPouches(context: context, endingAt: timestamp)
            return levelFromPouches(pouches, at: timestamp)
        } catch {
            logger.error("Failed to calculate nicotine level: \(error.localizedDescription)")
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

    func levelFromPouches(_ pouches: [PouchLog], at timestamp: Date, lookbackFloor: Date? = nil) -> Double {
        let lookbackTime = lookbackFloor ?? timestamp.addingTimeInterval(-10 * 3600)
        var totalLevel = 0.0
        for pouch in pouches {
            guard let insertionTime = pouch.insertionTime else { continue }
            guard insertionTime >= lookbackTime else { continue }
            guard insertionTime <= timestamp else { continue }
            totalLevel += calculatePouchContribution(pouch: pouch, at: timestamp, insertionTime: insertionTime)
        }
        return max(0, totalLevel)
    }

    func projectNicotineLevels(
        context: NSManagedObjectContext,
        settings: NotificationSettings,
        startTime: Date = Date(),
        duration: TimeInterval = 10 * 3600
    ) async -> NicotineLevelProjection {
        let endTime = startTime.addingTimeInterval(duration)
        let sampleInterval: TimeInterval = 5 * 60
        var projectedPoints: [NicotineLevelPoint] = []
        var lowBoundaryCrossing: Date? = nil
        var highBoundaryCrossing: Date? = nil
        let lowBoundary = settings.effectiveLowBoundary
        let highBoundary = settings.effectiveHighBoundary
        let windowStart = startTime.addingTimeInterval(-10 * 3600)
        let windowRequest: NSFetchRequest<PouchLog> = PouchLog.fetchRequest()
        windowRequest.predicate = NSPredicate(format: "insertionTime >= %@", windowStart as NSDate)
        windowRequest.sortDescriptors = [NSSortDescriptor(keyPath: \PouchLog.insertionTime, ascending: true)]
        let windowPouches = (try? context.fetch(windowRequest)) ?? []
        var currentTime = startTime
        var previousLevel: Double?
        while currentTime <= endTime {
            let level = levelFromPouches(windowPouches, at: currentTime, lookbackFloor: windowStart)
            projectedPoints.append(NicotineLevelPoint(timestamp: currentTime, level: level))
            if let prevLevel = previousLevel {
                if lowBoundaryCrossing == nil && prevLevel > lowBoundary && level <= lowBoundary {
                    lowBoundaryCrossing = currentTime
                }
                if highBoundaryCrossing == nil && prevLevel <= highBoundary && level > highBoundary {
                    highBoundaryCrossing = currentTime
                }
            }
            previousLevel = level
            currentTime = currentTime.addingTimeInterval(sampleInterval)
        }
        return NicotineLevelProjection(
            currentLevel: projectedPoints.first?.level ?? 0,
            projectedPoints: projectedPoints,
            lowBoundaryCrossing: lowBoundaryCrossing,
            highBoundaryCrossing: highBoundaryCrossing
        )
    }

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
            fullReleaseTime: duration,
            absorptionFraction: pouch.absorptionFraction
        )
    }
}
