//
// CloudKitSyncManager.swift
// nicnark-2
//
// Manages CloudKit synchronization and cross-device Live Activity coordination
//

import Foundation
import CloudKit
import CoreData
import ActivityKit
import UIKit
import os.log

@available(iOS 16.1, *)
@MainActor
class CloudKitSyncManager: ObservableObject {
    static let shared = CloudKitSyncManager()
    
    private let logger = Logger(subsystem: "com.nicnark.nicnark-2", category: "CloudKitSync")
    private let container = CKContainer(identifier: "iCloud.ConnorNeedling.nicnark-2")
    
    @Published var isCloudKitAvailable = false
    @Published var lastSyncDate: Date?
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
                let pouchId = pouch.objectID.uriRepresentation().absoluteString
                let hasActivity = currentActivities.contains { $0.attributes.pouchId == pouchId }
                
                if !hasActivity {
                    logger.info("🆕 Starting Live Activity for synced pouch from another device")
                    let success = await LiveActivityManager.startLiveActivity(
                        for: pouchId,
                        nicotineAmount: pouch.nicotineAmount
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
                let stillActive = activePouches.contains { pouch in
                    pouch.objectID.uriRepresentation().absoluteString == pouchId
                }
                
                if !stillActive {
                    logger.info("🛑 Ending Live Activity for pouch completed on another device")
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
                
                helper.setFromLiveActivity(
                    level: currentLevel,
                    peak: activePouch.nicotineAmount * ABSORPTION_FRACTION,
                    pouchName: "\(Int(activePouch.nicotineAmount))mg pouch",
                    endTime: insertionTime.addingTimeInterval(FULL_RELEASE_TIME)
                )
                
                logger.info("📱 Widget data updated after sync")
            } else {
                helper.markActivityEnded()
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
        do {
            logger.info("📶 Initializing CloudKit schema")
            
            // Access the private database to ensure schema is initialized
            let privateDB = container.privateCloudDatabase
            
            // Try to fetch user record to trigger schema initialization
            _ = try await container.userRecordID()
            
            // First, try to query the existing schema
            let query = CKQuery(recordType: "PouchLog", predicate: NSPredicate(format: "TRUEPREDICATE"))
            
            do {
                _ = try await privateDB.records(matching: query)
                logger.info("✅ CloudKit schema already exists and is accessible")
            } catch {
                logger.info("📝 CloudKit schema not found - forcing Core Data to create it: \(error.localizedDescription, privacy: .public)")
                
                // Force Core Data to create the CloudKit schema by creating and saving a test record
                await forceSchemaCreationWithTestData()
            }
            
        } catch {
            logger.error("❌ CloudKit schema initialization failed: \(error.localizedDescription, privacy: .public)")
        }
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
        
        // 1. Device Information
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
                
                // Try a simple query to test connectivity
                let query = CKQuery(recordType: "PouchLog", predicate: NSPredicate(format: "TRUEPREDICATE"))
                
                do {
                    let (_, _) = try await privateDB.records(matching: query, resultsLimit: 1)
                    diagnostics.append("✅ Database query successful")
                } catch {
                    diagnostics.append("⚠️ Database query failed (expected on first run): \(error.localizedDescription)")
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
