//
// LogService.swift
// nicnark-2
//
// Centralized service for logging nicotine pouch usage.
// This is the single entry point for creating new PouchLog entries regardless of how the user initiates logging:
// - Manual logging through the UI
// - URL scheme calls (nicnark2://log?mg=6)
// - Siri Shortcuts / iOS Shortcuts app
// - Widget interactions
//
// The service handles all side effects of logging including:
// - Creating/updating custom dosage buttons
// - Triggering CloudKit sync
// - Starting Live Activities (iOS 16.1+)
// - Scheduling completion notifications
// - Updating widgets
// - Managing can inventory
//

import Foundation
import CoreData
import WidgetKit

/**
 * LogService: A utility enum (no instances) that provides static methods for pouch logging.
 * 
 * @MainActor ensures all methods run on the main thread since they interact with Core Data's
 * main context and trigger UI updates (widgets, notifications, Live Activities).
 */
@MainActor
enum LogService {
    
    /// The default dosage amounts (3mg, 6mg) that are always available.
    /// Custom buttons are NOT created for these predefined amounts to avoid duplicates.
    private static let predefinedAmounts: Set<Double> = [3.0, 6.0]
    
/**
     * Creates a CustomButton entity for non-standard dosage amounts.
     * 
     * Custom buttons allow users to quickly select frequently-used dosages that aren't
     * part of the default 3mg/6mg options. For example, if a user logs 4mg, a custom
     * button for 4mg will be created so they can easily select it again.
     * 
     * - Parameter amount: The nicotine amount in milligrams
     * - Parameter ctx: Core Data context for database operations
     */
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
    
    /**
     * The main pouch logging function - this is THE method that creates new pouch entries.
     * 
     * This function:
     * 1. Checks if there's already an active pouch (prevents double-logging)
     * 2. Creates a custom dosage button if needed
     * 3. Creates and saves a new PouchLog to Core Data
     * 4. Associates the pouch with a can (if provided) and decrements can inventory
     * 5. Triggers CloudKit sync to share data across devices
     * 6. Starts a Live Activity for real-time tracking (iOS 16.1+)
     * 7. Schedules a completion notification
     * 8. Updates widgets immediately
     * 9. Checks for low inventory alerts
     * 
     * - Parameter mg: Nicotine amount in milligrams (e.g., 3.0, 6.0)
     * - Parameter ctx: Core Data managed object context for database operations
     * - Parameter can: Optional Can object if this pouch came from tracked inventory
     * - Parameter customDuration: Optional custom absorption time (defaults to 30 minutes)
     * - Returns: true if logging succeeded, false if failed or blocked
     */
    @discardableResult
    static func logPouch(amount mg: Double, ctx: NSManagedObjectContext, can: Can? = nil, customDuration: TimeInterval? = nil) -> Bool {
        // STEP 1: Prevent double-logging by checking for existing active pouches
        // An active pouch is one without a removalTime (user hasn't marked it as removed)
        let activePouchFetch: NSFetchRequest<PouchLog> = PouchLog.fetchRequest()
        activePouchFetch.predicate = NSPredicate(format: "removalTime == nil")
        activePouchFetch.fetchLimit = 1
        
        if let existingActivePouches = try? ctx.fetch(activePouchFetch), !existingActivePouches.isEmpty {
            print("⚠️ Cannot log new pouch: Active pouch already exists")
            return false  // Exit early - only one active pouch allowed at a time
        }
        
        // STEP 2: Create custom dosage button for this amount (if not 3mg/6mg)
        ensureCustomButton(for: mg, in: ctx)
        
        // STEP 3: Create the new PouchLog entity
        let pouch = PouchLog(context: ctx)
        pouch.pouchId = UUID()           // Unique ID for CloudKit sync and cross-device identity
        pouch.insertionTime = .now       // When the pouch was inserted (current timestamp)
        pouch.nicotineAmount = mg        // How much nicotine (e.g., 3.0, 6.0)
        
        // STEP 4: Determine absorption duration (how long the pouch should be tracked)
        // Priority: customDuration > can's custom duration > default 30 minutes
        let canDuration = can?.duration ?? 0  // Duration from can settings (in minutes)
        let durationMinutes = Int32((customDuration ?? (canDuration > 0 ? TimeInterval(canDuration * 60) : FULL_RELEASE_TIME)) / 60)
        pouch.timerDuration = durationMinutes  // Store in Core Data as minutes
        
        // STEP 5: Link to inventory and decrement pouch count (if logging from a tracked can)
        if let can = can {
            can.addToPouchLogs(pouch)  // Create relationship: this pouch belongs to this can
            can.usePouch()             // Subtract one pouch from the can's inventory count
            print("📦 Used pouch from can \(can.brand ?? "Unknown") - remaining: \(can.pouchCount)")
        }
        
        // STEP 6: Save to Core Data and trigger CloudKit sync for cross-device sharing
        do {
            try ctx.save()
            print("✅ PouchLog saved successfully: \(mg)mg at \(Date().formatted(.dateTime.hour().minute()))")
            
            // Immediately trigger CloudKit sync so other devices see this pouch
            // Using multiple sync methods for maximum reliability
            Task {
                // Method 1: Core Data's built-in CloudKit sync
                await PersistenceController.shared.triggerCloudKitSync()
                
                // Method 2: Custom sync manager (iOS 16.1+ for better Live Activity coordination)
                if #available(iOS 16.1, *) {
                    await CloudKitSyncManager.shared.triggerManualSync()
                }
            }
        } catch {
            print("❌ Failed to save PouchLog: \(error)")
            print("❌ Error details: \(error.localizedDescription)")
            return false
        }
        
