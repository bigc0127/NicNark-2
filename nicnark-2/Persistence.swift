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

                // NOTE: `initializeCloudKitSchema` is intentionally NOT called.
                // Entitlements force CloudKit *Production* even on debug installs
                // (`com.apple.developer.icloud-container-environment=Production`). Schema init
                // only works against the Development environment and would fail every launch
                // with noisy logs while silently killing the old dev→promote workflow.
                // Schema changes: CloudKit Dashboard → Deploy Schema to Production.
                // Stuck export after env flip: Settings → Sync Status (5×) → Reset Zone & Re-upload.
            }
        }

        // Context configuration
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump

        // Surface CloudKit sync (import/export) health so we can confirm records actually
        // reach the CloudKit *Production* environment. Real store only (no CloudKit in previews).
        if !inMemory {
            CloudKitEventMonitor.start(for: container)
            // Bulk-null retired Can.imageData + wipe App Group CanImages/ (state that outlives code).
            Task { @MainActor in
                DataHygiene.stripRetiredCanPhotosIfNeeded(context: persistentContainer.viewContext)
            }
        }

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

// MARK: - CloudKit Sync Event Monitor

/**
 Debug-gated observer of `NSPersistentCloudKitContainer.eventChangedNotification`.

 Logs CloudKit setup / import / **export** outcomes (succeeded flag + error) so we can
 verify that local saves actually reach CloudKit. This is the signal that tells us whether
 the Production schema deploy worked: before the deploy, export events for records carrying
 the `CD_timerDuration` field fail; after, they should report `succeeded=true`.

 Visible in **Console.app** (or the Xcode device console) filtered to subsystem
 `com.nicnark.nicnark-2`, category `CloudKitEvents`. Intentionally NOT gated on `#if DEBUG`
 — it must work on a TestFlight/Release build (Production environment) to confirm the fix.
 Gated instead on a runtime flag (`UserDefaults` key `ckEventLoggingEnabled`, default on);
 set that key to `false` to silence.
 */
enum CloudKitEventMonitor {
    nonisolated private static let logger = Logger(subsystem: "com.nicnark.nicnark-2", category: "CloudKitEvents")

    /// `UserDefaults` key for the in-app ring buffer of recent event lines (viewable in Settings →
    /// CloudKit → "Event Log" on a device with no Mac/Console attached).
    nonisolated private static let logBufferKey = "ckEventLogBuffer"
    /// Keep the buffer small — the most recent events are what matter for diagnosis.
    nonisolated private static let maxBufferedLines = 60

    /// Runtime debug flag. Defaults ON so a TestFlight install logs without a debug build.
    /// `nonisolated`: only touches `UserDefaults` (Sendable-safe) so the observer block can read it.
    nonisolated static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "ckEventLoggingEnabled") as? Bool ?? true
    }

    /// Most-recent-last list of formatted event lines, for the in-app viewer.
    nonisolated static func recentLog() -> [String] {
        UserDefaults.standard.stringArray(forKey: logBufferKey) ?? []
    }

    /// Clear the in-app buffer (so a fresh "log a pouch" test starts clean).
    nonisolated static func clearLog() {
        UserDefaults.standard.removeObject(forKey: logBufferKey)
    }

    /// Append one line to the capped ring buffer. UserDefaults is thread-safe; the observer
    /// block runs serially on the main queue, so the read-modify-write here is race-free.
    nonisolated private static func appendToBuffer(_ line: String) {
        var lines = UserDefaults.standard.stringArray(forKey: logBufferKey) ?? []
        lines.append(line)
        if lines.count > maxBufferedLines { lines.removeFirst(lines.count - maxBufferedLines) }
        UserDefaults.standard.set(lines, forKey: logBufferKey)
    }

    /// Register the observer. Called once from `PersistenceController.init` for the real store.
    /// The block runs on the main queue and logs synchronously, so it captures no mutable state
    /// (Swift 6 concurrency-safe) and never needs to be removed for the app's lifetime.
    nonisolated static func start(for container: NSPersistentCloudKitContainer) {
        NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: container,
            queue: .main
        ) { note in
            guard isEnabled else { return }
            guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event else { return }
            log(event)
        }
    }

    nonisolated private static func log(_ event: NSPersistentCloudKitContainer.Event) {
        let kind: String
        switch event.type {
        case .setup:  kind = "setup"
        case .import: kind = "import"
        case .export: kind = "export"
        @unknown default: kind = "unknown"
        }

        // endDate == nil → operation just *started*; non-nil → it *finished* (succeeded/error meaningful).
        let id = event.identifier.uuidString.prefix(8)
        let time = Date.now.formatted(date: .omitted, time: .standard)

        if event.endDate == nil {
            logger.debug("☁️… CK \(kind, privacy: .public) started id=\(id, privacy: .public)")
            appendToBuffer("\(time)  \(kind) … started  [\(id)]")
            return
        }

        if let error = event.error {
            logger.error("☁️❌ CK \(kind, privacy: .public) FAILED id=\(id, privacy: .public) error=\(error.localizedDescription, privacy: .public) full=\(String(describing: error), privacy: .public)")
            appendToBuffer("\(time)  \(kind) ❌ FAILED  [\(id)]\n   \(error.localizedDescription)\n   \(String(describing: error))")
        } else {
            logger.info("☁️✅ CK \(kind, privacy: .public) finished succeeded=\(event.succeeded, privacy: .public) id=\(id, privacy: .public)")
            appendToBuffer("\(time)  \(kind) ✅ finished succeeded=\(event.succeeded)  [\(id)]")
        }
    }
}
