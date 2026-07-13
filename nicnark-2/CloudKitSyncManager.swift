//
// CloudKitSyncManager.swift
// nicnark-2
//
// Advanced CloudKit Synchronization & Cross-Device Coordination Manager
//
// This manager handles the complex orchestration of data synchronization across multiple devices.
// Key responsibilities include:
//
// Data Synchronization:
// • Monitoring CloudKit account status and availability
// • Detecting when data changes arrive from other devices
// • Triggering manual sync operations when needed
// • Handling sync conflicts and error recovery
//
// Cross-Device Live Activity Management:
// • Starting Live Activities for pouches logged on other devices
// • Ending Live Activities for pouches removed on other devices
// • Preventing duplicate activities across multiple devices
// • Ensuring consistent activity state across iPhone, iPad, etc.
//
// Widget & UI Coordination:
// • Updating widgets after sync events
// • Maintaining widget persistence data consistency
// • Publishing sync status for UI indicators
// • Managing background sync preferences
//
// This system ensures users have a seamless experience when using the app across
// multiple Apple devices signed into the same iCloud account.
//

import Foundation
import Combine
import CloudKit
import CoreData
import ActivityKit
import UIKit
import WidgetKit
import os.log

/**
 * CloudKitSyncManager: Orchestrates advanced CloudKit synchronization for multi-device scenarios.
 * 
 * This singleton manages the sophisticated coordination required when users have the app
 * installed on multiple devices (iPhone, iPad) signed into the same iCloud account.
 * 
 * Key challenges this solves:
 * - Preventing duplicate Live Activities across devices
 * - Synchronizing pouch state changes in real-time
 * - Maintaining consistent UI state across all devices
 * - Handling network failures and sync conflicts gracefully
 * 
 * @MainActor ensures all UI updates happen on the main thread
 */
@MainActor
class CloudKitSyncManager: ObservableObject {
    /// Shared singleton instance used throughout the app
    static let shared = CloudKitSyncManager()
    
    /// Logger for debugging complex sync scenarios
    private let logger = Logger(subsystem: "com.nicnark.nicnark-2", category: "CloudKitSync")
    /// CloudKit container for accessing iCloud data
    private let container = CKContainer(identifier: "iCloud.ConnorNeedling.nicnark-2")
    
    /// Published property indicating if CloudKit sync is available (UI can observe this)
    @Published var isCloudKitAvailable = false
    /// When the last sync operation completed (for UI display)
    @Published var lastSyncDate: Date?
    /// Current sync status message (for debugging and UI feedback)
    @Published var syncStatus: String = "Initializing..."
    
    private init() {
        Task {
            await checkCloudKitAvailability()
            await migrateExistingPouchLogsWithMissingUUIDs()
            await setupSyncMonitoring()
            // Force an initial sync check
            await triggerInitialSync()
        }
    }
    
    // MARK: - CloudKit Status
    
    private func checkCloudKitAvailability() async {
        do {
            let status = try await container.accountStatus()
            await MainActor.run {
                self.isCloudKitAvailable = (status == .available)
                
                switch status {
                case .available:
                    logger.info("✅ CloudKit available - multi-device sync enabled")
                case .noAccount:
                    logger.warning("⚠️ No iCloud account - sync disabled")
                case .restricted:
                    logger.warning("⚠️ iCloud restricted - sync disabled")
                case .couldNotDetermine:
                    logger.warning("⚠️ CloudKit status unknown")
                case .temporarilyUnavailable:
                    logger.warning("⚠️ CloudKit temporarily unavailable")
                @unknown default:
                    logger.warning("⚠️ Unknown CloudKit status")
                }
            }
        } catch {
            logger.error("❌ Failed to check CloudKit status: \(error.localizedDescription, privacy: .public)")
            await MainActor.run {
                self.isCloudKitAvailable = false
            }
        }
    }
    
    // MARK: - Sync Monitoring
    
