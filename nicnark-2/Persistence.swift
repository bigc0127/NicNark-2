//
//  Persistence.swift
//  nicnark-2
//
//  Created by Connor Needling on 8/3/25.
//  Updated for CloudKit support with existing model
//

import CoreData
import CloudKit
import os.log

/**
 A thin wrapper around NSPersistentCloudKitContainer that configures:
 - Core Data with CloudKit sync (automatic history tracking + remote change notifications)
 - App Group storage so the main app and widgets share the same SQLite store
 - Basic CloudKit account/status checks and logging for easier debugging
 - Live Activity syncing (iOS 16.1+) in response to remote CloudKit changes

 This controller exposes a shared singleton for app-wide access and a preview instance for SwiftUI previews.
 */
struct PersistenceController {
    /// Shared singleton instance used by the running app.
    static let shared = PersistenceController()
    /// Logger for CloudKit-related messages.
    nonisolated static let logger = Logger(subsystem: "com.nicnark.nicnark-2", category: "CloudKit")

@MainActor
    /// An in-memory PersistenceController for SwiftUI previews and tests.
    /// Populated with a single sample PouchLog so UI has realistic data.
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

/// The Core Data container backed by CloudKit (via NSPersistentCloudKitContainer).
    /// This is configured to store data in the app group so widgets can access the same database.
    let container: NSPersistentCloudKitContainer

/// Initializes the Core Data + CloudKit stack.
    /// - Parameter inMemory: When true, uses an in-memory store (useful for previews/tests).
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
            
            #if os(iOS)
            // Keep the SQLite store accessible while the device is locked.
            // This is important for background tasks, Live Activities, and widgets.
            storeDescription.setOption(
                FileProtectionType.completeUntilFirstUserAuthentication as NSObject,
                forKey: NSPersistentStoreFileProtectionKey
            )
            #endif
            
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
                
                #if os(iOS)
                if let url = storeDescription.url {
                    Self.ensureSQLiteStoreIsAccessibleWhileLocked(storeURL: url)
                }
                #endif
                
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
        container.viewContext.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump

        // Check CloudKit account status on init
        Task.detached {
            await Self.checkCloudKitStatus()
        }
    }

    #if os(iOS)
    private static func ensureSQLiteStoreIsAccessibleWhileLocked(storeURL: URL) {
        let fm = FileManager.default
        let protection = FileProtectionType.completeUntilFirstUserAuthentication

        // Core Data SQLite stores can have sidecar files.
        let paths = [
            storeURL.path,
            storeURL.path + "-wal",
            storeURL.path + "-shm",
            storeURL.path + "-journal"
        ]

        for path in paths where fm.fileExists(atPath: path) {
            do {
                try fm.setAttributes([.protectionKey: protection], ofItemAtPath: path)
            } catch {
                Self.logger.warning("⚠️ Failed to set file protection on \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }
    #endif

/// Saves pending changes on the main view context, if any.
    /// Errors are logged in DEBUG builds instead of crashing the app.
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
    
    // MARK: - CloudKit Status Checking
    
/// Checks the user's iCloud account status and logs human-readable messages for debugging.
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
}
