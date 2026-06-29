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
    /// Earliest active pouch's modeled removal time — drives the active-pouch countdown.
    var soonestRemoval: Date?
    /// (time, level) samples including the near future, so the complication can show the
    /// level decaying on the watch face without the app being relaunched for every tick.
    var points: [Point]

    static let appGroupSuite = "group.ConnorNeedling.nicnark-2"
    static let defaultsKey = "watchComplicationSnapshot"

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