        // STEP 7: Calculate final duration in seconds for Live Activities and notifications
        // Convert can duration from minutes to seconds if needed
        let duration = customDuration ?? (canDuration > 0 ? TimeInterval(canDuration * 60) : FULL_RELEASE_TIME)
        
        // STEP 8: Start Live Activity for real-time tracking (iOS 16.1+)
        // Live Activities show on the Lock Screen and Dynamic Island with a countdown timer
        // 
        // CRITICAL: We pass the pouch's actual insertion time from Core Data to ensure the
        // Live Activity countdown matches exactly what's displayed in-app and in widgets.
        // Without this, the timer would restart from 30 minutes whenever the activity refreshes.
        if #available(iOS 16.1, *) {
            // Use UUID as identifier for consistency across devices and app launches
            let pouchId = pouch.pouchId?.uuidString ?? pouch.objectID.uriRepresentation().absoluteString
            Task {
                _ = await LiveActivityManager.startLiveActivity(
                    for: pouchId, 
                    nicotineAmount: mg,
                    insertionTime: pouch.insertionTime,  // Pass actual insertion time for accurate countdown
                    duration: duration  // How long the absorption should take
                )
            }
        }
        
        // STEP 9: Schedule completion notification to alert user when absorption is done
        let pouchId = pouch.pouchId?.uuidString ?? pouch.objectID.uriRepresentation().absoluteString
        let fireDate = Date().addingTimeInterval(duration)  // When to show the notification
        NotificationManager.scheduleCompletionAlert(
            id: pouchId,                                     // Unique ID to cancel later if needed
            title: "Absorption complete",                   // Notification title
            body: "Your \(Int(mg))mg pouch has finished absorbing.",  // Notification body
            fireDate: fireDate                              // Exactly when to fire
        )
        
        // STEP 10: Post notification for any observers (like UI components that need to refresh)
        // This is Swift's NotificationCenter, NOT push notifications
        NotificationCenter.default.post(name: NSNotification.Name("PouchLogged"),
                                      object: nil,
                                      userInfo: ["mg": mg])  // Pass the dosage amount to observers
        
        // STEP 11: Update home screen widgets with the new pouch data
        updateWidgetPersistenceHelperAfterLogging(pouch: pouch, ctx: ctx)  // Store widget-specific data
        WidgetCenter.shared.reloadAllTimelines()                          // Tell iOS to refresh widgets
        
        // STEP 12: Check for additional notifications (inventory alerts, usage reminders)
        Task {
            // If we used a can, check if we're running low on pouches
            if can != nil {
                NotificationManager.checkCanInventory(context: ctx)
            }
            
            // Schedule reminders based on user's notification preferences
            NotificationManager.scheduleUsageReminder(context: ctx)
        }
        
        // STEP 13: Schedule background task to keep Live Activity updated
        // This ensures the countdown timer stays accurate even when the app is backgrounded
        if #available(iOS 16.1, *) {
            Task { await BackgroundMaintainer.shared.scheduleSoon() }
        }
        
        return true
    }
    
    // MARK: - Widget Data Management
    
    /**
     * Updates widget-specific data storage after logging a new pouch.
     * 
     * Widgets can't directly access Core Data due to iOS limitations, so we use
     * WidgetPersistenceHelper to store simplified data that widgets can read.
     * This includes current nicotine level, peak absorption, and timing info.
     * 
     * - Parameter pouch: The newly logged pouch
     * - Parameter ctx: Core Data context (unused here, but available for future enhancements)
     */
    private static func updateWidgetPersistenceHelperAfterLogging(pouch: PouchLog, ctx: NSManagedObjectContext) {
        let helper = WidgetPersistenceHelper()
        
        // Calculate initial nicotine level (since we just logged, elapsed time is essentially 0)
        let currentLevel = AbsorptionConstants.shared.calculateCurrentNicotineLevel(
            nicotineContent: pouch.nicotineAmount,
            elapsedTime: 0  // Just started, no time has passed
        )
        
        // Format display name for the widget
        let pouchName = "\(Int(pouch.nicotineAmount))mg pouch"
        
        // IMPORTANT: Use the pouch's actual duration for widget end time calculation.
        // Previously used FULL_RELEASE_TIME which could mismatch if pouch has custom duration.
        let pouchDuration = TimeInterval(pouch.timerDuration * 60)  // Convert stored minutes to seconds
        let endTime = pouch.insertionTime?.addingTimeInterval(pouchDuration)  // Accurate completion time
        
        // Store all the data widgets need to display current status
        helper.setFromLiveActivity(
            level: currentLevel,                                    // Current nicotine level
            peak: pouch.nicotineAmount * ABSORPTION_FRACTION,      // Maximum absorption (30% of total)
            pouchName: pouchName,                                  // Display name (e.g., "6mg pouch")
            endTime: endTime                                       // When the countdown ends
        )
    }
}
