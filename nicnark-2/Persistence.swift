//
//  Persistence.swift
//  nicnark-2
//
//  Created by Connor Needling on 8/3/25.
//  Updated for CloudKit support with existing model
//

import CoreData
import CloudKit
import ActivityKit
import os.log

struct PersistenceController {
    static let shared = PersistenceController()
    private static let logger = Logger(subsystem: "com.nicnark.nicnark-2", category: "CloudKit")

    @MainActor
    static let preview: PersistenceController = {
        let result = PersistenceController(inMemory: true)
        let viewContext = result.container.viewContext

        // Sample data for previews using your existing model
        let samplePouch = PouchLog(context: viewContext)
        samplePouch.pouchId = UUID()
        samplePouch.insertionTime = Date()
        samplePouch.nicotineAmount = 3.0

        do {
            try viewContext.save()
        } catch {
            let nsError = error as NSError
            fatalError("Unresolved error \(nsError), \(nsError.userInfo)")
        }

        return result
    }()

    let container: NSPersistentCloudKitContainer

    init(inMemory: Bool = false) {
        container = NSPersistentCloudKitContainer(name: "nicnark_2")

        if inMemory {
            container.persistentStoreDescriptions.first!.url = URL(fileURLWithPath: "/dev/null")
        } else {
            // Configure the default store description for CloudKit
            guard let storeDescription = container.persistentStoreDescriptions.first else {
                fatalError("Failed to get store description")
            }
            
            // Use App Group container for shared access between app and widgets
            if let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.ConnorNeedling.nicnark-2") {
                let storeURL = groupURL.appendingPathComponent("nicnark_2.sqlite")
                storeDescription.url = storeURL
                print("📱 Using App Group container for Core Data store: \(storeURL.path)")
            } else {
                print("⚠️ App Group container not available, using default location")
            }
            
            // Enable CloudKit sync
            let cloudKitOptions = NSPersistentCloudKitContainerOptions(
                containerIdentifier: "iCloud.ConnorNeedling.nicnark-2"
            )
            storeDescription.cloudKitContainerOptions = cloudKitOptions
            
            // Enable history tracking and remote change notifications (required for CloudKit)
            storeDescription.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
            storeDescription.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
            
            print("📱 CloudKit store configured with App Group for widget access")
        }

        // Use a local reference to avoid capturing `self` in the escaping closure inside init
        let persistentContainer = container
        persistentContainer.loadPersistentStores { storeDescription, error in
            if let error = error as NSError? {
                // Log detailed CloudKit error information
                print("❌ Core Data CloudKit error: \(error), \(error.userInfo)")
print("📍 Store URL: \(storeDescription.url?.absoluteString ?? "Unknown")")
                print("🔧 Store Type: \(storeDescription.type)")
                if let cloudKitOptions = storeDescription.cloudKitContainerOptions {
                    print("☁️ CloudKit Container: \(cloudKitOptions.containerIdentifier)")
                }
                #if DEBUG
                fatalError("Unresolved error \(error), \(error.userInfo)")
                #endif
            } else {
                print("✅ Core Data CloudKit store loaded successfully")
                if let cloudKitOptions = storeDescription.cloudKitContainerOptions {
                    print("☁️ CloudKit sync enabled for container: \(cloudKitOptions.containerIdentifier)")
                }
                
                // Ensure CloudKit schema exists in development env so sync can begin
                #if DEBUG
                do {
                    try persistentContainer.initializeCloudKitSchema(options: [])
                    print("🧱 CloudKit schema initialized (or already present)")
                } catch {
                    print("⚠️ CloudKit schema initialization skipped/failed: \(error.localizedDescription)")
                }
                #endif
            }
        }

        // Context configuration
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy

