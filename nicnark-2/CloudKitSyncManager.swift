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
import os.log

@available(iOS 16.1, *)
@MainActor
class CloudKitSyncManager: ObservableObject {
    static let shared = CloudKitSyncManager()
    
    private let logger = Logger(subsystem: "com.nicnark.nicnark-2", category: "CloudKitSync")
    private let container = CKContainer(identifier: "iCloud.ConnorNeedling.nicnark-2")
    
    @Published var isCloudKitAvailable = false
    @Published var lastSyncDate: Date?
    
    private init() {
        Task {
            await checkCloudKitAvailability()
            await setupSyncMonitoring()
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
    
    // MARK: - Sync Status
    
    private func checkSyncStatus() async {
        // Check if CloudKit status has changed
        await checkCloudKitAvailability()
    }
    
    // MARK: - CloudKit Diagnostics
    
    func diagnoseCloudKitSync() async -> String {
        var diagnostics = ["=== CloudKit Sync Diagnostics ==="]
        
        // 1. Check CloudKit Account Status
        do {
            let accountStatus = try await container.accountStatus()
            diagnostics.append("✅ Account Status: \(accountStatus)")
            
            if accountStatus == .available {
                // 2. Check user record
                do {
                    let userRecordID = try await container.userRecordID()
                    diagnostics.append("✅ User Record ID: \(userRecordID.recordName)")
                } catch {
                    diagnostics.append("❌ User Record Error: \(error.localizedDescription)")
                }
                
                // 3. Check database availability
                let privateDB = container.privateCloudDatabase
                diagnostics.append("✅ Private Database Available")
            }
        } catch {
            diagnostics.append("❌ Account Status Error: \(error.localizedDescription)")
        }
        
        // 4. Check Core Data CloudKit Configuration
        let container = PersistenceController.shared.container
        let coordinator = container.persistentStoreCoordinator
        
        for store in coordinator.persistentStores {
            if let options = store.options,
               let cloudKitOptions = options["NSPersistentCloudKitContainerOptionsKey"] as? NSPersistentCloudKitContainerOptions {
                diagnostics.append("✅ Store CloudKit Container: \(cloudKitOptions.containerIdentifier)")
            } else {
                diagnostics.append("❌ Store missing CloudKit configuration")
            }
            
            if store.options?[NSPersistentHistoryTrackingKey] as? Bool == true {
                diagnostics.append("✅ History tracking enabled")
            } else {
                diagnostics.append("❌ History tracking disabled")
            }
        }
        
        // 5. Count local data
        let context = container.viewContext
        await context.perform {
            do {
                let pouchRequest: NSFetchRequest<PouchLog> = PouchLog.fetchRequest()
                let pouchCount = try context.count(for: pouchRequest)
                diagnostics.append("📊 Local PouchLog count: \(pouchCount)")
                
                let buttonRequest: NSFetchRequest<CustomButton> = CustomButton.fetchRequest()
                let buttonCount = try context.count(for: buttonRequest)
                diagnostics.append("📊 Local CustomButton count: \(buttonCount)")
            } catch {
                diagnostics.append("❌ Local data count error: \(error.localizedDescription)")
            }
        }
        
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
