//
// CloudKitSyncState.swift
// nicnark-2
//
// Tracks CloudKit sync state to prevent duplicate operations across devices
//

import Foundation
import CloudKit
import CoreData
import os.log

@available(iOS 16.1, *)
@MainActor
class CloudKitSyncState: ObservableObject {
    static let shared = CloudKitSyncState()
    
    @Published var isSyncing = false
    @Published var syncCompleted = false
    @Published var syncProgress: Double = 0.0
    @Published var syncMessage = "Checking for updates..."
    @Published var needsInitialSync = true
    
    private let logger = Logger(subsystem: "com.nicnark.nicnark-2", category: "SyncState")
    private var syncCompletionTimer: Timer?
    private let syncTimeout: TimeInterval = 10.0 // Maximum time to wait for sync
    
    init() {
        // Check if CloudKit is available and enabled
        Task {
            await checkIfSyncIsNeeded()
        }
    }
    
    // MARK: - Check if iCloud sync is enabled
    
    var isCloudKitEnabled: Bool {
        // Check if user has iCloud sync enabled in settings
        let syncEnabled = UserDefaults.standard.object(forKey: "cloudKitSyncEnabled") as? Bool ?? true
        return syncEnabled && CloudKitSyncManager.shared.isCloudKitAvailable
    }
    
    // MARK: - Initial Sync Check
    
    func checkIfSyncIsNeeded() async {
        guard isCloudKitEnabled else {
            // If CloudKit is disabled, we don't need to sync
            await MainActor.run {
                self.needsInitialSync = false
                self.syncCompleted = true
            }
            return
        }
        
        // Check if app was just launched
        let lastLaunchTime = UserDefaults.standard.object(forKey: "lastAppLaunchTime") as? Date
        let now = Date()
        UserDefaults.standard.set(now, forKey: "lastAppLaunchTime")
        
        // If app was launched recently (within 5 seconds), don't force sync
        if let lastLaunch = lastLaunchTime, now.timeIntervalSince(lastLaunch) < 5 {
            await MainActor.run {
                self.needsInitialSync = false
                self.syncCompleted = true
            }
            return
        }
        
        // Otherwise, we need an initial sync
        await MainActor.run {
            self.needsInitialSync = true
            self.syncCompleted = false
        }
    }
    
    // MARK: - Start Sync Process
    
    func startInitialSync() async {
        guard isCloudKitEnabled && needsInitialSync else {
            syncCompleted = true
            return
        }
        
        logger.info("🔄 Starting initial CloudKit sync")
        
        await MainActor.run {
            self.isSyncing = true
            self.syncProgress = 0.0
            self.syncMessage = "Syncing with iCloud..."
        }
        
        // Start timeout timer
        startSyncTimeout()
        
        // Listen for CloudKit sync notifications
        NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.handleSyncProgress()
            }
        }
        
        // Trigger manual sync
        await performSync()
    }
    
    private func performSync() async {
        // Update progress
        await MainActor.run {
            self.syncProgress = 0.3
            self.syncMessage = "Fetching remote changes..."
        }
        
        // Trigger CloudKit sync
        await CloudKitSyncManager.shared.triggerManualSync()
        
        // Update progress
        await MainActor.run {
            self.syncProgress = 0.6
            self.syncMessage = "Processing updates..."
        }
        
        // Wait a moment for sync to complete
        try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5 seconds
        
        // Check for active pouches that might have been removed on another device
        await checkForRemotePouchChanges()
        
        // Update progress
        await MainActor.run {
            self.syncProgress = 0.9
            self.syncMessage = "Finalizing..."
        }
        
        // Wait a brief moment
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        
        // Complete sync
        await completeSyncProcess()
    }
    
    private func checkForRemotePouchChanges() async {
        let context = PersistenceController.shared.container.viewContext
        
        // Check if any active pouches were removed on another device
        let fetchRequest: NSFetchRequest<PouchLog> = PouchLog.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "removalTime == nil")
        
        do {
            let activePouches = try context.fetch(fetchRequest)
            logger.info("📊 Found \(activePouches.count) active pouches after sync")
            
            // If we have active pouches, verify they're still valid
            for pouch in activePouches {
                if let insertionTime = pouch.insertionTime {
                    let timeSinceInsertion = Date().timeIntervalSince(insertionTime)
                    
                    // If pouch has been active for more than 30 minutes without removal,
                    // it might have been removed on another device but sync hasn't updated yet
                    if timeSinceInsertion > FULL_RELEASE_TIME + 60 { // 31 minutes
                        logger.warning("⚠️ Found stale active pouch - may need cleanup")
                    }
                }
            }
        } catch {
            logger.error("❌ Failed to check remote pouch changes: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Sync Progress Handling
    
    private func handleSyncProgress() async {
        await MainActor.run {
            if syncProgress < 0.8 {
                syncProgress += 0.2
            }
            syncMessage = "Syncing data..."
        }
    }
    
    // MARK: - Complete Sync
    
    private func completeSyncProcess() async {
        cancelSyncTimeout()
        
        await MainActor.run {
            self.syncProgress = 1.0
            self.syncMessage = "Sync complete"
            self.syncCompleted = true
            self.needsInitialSync = false
        }
        
        // Keep success state visible briefly
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        
        await MainActor.run {
            self.isSyncing = false
        }
        
        logger.info("✅ Initial sync completed successfully")
    }
    
    // MARK: - Timeout Handling
    
    private func startSyncTimeout() {
        cancelSyncTimeout()
        
        syncCompletionTimer = Timer.scheduledTimer(withTimeInterval: syncTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in
                await self?.handleSyncTimeout()
            }
        }
    }
    
    private func cancelSyncTimeout() {
        syncCompletionTimer?.invalidate()
        syncCompletionTimer = nil
    }
    
    private func handleSyncTimeout() async {
        logger.warning("⚠️ Sync timeout - completing anyway")
        
        await MainActor.run {
            self.syncProgress = 1.0
            self.syncMessage = "Ready"
            self.syncCompleted = true
            self.isSyncing = false
            self.needsInitialSync = false
        }
    }
    
    // MARK: - Reset for Testing
    
    func resetSyncState() {
        isSyncing = false
        syncCompleted = false
        syncProgress = 0.0
        syncMessage = "Checking for updates..."
        needsInitialSync = true
    }
}