        // Listen for remote changes (CloudKit merges)
        NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange,
            object: container.persistentStoreCoordinator,
            queue: .main
        ) { [weak container] _ in
            // Handle remote changes - trigger Live Activity sync
            Self.logger.info("📡 Remote CloudKit changes detected - syncing Live Activities")
            Task {
                await Self.handleRemoteChanges(container: container)
            }
        }
        
        // Check CloudKit account status on init
        Task.detached {
            await Self.checkCloudKitStatus()
        }
    }

    func save() {
        let context = container.viewContext
        if context.hasChanges {
            do {
                try context.save()
                print("✅ Core Data context saved successfully")
            } catch {
                let nsError = error as NSError
                print("❌ Core Data save error: \(nsError), \(nsError.userInfo)")
                print("❌ Save error details: \(nsError.localizedDescription)")
            }
        }
    }
    
    // MARK: - CloudKit Sync
    
    func triggerCloudKitSync() async {
        // Force a background context save to trigger CloudKit sync
        let backgroundContext = container.newBackgroundContext()
        await backgroundContext.perform {
            do {
                // Process any pending persistent history
                let historyRequest = NSPersistentHistoryChangeRequest.fetchHistory(after: .distantPast)
                _ = try backgroundContext.execute(historyRequest)
                
                // Save to trigger CloudKit operations
                if backgroundContext.hasChanges {
                    try backgroundContext.save()
                    print("✅ Background context saved - CloudKit sync triggered")
                } else {
                    // Even without changes, save to trigger sync
                    try backgroundContext.save()
                    print("✅ CloudKit sync triggered via background save")
                }
            } catch {
                print("❌ Failed to trigger CloudKit sync: \(error.localizedDescription)")
            }
        }
    }
    
    // MARK: - CloudKit Status Checking
    
    private static func checkCloudKitStatus() async {
        let cloudKitContainer = CKContainer(identifier: "iCloud.ConnorNeedling.nicnark-2")
        
        do {
            let accountStatus = try await cloudKitContainer.accountStatus()
            await MainActor.run {
                switch accountStatus {
                case .available:
                    Self.logger.info("✅ CloudKit account available - sync enabled")
                case .noAccount:
                    Self.logger.warning("⚠️ No iCloud account - sync disabled")
                case .restricted:
                    Self.logger.warning("⚠️ iCloud account restricted - sync disabled")
                case .couldNotDetermine:
                    Self.logger.warning("⚠️ Could not determine iCloud status")
                case .temporarilyUnavailable:
                    Self.logger.warning("⚠️ CloudKit temporarily unavailable")
                @unknown default:
                    Self.logger.warning("⚠️ Unknown iCloud account status")
                }
            }
        } catch {
            Self.logger.error("❌ Failed to check CloudKit status: \(error.localizedDescription, privacy: .public)")
        }
    }
    
    // MARK: - Remote Change Handling
    
    private static func handleRemoteChanges(container: NSPersistentCloudKitContainer?) async {
        guard let container = container else { return }
        // When CloudKit syncs new data, check for active pouches that need Live Activities
        await syncLiveActivitiesWithRemoteData(container: container)
    }
    
    private static func syncLiveActivitiesWithRemoteData(container: NSPersistentCloudKitContainer) async {
        await MainActor.run {
            let context = container.viewContext
            let fetchRequest: NSFetchRequest<PouchLog> = PouchLog.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "removalTime == nil")
            fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \PouchLog.insertionTime, ascending: false)]
            
            do {
                let activePouches = try context.fetch(fetchRequest)
                
                if #available(iOS 16.1, *) {
                    // Only sync Live Activities if we have exactly one active pouch
                    // Multiple active pouches shouldn't happen, but if they do, don't create activities
                    if activePouches.count == 1, let pouch = activePouches.first {
                        // Use stable UUID for cross-device identity
                        let pouchId = pouch.pouchId?.uuidString ?? pouch.objectID.uriRepresentation().absoluteString
                        
                        // Use the improved helper to check for existing activity
                        if !LiveActivityManager.activityExists(for: pouchId) {
                            // Check if this pouch was created recently (within last 5 seconds)
                            // If so, it's likely created locally and we shouldn't sync a Live Activity
                            let isRecentlyCreated = pouch.insertionTime.map { Date().timeIntervalSince($0) < 5 } ?? false
                            
                            if !isRecentlyCreated {
                                // Double-check pouch is still active before creating activity
                                Task {
                                    guard await LiveActivityManager.isPouchActive(pouchId) else {
                                        Self.logger.info("🚫 Pouch no longer active, skipping Live Activity sync")
                                        return
                                    }
                                    
                                    Self.logger.info("🔄 Starting Live Activity for synced pouch: \(pouchId, privacy: .public)")
                                    let success = await LiveActivityManager.startLiveActivity(
                                        for: pouchId,
                                        nicotineAmount: pouch.nicotineAmount,
                                        isFromSync: true
                                    )
                                    if success {
                                        Self.logger.info("✅ Live Activity started for synced pouch")
                                    } else {
                                        Self.logger.error("❌ Failed to start Live Activity for synced pouch")
                                    }
                                }
                            } else {
                                Self.logger.info("⏭️ Skipping Live Activity for recently created pouch (likely local)")
                            }
                        }
                    } else if activePouches.count > 1 {
                        Self.logger.warning("⚠️ Multiple active pouches detected (\(activePouches.count, privacy: .public)) - skipping Live Activity sync")
                    }
                    
                    // End Live Activities for pouches that were completed on other devices
                    for activity in Activity<PouchActivityAttributes>.activities {
                        let pouchId = activity.attributes.pouchId
                        
                        // Use Core Data guard to check if pouch is still active
                        Task {
                            let isStillActive = await LiveActivityManager.isPouchActive(pouchId)
                            if !isStillActive {
                                Self.logger.info("🔄 Ending Live Activity for completed pouch: \(pouchId, privacy: .public)")
                                await LiveActivityManager.endLiveActivity(for: pouchId)
                            }
                        }
                    }
                }
                
                Self.logger.info("🔄 Live Activity sync completed - \(activePouches.count, privacy: .public) active pouches")
                
            } catch {
                Self.logger.error("❌ Failed to fetch active pouches for sync: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
