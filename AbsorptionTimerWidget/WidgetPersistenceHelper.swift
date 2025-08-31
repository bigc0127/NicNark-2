// WidgetPersistenceHelper.swift

import Foundation
import CoreData

// Shared lightweight point for charts
public struct WidgetNicotinePoint: Identifiable, Hashable {
    public let id = UUID()
    public let time: Date
    public let level: Double
    public init(time: Date, level: Double) {
        self.time = time
        self.level = level
    }
}

/// Bridge between app/live activity and widget using App Group UserDefaults.
/// Keep App Group in sync with your project capabilities.
public final class WidgetPersistenceHelper {
    private let defaults = UserDefaults(suiteName: "group.ConnorNeedling.nicnark-2")

    private enum Keys {
        static let currentLevel = "snapshot.currentLevel"
        static let peakLevel = "snapshot.peakLevel"
        static let lastUpdated = "snapshot.lastUpdated"
        static let activityRunning = "snapshot.activityRunning"
        static let activityPouchName = "snapshot.activityPouchName"
        static let activityEnd = "snapshot.activityEnd"
    }

    public init() {}

    // MARK: Setters (call from app/live activity)
    public func setFromLiveActivity(level: Double, peak: Double?, pouchName: String?, endTime: Date?) {
        guard let d = defaults else { return }
        d.set(level, forKey: Keys.currentLevel)
        if let peak { d.set(peak, forKey: Keys.peakLevel) }
        d.set(true, forKey: Keys.activityRunning)
        if let pouchName { d.set(pouchName, forKey: Keys.activityPouchName) }
        if let endTime { d.set(endTime.timeIntervalSince1970, forKey: Keys.activityEnd) }
        d.set(Date().timeIntervalSince1970, forKey: Keys.lastUpdated)
    }

    public func markActivityEnded() {
        guard let d = defaults else { return }
        d.set(false, forKey: Keys.activityRunning)
        d.set(Date().timeIntervalSince1970, forKey: Keys.lastUpdated)
    }

    // MARK: Getters (read in widget)
    public func isActivityRunning() -> Bool {
        defaults?.bool(forKey: Keys.activityRunning) ?? false
    }

    public func getSnapshotCurrent() -> Double {
        defaults?.double(forKey: Keys.currentLevel) ?? 0
    }

    public func getSnapshotPeak() -> Double {
        defaults?.double(forKey: Keys.peakLevel) ?? 0
    }

    public func getSnapshotEndTime() -> Date? {
        guard let ts = defaults?.double(forKey: Keys.activityEnd), ts > 0 else { return nil }
        return Date(timeIntervalSince1970: ts)
    }

    public func getSnapshotPouchName() -> String? {
        defaults?.string(forKey: Keys.activityPouchName)
    }

    public func getSnapshotLastUpdated() -> Date? {
        guard let ts = defaults?.double(forKey: Keys.lastUpdated), ts > 0 else { return nil }
        return Date(timeIntervalSince1970: ts)
    }

    // MARK: Fallback computations for widget (safe defaults)
    public func getCurrentNicotineLevel() -> Double {
        return getSnapshotCurrent()
    }

    public func getPeakNicotineLevel() -> Double {
        let peak = getSnapshotPeak()
        return peak > 0 ? peak : getSnapshotCurrent()
    }

    public func generateNicotineDataPoints(hours: Int, intervalMinutes: Int) -> [WidgetNicotinePoint] {
        let now = Date()
        let count = max(1, (hours * 60) / max(1, intervalMinutes))
        return (0..<count).map { i in
            let t = now.addingTimeInterval(Double(-i * intervalMinutes) * 60)
            return WidgetNicotinePoint(time: t, level: max(0, getCurrentNicotineLevel() - Double(i) * 0.01))
        }.reversed()
    }
    
    // MARK: Core Data Support for Widgets
    private lazy var persistentContainer: NSPersistentContainer = {
        let container = NSPersistentContainer(name: "nicnark_2")
        
        // Use the App Group container URL for shared data
        guard let storeURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.ConnorNeedling.nicnark-2")?.appendingPathComponent("nicnark_2.sqlite") else {
            print("❌ Widget Core Data: Failed to get App Group container URL")
            return container
        }
        
        let description = NSPersistentStoreDescription(url: storeURL)
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        
        // Configure for read-only access in widget to avoid conflicts
        description.setOption(true as NSNumber, forKey: NSReadOnlyPersistentStoreOption)
        
        container.persistentStoreDescriptions = [description]
        
        container.loadPersistentStores { _, error in
            if let error = error as NSError? {
                print("❌ Widget Core Data error: \(error), \(error.userInfo)")
            } else {
                print("✅ Widget Core Data loaded successfully from: \(storeURL.path)")
            }
        }
        return container
    }
    
    public func backgroundContext() -> NSManagedObjectContext {
        return persistentContainer.newBackgroundContext()
    }
}
