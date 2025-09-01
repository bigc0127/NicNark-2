//
// LogService.swift
// nicnark-2
//
// Centralized pouch logging used by UI, URL scheme, and Shortcuts.
//

import Foundation
import CoreData
import WidgetKit

@MainActor
enum LogService {
    
    // Define the predefined button amounts that shouldn't create custom buttons
    private static let predefinedAmounts: Set<Double> = [3.0, 6.0]
    
    static func ensureCustomButton(for amount: Double, in ctx: NSManagedObjectContext) {
        // Skip creating custom buttons for predefined amounts
        guard !predefinedAmounts.contains(amount) else { return }
        
        let fetch: NSFetchRequest<CustomButton> = CustomButton.fetchRequest()
        fetch.predicate = NSPredicate(format: "nicotineAmount == %f", amount)
        fetch.fetchLimit = 1
        
        if let found = try? ctx.fetch(fetch), found.first != nil { return }
        
        let btn = CustomButton(context: ctx)
        btn.nicotineAmount = amount
        do {
            try ctx.save()
            print("✅ CustomButton saved successfully for amount: \(amount)")
        } catch {
            print("❌ Failed to save CustomButton: \(error)")
        }
    }
    
    @discardableResult
    static func logPouch(amount mg: Double, ctx: NSManagedObjectContext) -> Bool {
        // Check if there's already an active pouch (no removal time)
        let activePouchFetch: NSFetchRequest<PouchLog> = PouchLog.fetchRequest()
        activePouchFetch.predicate = NSPredicate(format: "removalTime == nil")
        activePouchFetch.fetchLimit = 1
        
        if let existingActivePouches = try? ctx.fetch(activePouchFetch), !existingActivePouches.isEmpty {
            print("⚠️ Cannot log new pouch: Active pouch already exists")
            return false
        }
        
        ensureCustomButton(for: mg, in: ctx)
        
        let pouch = PouchLog(context: ctx)
        pouch.pouchId = UUID() // Ensure UUID is set for CloudKit
        pouch.insertionTime = .now
        pouch.nicotineAmount = mg
        
        // Save with proper error handling and CloudKit sync trigger
        do {
            try ctx.save()
            print("✅ PouchLog saved successfully: \(mg)mg at \(Date().formatted(.dateTime.hour().minute()))")
            
            // Force CloudKit sync after successful save using multiple methods
            Task {
                // Method 1: Use persistence controller sync
                await PersistenceController.shared.triggerCloudKitSync()
                
                // Method 2: Use CloudKit sync manager
                if #available(iOS 16.1, *) {
                    await CloudKitSyncManager.shared.triggerManualSync()
                }
            }
        } catch {
            print("❌ Failed to save PouchLog: \(error)")
            print("❌ Error details: \(error.localizedDescription)")
            return false
        }
        
        if #available(iOS 16.1, *) {
            let pouchId = pouch.objectID.uriRepresentation().absoluteString
            Task {
                _ = await LiveActivityManager.startLiveActivity(for: pouchId, nicotineAmount: mg)
            }
        }
        
        let pouchId = pouch.objectID.uriRepresentation().absoluteString
        let fireDate = Date().addingTimeInterval(FULL_RELEASE_TIME)
        NotificationManager.scheduleCompletionAlert(
            id: pouchId,
            title: "Absorption complete",
            body: "Your \(Int(mg))mg pouch has finished absorbing.",
            fireDate: fireDate
        )
        
        NotificationCenter.default.post(name: NSNotification.Name("PouchLogged"),
                                      object: nil,
                                      userInfo: ["mg": mg])
        
        // Update widget persistence helper for immediate widget updates
        updateWidgetPersistenceHelperAfterLogging(pouch: pouch, ctx: ctx)
        
        // Reload all widget timelines to ensure immediate updates
        WidgetCenter.shared.reloadAllTimelines()
        
        // Nudge a near-term background refresh to keep the Live Activity fresh soon after start
        if #available(iOS 16.1, *) {
            Task { await BackgroundMaintainer.shared.scheduleSoon() }
        }
        
        return true
    }
    
    // MARK: - Widget Persistence Helper
    
    private static func updateWidgetPersistenceHelperAfterLogging(pouch: PouchLog, ctx: NSManagedObjectContext) {
        let helper = WidgetPersistenceHelper()
        
        // Calculate initial nicotine level (just logged, so elapsed time is minimal)
        let currentLevel = AbsorptionConstants.shared.calculateCurrentNicotineLevel(
            nicotineContent: pouch.nicotineAmount,
            elapsedTime: 0 // Just logged
        )
        
        let pouchName = "\(Int(pouch.nicotineAmount))mg pouch"
        let endTime = pouch.insertionTime?.addingTimeInterval(FULL_RELEASE_TIME)
        
        // Update the persistence helper with new pouch data
        helper.setFromLiveActivity(
            level: currentLevel,
            peak: pouch.nicotineAmount * ABSORPTION_FRACTION, // Maximum possible absorption
            pouchName: pouchName,
            endTime: endTime
        )
    }
}
