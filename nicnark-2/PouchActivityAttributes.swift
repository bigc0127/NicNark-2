// PouchActivityAttributes.swift

import ActivityKit
import Foundation

@available(iOS 16.1, *)
struct PouchActivityAttributes: ActivityAttributes {

    struct ContentState: Codable, Hashable {
        // System-driven timer for smooth countdown/progress
        var timerInterval: ClosedRange<Date>

        // Values you want to refresh via pushes
        var currentNicotineLevel: Double
        var status: String
        var absorptionRate: Double
        var lastUpdated: Date

        init(
            timerInterval: ClosedRange<Date>,
            currentNicotineLevel: Double,
            status: String,
            absorptionRate: Double,
            lastUpdated: Date = Date()
        ) {
            self.timerInterval = timerInterval
            self.currentNicotineLevel = currentNicotineLevel
            self.status = status
            self.absorptionRate = absorptionRate
            self.lastUpdated = lastUpdated
        }
    }

    // Static attributes (unchanged for activity lifetime)
    let pouchName: String
    let totalNicotine: Double
    let startTime: Date
    let expectedDuration: TimeInterval
    let pouchId: String

    var endTime: Date {
        startTime.addingTimeInterval(expectedDuration)
    }

    init(
        pouchName: String,
        totalNicotine: Double,
        startTime: Date,
        expectedDuration: TimeInterval,
        pouchId: String
    ) {
        self.pouchName = pouchName
        self.totalNicotine = totalNicotine
        self.startTime = startTime
        self.expectedDuration = expectedDuration
        self.pouchId = pouchId
    }
}
