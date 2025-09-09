//
//  NicotineCalculator+Widget.swift
//  AbsorptionTimerWidget (widget target)
//
//  This is a widget-local copy of the NicotineCalculator used in the main app.
//  It mirrors the API and logic exactly so the widget computes nicotine levels
//  consistently with the app without requiring cross-target file membership.
//
//  If you update the calculator in the app target, mirror the change here.
//

import Foundation
import CoreData
import os.log

// MARK: - Nicotine Calculator (widget copy)
class NicotineCalculator {
    private let logger = Logger(subsystem: "com.nicnark.nicnark-2", category: "NicotineCalculator")
    private let absorptionConstants = AbsorptionConstants.shared

    /// Calculates comprehensive nicotine levels including decay from removed pouches
    func calculateTotalNicotineLevel(context: NSManagedObjectContext, at timestamp: Date = Date()) async -> Double {
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

    // MARK: - Private helpers
    private func calculatePouchContribution(
        pouch: PouchLog,
        at timestamp: Date,
        insertionTime: Date
    ) -> Double {
        let nicotineContent = pouch.nicotineAmount
        let removalTime = pouch.removalTime ?? insertionTime.addingTimeInterval(FULL_RELEASE_TIME)

        if timestamp <= removalTime {
            // Absorption phase
            let timeInMouth = timestamp.timeIntervalSince(insertionTime)
            return absorptionConstants.calculateCurrentNicotineLevel(
                nicotineContent: nicotineContent,
                elapsedTime: max(0, timeInMouth)
            )
        } else {
            // Decay phase
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

