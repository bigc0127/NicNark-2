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
        
        // Try to trigger CloudKit sync by touching the persistent history
        let context = PersistenceController.shared.container.newBackgroundContext()
        await context.perform {
            do {
                // Force a save to trigger CloudKit sync
                try context.save()
                self.logger.info("✅ Manual sync triggered")
            } catch {
                self.logger.error("❌ Manual sync failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
    
    // MARK: - Sync Status
    
    private func checkSyncStatus() async {
        // Check if CloudKit status has changed
        await checkCloudKitAvailability()
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
