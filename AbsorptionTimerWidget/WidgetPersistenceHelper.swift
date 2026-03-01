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
    
    // MARK: Manual update methods for sync functionality
    
    public func setCurrentNicotineLevel(_ level: Double) {
        defaults?.set(level, forKey: Keys.currentLevel)
        defaults?.set(Date().timeIntervalSince1970, forKey: Keys.lastUpdated)
    }
    
    public func setActivityRunning(_ isRunning: Bool) {
        defaults?.set(isRunning, forKey: Keys.activityRunning)
    }
    
    public func updateSnapshot(level: Double, isRunning: Bool) {
        guard let d = defaults else { return }
        d.set(level, forKey: Keys.currentLevel)
        d.set(isRunning, forKey: Keys.activityRunning)
        d.set(Date().timeIntervalSince1970, forKey: Keys.lastUpdated)
    }
    
    // MARK: Capability checks
    // Check if Core Data store is actually accessible with data
    // Only return true if we can successfully read data from the store
    public func isCoreDataReadable() -> Bool {
        let context = backgroundContext()
        let request = PouchLog.fetchRequest()
        request.fetchLimit = 1
        
        do {
            // Try to fetch at least one record to verify store is accessible
            _ = try context.fetch(request)
            return true
        } catch {
            print("📱 Widget Core Data not readable: \(error.localizedDescription)")
            return false
        }
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
    private var _persistentContainer: NSPersistentContainer?
    
    private func createPersistentContainer() -> NSPersistentContainer {
        let container = NSPersistentCloudKitContainer(name: "nicnark_2")
        
        // Use App Group container for shared access between app and widgets
        guard let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.ConnorNeedling.nicnark-2") else {
            print("❌ Failed to get App Group container URL")
            return container
        }
        
        let storeURL = groupURL.appendingPathComponent("nicnark_2.sqlite")
        
        let description = NSPersistentStoreDescription(url: storeURL)
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        
        // CloudKit configuration for widgets
        description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(
            containerIdentifier: "iCloud.ConnorNeedling.nicnark-2"
        )
        
        // Configure for read-only access in widget to avoid conflicts
        description.setOption(true as NSNumber, forKey: NSReadOnlyPersistentStoreOption)
        
        // Set merge policy to handle CloudKit conflicts
        container.viewContext.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump
        container.viewContext.automaticallyMergesChangesFromParent = true
        
        container.persistentStoreDescriptions = [description]
        
        print("📱 Widget Core Data: Configuring with App Group CloudKit store URL: \(storeURL.path)")
        
        container.loadPersistentStores { storeDescription, error in
            if let error = error as NSError? {
                print("❌ Widget Core Data error: \(error), \(error.userInfo)")
            } else {
                print("✅ Widget Core Data loaded successfully from: \(storeDescription.url?.path ?? "unknown")")
            }
        }
        
        return container
    }
    
    private var persistentContainer: NSPersistentContainer {
        if let container = _persistentContainer {
            return container
        }
        let container = createPersistentContainer()
        _persistentContainer = container
        return container
    }
    
    public func backgroundContext() -> NSManagedObjectContext {
        return persistentContainer.newBackgroundContext()
    }
    
    public func getPersistentStoreCoordinator() -> NSPersistentStoreCoordinator {
        return persistentContainer.persistentStoreCoordinator
    }
}
