//
//  WatchComplicationSnapshot.swift
//  Nicnark-2 Watch Widget
//
//  Lightweight snapshot the watch APP writes into the shared App Group, and the
//  complication (this widget extension) reads, since the extension has no data store of
//  its own and cannot reach WatchConnectivity. Keep this struct byte-identical to the copy
//  in the watch app target so the JSON round-trips.
//

import Foundation

struct WatchComplicationSnapshot: Codable {
    struct Point: Codable {
        let t: Date
        let level: Double
    }

    /// When the watch app last wrote this snapshot.
    var updatedAt: Date
    /// Current modeled nicotine in the bloodstream, mg.
    var currentLevel: Double
    /// Number of pouches currently in the mouth.
    var activePouchCount: Int
    /// Longest remaining active-pouch timer end (same policy as the iPhone Live Activity).
    var countdownEnd: Date?
    /// (time, level) samples including the near future, so the complication can show the
    /// level decaying on the watch face without the app being relaunched for every tick.
    var points: [Point]

    static let appGroupSuite = "group.ConnorNeedling.nicnark-2"
    static let defaultsKey = "watchComplicationSnapshot"

    enum CodingKeys: String, CodingKey {
        case updatedAt, currentLevel, activePouchCount, countdownEnd, points
        case soonestRemoval
    }

    init(
        updatedAt: Date,
        currentLevel: Double,
        activePouchCount: Int,
        countdownEnd: Date?,
        points: [Point]
    ) {
        self.updatedAt = updatedAt
        self.currentLevel = currentLevel
        self.activePouchCount = activePouchCount
        self.countdownEnd = countdownEnd
        self.points = points
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        currentLevel = try c.decode(Double.self, forKey: .currentLevel)
        activePouchCount = try c.decode(Int.self, forKey: .activePouchCount)
        countdownEnd = try c.decodeIfPresent(Date.self, forKey: .countdownEnd)
            ?? c.decodeIfPresent(Date.self, forKey: .soonestRemoval)
        points = try c.decode([Point].self, forKey: .points)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(currentLevel, forKey: .currentLevel)
        try c.encode(activePouchCount, forKey: .activePouchCount)
        try c.encodeIfPresent(countdownEnd, forKey: .countdownEnd)
        try c.encode(points, forKey: .points)
    }

    /// Reads the latest snapshot from the shared App Group, or nil if none has been written.
    static func load() -> WatchComplicationSnapshot? {
        guard let defaults = UserDefaults(suiteName: appGroupSuite),
              let data = defaults.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(WatchComplicationSnapshot.self, from: data)
    }

    /// Writes this snapshot to the shared App Group for the complication to read.
    func save() {
        guard let defaults = UserDefaults(suiteName: WatchComplicationSnapshot.appGroupSuite),
              let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: WatchComplicationSnapshot.defaultsKey)
    }
}