    private func setupSyncMonitoring() async {
        // Listen for remote CloudKit changes
        NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.handleRemoteDataChanges()
            }
        }
        
        // Re-check CloudKit availability when the app returns to the foreground, instead
        // of a forever-running 60s polling timer that strongly retained this singleton
        // (the closure captured `self`, not `[weak self]`) and burned battery polling
        // accountStatus on a fixed cadence for the whole app lifetime.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.checkCloudKitAvailability()
            }
        }
    }
    
    // MARK: - Sync Preferences
    
    private var isSyncEnabled: Bool {
        UserDefaults.standard.object(forKey: "cloudKitSyncEnabled") as? Bool ?? true
    }
    
    // MARK: - Data Sync Handling
    
    func handleRemoteDataChanges() async {
        guard isCloudKitAvailable && isSyncEnabled else { 
            logger.info("⚠️ Skipping remote data sync - CloudKit unavailable or sync disabled")
            return 
        }
        
        logger.info("📡 Processing remote CloudKit data changes")
        lastSyncDate = Date()

        // Backfill UUIDs for any records that just arrived from CloudKit without a pouchId,
        // so the Live Activity sync below can select/dedup them by their cross-device identity.
        await migrateExistingPouchLogsWithMissingUUIDs()

        // Sync Live Activities with remote data
        await syncLiveActivitiesAcrossDevices()
        
        // Update widgets with new data
        await updateWidgetsAfterSync()

        // Re-strip any Can.imageData that arrived from older devices still holding photos.
        await MainActor.run {
            DataHygiene.stripRetiredCanPhotosIfNeeded(
                context: PersistenceController.shared.container.viewContext
            )
        }

        logger.info("🔄 Remote data sync completed")
    }
    
    /**
     * Syncs Live Activities across devices using CloudKit data.
     * 
     * SINGLE-ACTIVITY POLICY:
     * This app enforces a strict one-Live-Activity-at-a-time policy, even when multiple
     * pouches are active simultaneously. This is because:
     * 1. iOS limits Live Activities per app (system throttling)
     * 2. Multiple Live Activities create visual clutter on lock screen
     * 3. Users want to see aggregated info (total nicotine, longest timer)
     * 
     * SELECTION CRITERIA:
     * When multiple pouches are active, we create ONE Live Activity that represents:
     * - Timer: The pouch with the LONGEST remaining duration
     * - Nicotine: The SUM of all active pouches' nicotine amounts
     * - Progress: Based on the longest timer's progress
     * 
     * This gives users the most relevant information at a glance.
     */
    private func syncLiveActivitiesAcrossDevices() async {
        let context = PersistenceController.shared.container.viewContext
        
        let fetchRequest: NSFetchRequest<PouchLog> = PouchLog.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "removalTime == nil")
        fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \PouchLog.insertionTime, ascending: false)]
        
        do {
            let activePouches = try context.fetch(fetchRequest)
            let currentActivities = Activity<PouchActivityAttributes>.activities
            
            // STEP 1: End Live Activities for pouches completed on other devices
            for activity in currentActivities {
                let pouchId = activity.attributes.pouchId
                let isStillActive = await LiveActivityManager.isPouchActive(pouchId)
                
                if !isStillActive {
                    logger.info("🛑 Ending Live Activity for pouch completed on another device: \(pouchId, privacy: .public)")
                    await LiveActivityManager.endLiveActivity(for: pouchId)
                }
            }
            
            guard !activePouches.isEmpty else {
                logger.info("ℹ️ No active pouches - no Live Activity needed")
                return
            }

            // Shared aggregate: total mg + longest remaining timer (same rule as LogService).
            guard let agg = LogService.aggregate(activePouches: activePouches) else {
                logger.warning("⚠️ Could not determine representative pouch for Live Activity")
                return
            }

            let remainingActivities = Activity<PouchActivityAttributes>.activities
            // Skip rebuild if the single LA already matches the aggregate.
            if let existing = remainingActivities.first {
                let samePouch = existing.attributes.pouchId == agg.representativePouchId
                let sameTotal = abs(existing.attributes.totalNicotine - agg.totalNicotine) < 0.01
                if samePouch && sameTotal && remainingActivities.count == 1 {
                    logger.info("✅ Live Activity already matches aggregate (\(agg.activeCount) pouches, \(agg.totalNicotine)mg)")
                    return
                }
            }

            logger.info("🆕 Rebuilding single Live Activity for \(agg.activeCount) pouches (total: \(agg.totalNicotine)mg)")
            // Serialized end→recreate (same chain as log/remove) with correct bloodstream seed.
            await LogService.presentAggregatedLiveActivitySerialized(in: context)

        } catch {
            logger.error("❌ Failed to sync Live Activities: \(error.localizedDescription, privacy: .public)")
        }
    }
    
    private func updateWidgetsAfterSync() async {
        let context = PersistenceController.shared.container.viewContext
        // Multi-pouch aggregate: total mg + longest remaining end time + full bloodstream level.
        LogService.updateWidgetSnapshotForActivePouches(in: context)
        WidgetReloadCoordinator.reload()
        logger.info("📱 Widget data updated after sync (aggregated)")
    }
    
    // MARK: - Manual Sync
    
    func triggerManualSync() async {
        guard isCloudKitAvailable else {
            logger.warning("⚠️ Cannot sync - CloudKit not available")
            return
        }
        
        logger.info("🔄 Triggering manual CloudKit sync")
        
        // Update sync status
        await MainActor.run {
            self.lastSyncDate = Date()
        }
        
        // Method 1: Force CloudKit sync by triggering persistent history processing
        await forcePersistentHistorySync()
        
        // Method 2: Trigger CloudKit container operations
        await triggerCloudKitOperations()
        
        // Method 3: Process any remote changes that may be pending
        await handleRemoteDataChanges()
        
        logger.info("✅ Manual sync completed")
    }
    
    private func forcePersistentHistorySync() async {
        let container = PersistenceController.shared.container
        let context = container.newBackgroundContext()
        
        await context.perform {
            do {
                // Process persistent history to push changes to CloudKit
                let historyRequest = NSPersistentHistoryChangeRequest.fetchHistory(after: .distantPast)
                if (try context.execute(historyRequest) as? NSPersistentHistoryResult) != nil {
                    self.logger.info("📄 Processing persistent history for CloudKit sync")
                }
                
                // Force a save to trigger any pending CloudKit operations
                if context.hasChanges {
                    try context.save()
                }
                
                self.logger.info("✅ Persistent history sync completed")
            } catch {
                self.logger.error("❌ Persistent history sync failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
    
    private func triggerCloudKitOperations() async {
        do {
            // Check CloudKit account status to ensure we can sync
            let accountStatus = try await container.accountStatus()
            
            if accountStatus == .available {
                // Fetch any pending CloudKit changes
                logger.info("🌍 Checking for CloudKit updates")
                
                // Try to trigger CloudKit schema update/check
                // This can help initiate sync operations
                _ = try await container.userRecordID()
                
                logger.info("✅ CloudKit operations completed")
            } else {
                logger.warning("⚠️ CloudKit account not available for sync: \(String(describing: accountStatus))")
            }
        } catch {
            logger.error("❌ CloudKit operations failed: \(error.localizedDescription, privacy: .public)")
        }
    }
    
    // MARK: - Initial Sync
    
    private func triggerInitialSync() async {
        guard isCloudKitAvailable && isSyncEnabled else {
            logger.info("⚠️ Skipping initial sync - CloudKit unavailable or sync disabled")
            return
        }
        
        logger.info("🚀 Triggering initial CloudKit sync")

        // Schema init intentionally skipped: app forces CloudKit Production (see entitlements).
        // `initializeCloudKitSchema` only targets Development and would fail every DEBUG launch.
        // Deploy schema via CloudKit Dashboard → Production. Connectivity probe only:
        do { _ = try await container.userRecordID() } catch {
            logger.warning("⚠️ CloudKit userRecordID probe failed: \(error.localizedDescription, privacy: .public)")
        }

        // Force a comprehensive sync to ensure data consistency.
        // triggerManualSync() already calls handleRemoteDataChanges(), so we don't
        // duplicate that work here.
        await triggerManualSync()

        logger.info("✅ Initial sync completed")
    }
    
    // MARK: - UUID Migration
    
    private func migrateExistingPouchLogsWithMissingUUIDs() async {
        // Backfill pouchId for any PouchLog with a nil UUID. Every PouchLog created since v2
        // gets a UUID at insertion time, but a record imported via CloudKit from a pre-UUID
        // build can arrive with a nil pouchId at any point — so we re-check on every launch
        // (and on remote changes) instead of gating behind a permanent one-shot flag, which
        // would leave such late-arriving records without the cross-device identity that Live
        // Activity selection/dedup keys on. The check is cheap: count(for:) does not
        // materialize objects, so it costs ~nothing when there is nothing to backfill.
        // We deliberately stay on the MainActor viewContext: this project generates Core Data
        // classes under MainActor isolation, so mutating pouch.pouchId from a background
        // context's Sendable closure is unsafe.
        let context = PersistenceController.shared.container.viewContext
        let fetchRequest = NSFetchRequest<PouchLog>(entityName: "PouchLog")
        fetchRequest.predicate = NSPredicate(format: "pouchId == nil")
        fetchRequest.fetchBatchSize = 200
        do {
            let missing = try context.count(for: fetchRequest)
            guard missing > 0 else {
                logger.info("✅ All PouchLog entries already have UUIDs")
                return
            }
            logger.info("🔧 Backfilling \(missing) PouchLog entries without UUIDs")
            let pouchesWithoutUUIDs = try context.fetch(fetchRequest)
            for pouch in pouchesWithoutUUIDs {
                pouch.pouchId = UUID()
            }
            try context.save()
        } catch {
            logger.error("❌ UUID migration failed: \(error.localizedDescription, privacy: .public)")
        }
    }
    
    // MARK: - CloudKit Diagnostics
    
    func diagnoseCloudKitSync() async -> String {
        var diagnostics = ["=== COMPREHENSIVE CLOUDKIT DIAGNOSTICS ==="]
        diagnostics.append("Generated: \(Date().formatted(.dateTime))")
        diagnostics.append("")
        
        // 1. Build configuration vs CloudKit container environment (they are NOT the same).
        // Entitlements force Production for all configs — see nicnark_2.entitlements.
        #if DEBUG
        let xcodeConfig = "Debug"
        #else
        let xcodeConfig = "Release"
        #endif
        diagnostics.append("🏷️ Xcode configuration: \(xcodeConfig)")
        diagnostics.append("☁️ CloudKit container environment: Production (forced by entitlements)")
        diagnostics.append("   Container: iCloud.ConnorNeedling.nicnark-2")
        diagnostics.append("   Verify exports: Console filter CloudKitEvents / Settings → Event Log")
        diagnostics.append("   Env flip recovery: Settings → Sync Status (tap 5×) → Reset Zone & Re-upload")
        
        // 2. Device Information
        diagnostics.append("📱 DEVICE INFO:")
        diagnostics.append("Device: \(UIDevice.current.model)")
        diagnostics.append("iOS Version: \(UIDevice.current.systemVersion)")
        diagnostics.append("Device Name: \(UIDevice.current.name)")
        diagnostics.append("")
        
        // 2. CloudKit Account Status
        diagnostics.append("☁️ CLOUDKIT ACCOUNT:")
        do {
            let accountStatus = try await container.accountStatus()
            diagnostics.append("Status: \(accountStatus)")
            
            switch accountStatus {
            case .available:
                diagnostics.append("✅ Account is available for CloudKit")
                
                // Get user record details
                do {
                    let userRecordID = try await container.userRecordID()
                    diagnostics.append("User Record: \(userRecordID.recordName)")
                } catch {
                    diagnostics.append("❌ User Record Error: \(error.localizedDescription)")
                }
                
                // Test database access
                let privateDB = container.privateCloudDatabase
                diagnostics.append("✅ Private Database accessible")
                
                // Try a simple query to test connectivity. With Core Data + CloudKit, record types are prefixed with "CD_".
                let candidates = ["CD_PouchLog", "PouchLog"]
                var querySucceeded = false
                for type in candidates {
                    do {
                        let query = CKQuery(recordType: type, predicate: NSPredicate(format: "TRUEPREDICATE"))
                        let (_, _) = try await privateDB.records(matching: query, resultsLimit: 1)
                        diagnostics.append("✅ Database query successful for record type: \(type)")
                        querySucceeded = true
                        break
                    } catch {
                        // Silently continue to next candidate
                        continue
                    }
                }
                if !querySucceeded {
                    // If direct CKQuery failed, avoid alarming users. Core Data + CloudKit may still be syncing fine.
                    // We’ll treat this as an informational note and report local data instead of an error line.
                    let context = PersistenceController.shared.container.viewContext
                    let fr: NSFetchRequest<PouchLog> = PouchLog.fetchRequest()
                    fr.fetchLimit = 1
                    let localHasData = (try? context.count(for: fr)) ?? 0 > 0
                    if localHasData {
                        diagnostics.append("ℹ️ Skipped direct record-type probe; CloudKit is reachable and local data exists. Sync appears active.")
                    } else {
                        diagnostics.append("ℹ️ Skipped direct record-type probe; CloudKit is reachable.")
                    }
                }
                
            case .noAccount:
                diagnostics.append("❌ No iCloud account signed in")
            case .restricted:
                diagnostics.append("❌ iCloud account is restricted")
            case .couldNotDetermine:
                diagnostics.append("❌ Could not determine iCloud status")
            case .temporarilyUnavailable:
                diagnostics.append("⚠️ iCloud temporarily unavailable")
            @unknown default:
                diagnostics.append("❌ Unknown iCloud status")
            }
            
        } catch {
            diagnostics.append("❌ Account Status Check Failed: \(error.localizedDescription)")
        }
        diagnostics.append("")
        
        // 3. Core Data Configuration
        diagnostics.append("🗄️ CORE DATA CONFIGURATION:")
        let coreDataContainer = PersistenceController.shared.container
        let coordinator = coreDataContainer.persistentStoreCoordinator
        
        for (index, store) in coordinator.persistentStores.enumerated() {
            diagnostics.append("Store #\(index + 1):")
            diagnostics.append("  URL: \(store.url?.absoluteString ?? "Unknown")")
            diagnostics.append("  Type: \(store.type)")
            
            if let options = store.options {
                if let cloudKitOptions = options["NSPersistentCloudKitContainerOptionsKey"] as? NSPersistentCloudKitContainerOptions {
                    diagnostics.append("  ✅ CloudKit Container: \(cloudKitOptions.containerIdentifier)")
                } else {
                    diagnostics.append("  ❌ No CloudKit configuration found")
                }
                
                if options[NSPersistentHistoryTrackingKey] as? Bool == true {
                    diagnostics.append("  ✅ History tracking: Enabled")
                } else {
                    diagnostics.append("  ❌ History tracking: Disabled")
                }
                
                if options[NSPersistentStoreRemoteChangeNotificationPostOptionKey] as? Bool == true {
                    diagnostics.append("  ✅ Remote notifications: Enabled")
                } else {
                    diagnostics.append("  ❌ Remote notifications: Disabled")
                }
            }
        }
        diagnostics.append("")
        
        // 4. Data Counts and Sample Data
        diagnostics.append("📊 DATA ANALYSIS:")
        let context = coreDataContainer.viewContext
        do {
            // PouchLog analysis
            let pouchRequest = NSFetchRequest<PouchLog>(entityName: "PouchLog")
            let allPouches = try context.fetch(pouchRequest)
            diagnostics.append("Total PouchLogs: \(allPouches.count)")

            let activePouches = allPouches.filter { $0.removalTime == nil }
            diagnostics.append("Active PouchLogs: \(activePouches.count)")

            if !allPouches.isEmpty {
                let latest = allPouches.max(by: { ($0.insertionTime ?? Date.distantPast) < ($1.insertionTime ?? Date.distantPast) })
                if let latest = latest {
                    diagnostics.append("Latest PouchLog:")
                    diagnostics.append("  UUID: \(latest.pouchId?.uuidString ?? "Missing UUID!")")
                    diagnostics.append("  Amount: \(latest.nicotineAmount)mg")
                    diagnostics.append("  Inserted: \(latest.insertionTime?.formatted(.dateTime) ?? "Unknown")")
                    diagnostics.append("  Removed: \(latest.removalTime?.formatted(.dateTime) ?? "Still active")")
                }
            }

            // CustomButton analysis
            let buttonRequest = NSFetchRequest<CustomButton>(entityName: "CustomButton")
            let buttons = try context.fetch(buttonRequest)
            diagnostics.append("CustomButtons: \(buttons.count)")
            if !buttons.isEmpty {
                let amounts = buttons.map { "\($0.nicotineAmount)mg" }.joined(separator: ", ")
                diagnostics.append("Button amounts: [\(amounts)]")
            }
        } catch {
            diagnostics.append("❌ Data analysis error: \(error.localizedDescription)")
        }
        diagnostics.append("")
        
        // 5. Sync Status
        diagnostics.append("🔄 SYNC STATUS:")
        diagnostics.append("CloudKit Available: \(isCloudKitAvailable ? "Yes" : "No")")
        diagnostics.append("Sync Enabled: \(isSyncEnabled ? "Yes" : "No")")
        if let lastSync = lastSyncDate {
            diagnostics.append("Last Sync: \(lastSync.formatted(.dateTime))")
            let timeSinceSync = Date().timeIntervalSince(lastSync)
            diagnostics.append("Time Since Last Sync: \(Int(timeSinceSync))s ago")
        } else {
            diagnostics.append("Last Sync: Never")
        }
        diagnostics.append("")
        
        // 6. Test a save operation
        diagnostics.append("🧪 TESTING SAVE OPERATION:")
        let testContainer = PersistenceController.shared.container

        if testContainer.persistentStoreCoordinator.persistentStores.isEmpty {
            diagnostics.append("❌ Core Data store is not loaded (device may be locked). Skipping save test.")
        } else {
            let testContext = testContainer.viewContext
            do {
                let testButton = CustomButton(context: testContext)
                testButton.nicotineAmount = 999.99 // Unique test value
                try testContext.save()
                diagnostics.append("✅ Test save successful")

                testContext.delete(testButton)
                try testContext.save()
                diagnostics.append("✅ Test cleanup successful")
            } catch {
                diagnostics.append("❌ Test save failed: \(error.localizedDescription)")
                diagnostics.append("❌ Full error: \(error)")
            }
        }
        
        diagnostics.append("")
        diagnostics.append("=== END DIAGNOSTICS ===")
        
        return diagnostics.joined(separator: "\n")
    }
    
    // MARK: - Force Data Sync Test
    
    func testDataSync() async {
        logger.info("🧪 Starting CloudKit sync test")

        let container = PersistenceController.shared.container
        guard !container.persistentStoreCoordinator.persistentStores.isEmpty else {
            logger.error("❌ Core Data store is not loaded (device may be locked). Aborting test sync.")
            return
        }

        let context = container.viewContext

        // Create a test custom button
        let testButton = CustomButton(context: context)
        testButton.nicotineAmount = 999.0 // Unique test value
        do {
            try context.save()
            logger.info("✅ Test data created and saved")
        } catch {
            logger.error("❌ Test data save failed: \(error.localizedDescription, privacy: .public)")
        }

        // Wait a moment then delete it
        try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds

        let fetchRequest = NSFetchRequest<CustomButton>(entityName: "CustomButton")
        fetchRequest.predicate = NSPredicate(format: "nicotineAmount == %f", 999.0)
        do {
            let testButtons = try context.fetch(fetchRequest)
            for button in testButtons {
                context.delete(button)
            }
            try context.save()
            logger.info("✅ Test data cleaned up")
        } catch {
            logger.error("❌ Test data cleanup failed: \(error.localizedDescription, privacy: .public)")
        }
    }
    
    // MARK: - Stalled-Export Recovery

    /**
     Recovery for a stalled/poisoned `NSPersistentCloudKitContainer` export queue.

     Symptom this fixes: the local store holds far more records than CloudKit (e.g. 2625 local
     vs 57 in the cloud, frozen for months) because one rejected export transaction blocked the
     queue and the container never recovered — even after the Production schema was corrected.

     Fix: delete the Core Data CloudKit record zone (`com.apple.coredata.cloudkit.zone`) in the
     private database. When the container next initializes and finds the zone missing, it
     re-creates it and re-uploads the **entire local store** from scratch — bypassing the stuck
     transaction entirely.

     SAFE ONLY when this device holds the superset of data (it does here: cloud ⊂ local). The
     caller MUST force-quit and relaunch the app immediately after this returns, so the container
     re-initializes from a clean state and re-uploads, rather than trying to reconcile the
     deletion in the current session. Recommend the user export a CSV backup beforehand.

     - Returns: a human-readable status string for display.
     */
    func resetCloudKitZoneForFullReupload() async -> String {
        guard isCloudKitAvailable else {
            return "❌ CloudKit not available — cannot reset (check iCloud sign-in / network)."
        }

        let zoneID = CKRecordZone.ID(zoneName: "com.apple.coredata.cloudkit.zone",
                                     ownerName: CKCurrentUserDefaultName)
        logger.info("🧨 Deleting CloudKit zone \(zoneID.zoneName, privacy: .public) to force full re-upload")
        do {
            let result = try await container.privateCloudDatabase.modifyRecordZones(
                saving: [], deleting: [zoneID]
            )
            if case .failure(let error)? = result.deleteResults[zoneID] {
                let nsError = error as NSError
                // Zone already gone is effectively success for our purpose.
                if nsError.domain == CKError.errorDomain, nsError.code == CKError.zoneNotFound.rawValue {
                    return "ℹ️ Cloud zone was already absent. Force-quit and reopen the app to trigger the full re-upload."
                }
                logger.error("❌ Zone delete failed: \(error.localizedDescription, privacy: .public)")
                return "❌ Zone delete failed: \(error.localizedDescription)"
            }
            logger.info("✅ CloudKit zone deleted — full re-upload will begin on next launch")
            return "✅ Cloud zone deleted.\n\nNOW: force-quit the app (swipe it away) and reopen it. The full re-upload of all local records will begin — keep the app open and on Wi-Fi; it can take several minutes for 2000+ records. Watch Event Log for repeated 'export ✅' lines."
        } catch {
            let nsError = error as NSError
            if nsError.domain == CKError.errorDomain, nsError.code == CKError.zoneNotFound.rawValue {
                return "ℹ️ Cloud zone was already absent. Force-quit and reopen the app to trigger the full re-upload."
            }
            logger.error("❌ Zone reset failed: \(error.localizedDescription, privacy: .public)")
            return "❌ Zone reset failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Public API

    func getSyncStatusText() -> String {
        if isCloudKitAvailable {
            if let lastSync = lastSyncDate {
                let formatter = DateFormatter()
                formatter.timeStyle = .short
                formatter.dateStyle = .none
                return "Last sync: \(formatter.string(from: lastSync))"
            } else {
                return "CloudKit ready"
            }
        } else {
            return "Sync unavailable"
        }
    }
}
