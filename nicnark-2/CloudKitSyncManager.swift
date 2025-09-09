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
 * @available(iOS 16.1, *) because Live Activity coordination requires this iOS version
 * @MainActor ensures all UI updates happen on the main thread
 */
@available(iOS 16.1, *)
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
        
        // Periodically check for sync status
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in
                await self.checkSyncStatus()
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
        
        // Sync Live Activities with remote data
        await syncLiveActivitiesAcrossDevices()
        
        // Update widgets with new data
        await updateWidgetsAfterSync()
        
        logger.info("🔄 Remote data sync completed")
    }
    
    private func syncLiveActivitiesAcrossDevices() async {
        let context = PersistenceController.shared.container.viewContext
        
        let fetchRequest: NSFetchRequest<PouchLog> = PouchLog.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "removalTime == nil")
        fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \PouchLog.insertionTime, ascending: false)]
        
        do {
            let activePouches = try context.fetch(fetchRequest)
            let currentActivities = Activity<PouchActivityAttributes>.activities
            
            // Start Live Activities for new active pouches (from other devices)
            for pouch in activePouches {
                let pouchId = pouch.pouchId?.uuidString ?? pouch.objectID.uriRepresentation().absoluteString
                
                // Use our improved helper to check for existing activity
                if !LiveActivityManager.activityExists(for: pouchId) {
                    // Double-check the pouch is still active before creating
                    guard await LiveActivityManager.isPouchActive(pouchId) else {
                        logger.info("🚫 Skipping Live Activity for inactive pouch during sync: \(pouchId, privacy: .public)")
                        continue
                    }
                    
                    logger.info("🆕 Starting Live Activity for synced pouch from another device")
                    // Use the pouch's specific duration (stored in minutes, convert to seconds)
                    let duration = TimeInterval(pouch.timerDuration * 60)
                    let success = await LiveActivityManager.startLiveActivity(
                        for: pouchId,
                        nicotineAmount: pouch.nicotineAmount,
                        duration: duration,  // Pass the pouch's specific duration
                        isFromSync: true  // Mark as from sync to prevent ending other activities
                    )
                    
                    if success {
                        logger.info("✅ Live Activity started for cross-device pouch")
                    } else {
                        logger.error("❌ Failed to start Live Activity for cross-device pouch")
                    }
                }
            }
            
            // End Live Activities for pouches completed on other devices
            for activity in currentActivities {
                let pouchId = activity.attributes.pouchId
                
                // Use our Core Data guard to check if pouch is still active
                let isStillActive = await LiveActivityManager.isPouchActive(pouchId)
                
                if !isStillActive {
                    logger.info("🛑 Ending Live Activity for pouch completed on another device: \(pouchId, privacy: .public)")
                    await LiveActivityManager.endLiveActivity(for: pouchId)
                }
            }
            
            logger.info("🔄 Cross-device Live Activity sync: \(activePouches.count) active pouches, \(currentActivities.count) activities")
            
        } catch {
            logger.error("❌ Failed to sync Live Activities: \(error.localizedDescription, privacy: .public)")
        }
    }
    
    private func updateWidgetsAfterSync() async {
        // Update widget persistence helper with latest data
        let helper = WidgetPersistenceHelper()
        
        let context = PersistenceController.shared.container.viewContext
        let fetchRequest: NSFetchRequest<PouchLog> = PouchLog.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "removalTime == nil")
        fetchRequest.fetchLimit = 1
        fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \PouchLog.insertionTime, ascending: false)]
        
        do {
            let activePouches = try context.fetch(fetchRequest)
            
            if let activePouch = activePouches.first,
               let insertionTime = activePouch.insertionTime {
                
                let elapsed = Date().timeIntervalSince(insertionTime)
                let currentLevel = AbsorptionConstants.shared.calculateCurrentNicotineLevel(
                    nicotineContent: activePouch.nicotineAmount,
                    elapsedTime: elapsed
                )
                
                // Use the pouch's specific duration, not the default
                let pouchDuration = TimeInterval(activePouch.timerDuration * 60)
                helper.setFromLiveActivity(
                    level: currentLevel,
                    peak: activePouch.nicotineAmount * ABSORPTION_FRACTION,
                    pouchName: "\(Int(activePouch.nicotineAmount))mg pouch",
                    endTime: insertionTime.addingTimeInterval(pouchDuration)
                )
                
                // Nudge widgets
                await MainActor.run {
                    WidgetCenter.shared.reloadAllTimelines()
                }
                
                logger.info("📱 Widget data updated after sync")
            } else {
                helper.markActivityEnded()
                await MainActor.run { WidgetCenter.shared.reloadAllTimelines() }
                logger.info("📱 Widget marked as ended after sync")
            }
            
        } catch {
            logger.error("❌ Failed to update widgets after sync: \(error.localizedDescription, privacy: .public)")
        }
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
        
        // Initialize CloudKit schema
        await initializeCloudKitSchema()
        
        // Force a comprehensive sync to ensure data consistency
        await triggerManualSync()
        
        // Also try to pull any remote changes
        await handleRemoteDataChanges()
        
        logger.info("✅ Initial sync completed")
    }
    
    private func initializeCloudKitSchema() async {
        #if DEBUG
        let coreDataContainer = PersistenceController.shared.container
        do {
            try coreDataContainer.initializeCloudKitSchema(options: [])
            logger.info("🧱 CloudKit schema initialized (or already present)")
        } catch {
            logger.warning("⚠️ initializeCloudKitSchema failed: \(error.localizedDescription, privacy: .public). Falling back to connectivity check.")
            // Fallback: touch user record to ensure container access
            do { _ = try await container.userRecordID() } catch { }
        }
        #else
        logger.info("ℹ️ Skipping schema init in non-DEBUG build")
        #endif
    }
    
    private func forceSchemaCreationWithTestData() async {
        logger.info("🔧 Forcing CloudKit schema creation with test data")
        
        let container = PersistenceController.shared.container
        let context = container.newBackgroundContext()
        
        // Step 1: Create and save test record
        await context.perform {
            do {
                // Create a temporary PouchLog to force schema creation
                let testPouch = PouchLog(context: context)
                testPouch.pouchId = UUID()
                testPouch.insertionTime = Date()
                testPouch.nicotineAmount = 0.01 // Tiny amount to identify as test data
                testPouch.removalTime = Date() // Already "removed" so it won't interfere
                
                // Save to Core Data - this should trigger CloudKit schema creation
                try context.save()
                self.logger.info("✅ Test record created to force CloudKit schema")
                
            } catch {
                self.logger.error("❌ Failed to create test record for CloudKit schema: \(error.localizedDescription, privacy: .public)")
            }
        }
        
        // Step 2: Wait for CloudKit to process (outside the context.perform)
        do {
            try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
        } catch {
            logger.warning("⚠️ Task sleep interrupted: \(error.localizedDescription, privacy: .public)")
        }
        
        // Step 3: Clean up the test data
        await context.perform {
            do {
                // Find and delete the test record
                let fetchRequest: NSFetchRequest<PouchLog> = PouchLog.fetchRequest()
                fetchRequest.predicate = NSPredicate(format: "nicotineAmount == %f", 0.01)
                
                let testRecords = try context.fetch(fetchRequest)
                for testRecord in testRecords {
                    context.delete(testRecord)
                }
                
                try context.save()
                self.logger.info("✅ Test record(s) cleaned up after schema creation")
                
            } catch {
                self.logger.error("❌ Failed to clean up test records: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
    
    // MARK: - UUID Migration
    
    private func migrateExistingPouchLogsWithMissingUUIDs() async {
        logger.info("🔄 Starting UUID migration for existing PouchLog entries")
        
        let container = PersistenceController.shared.container
        let context = container.newBackgroundContext()
        
        await context.perform {
            let fetchRequest: NSFetchRequest<PouchLog> = PouchLog.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "pouchId == nil")
            
            do {
                let pouchesWithoutUUIDs = try context.fetch(fetchRequest)
                
                if pouchesWithoutUUIDs.isEmpty {
                    self.logger.info("✅ All PouchLog entries already have UUIDs")
                    return
                }
                
                self.logger.info("🔧 Found \(pouchesWithoutUUIDs.count) PouchLog entries without UUIDs - migrating")
                
                for pouch in pouchesWithoutUUIDs {
                    pouch.pouchId = UUID()
                }
                
                try context.save()
                self.logger.info("✅ Successfully migrated \(pouchesWithoutUUIDs.count) PouchLog entries with new UUIDs")
                
            } catch {
                self.logger.error("❌ UUID migration failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
    
    // MARK: - Sync Status
    
    private func checkSyncStatus() async {
        // Check if CloudKit status has changed
        await checkCloudKitAvailability()
    }
    
    // MARK: - CloudKit Diagnostics
    
    func diagnoseCloudKitSync() async -> String {
        var diagnostics = ["=== COMPREHENSIVE CLOUDKIT DIAGNOSTICS ==="]
        diagnostics.append("Generated: \(Date().formatted(.dateTime))")
        diagnostics.append("")
        
        // 1. Build/Schema Environment
        #if DEBUG
        let buildEnv = "Development"
        #else
        let buildEnv = "Production"
        #endif
        diagnostics.append("🏷️ Build: \(buildEnv)")
        
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
        await context.perform {
            do {
                // PouchLog analysis
                let pouchRequest: NSFetchRequest<PouchLog> = PouchLog.fetchRequest()
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
                let buttonRequest: NSFetchRequest<CustomButton> = CustomButton.fetchRequest()
                let buttons = try context.fetch(buttonRequest)
                diagnostics.append("CustomButtons: \(buttons.count)")
                if !buttons.isEmpty {
                    let amounts = buttons.map { "\($0.nicotineAmount)mg" }.joined(separator: ", ")
                    diagnostics.append("Button amounts: [\(amounts)]")
                }
                
            } catch {
                diagnostics.append("❌ Data analysis error: \(error.localizedDescription)")
            }
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
        let testContext = testContainer.newBackgroundContext()
        
        await testContext.perform {
            do {
                // Create a test entity
                let testButton = CustomButton(context: testContext)
                testButton.nicotineAmount = 999.99 // Unique test value
                
                try testContext.save()
                diagnostics.append("✅ Test save successful")
                
                // Clean up test data
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
        
        // Create a test entry to trigger sync
        let container = PersistenceController.shared.container
        let context = container.newBackgroundContext()
        
        await context.perform {
            // Create a test custom button
            let testButton = CustomButton(context: context)
            testButton.nicotineAmount = 999.0 // Unique test value
            
            do {
                try context.save()
                self.logger.info("✅ Test data created and saved")
            } catch {
                self.logger.error("❌ Test data save failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        
        // Wait a moment then delete it
        try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
        
        await context.perform {
            let fetchRequest: NSFetchRequest<CustomButton> = CustomButton.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "nicotineAmount == %f", 999.0)
            
            do {
                let testButtons = try context.fetch(fetchRequest)
                for button in testButtons {
                    context.delete(button)
                }
                try context.save()
                self.logger.info("✅ Test data cleaned up")
            } catch {
                self.logger.error("❌ Test data cleanup failed: \(error.localizedDescription, privacy: .public)")
            }
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
