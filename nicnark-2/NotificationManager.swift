// NotificationManager.swift
//
// Unified notification management system for the nicnark-2 app.
//
// This manager handles all types of notifications in the app:
// • Pouch completion alerts (when absorption timer ends)
// • Can inventory low stock warnings
// • Daily usage reminders
// • Background notification scheduling and cancellation
//
// The manager integrates with:
// • iOS UserNotifications framework for push notifications
// • WidgetKit for updating home screen widgets
// • Live Activities for Lock Screen/Dynamic Island updates
// • NotificationScheduler for advanced scheduling logic
//

import Foundation
import UserNotifications  // iOS push notifications
import WidgetKit           // Home screen widget updates
import CoreData           // Database access for scheduling logic
import os.log            // System logging

/**
 * NotificationManager: Central hub for all notification operations.
 * 
 * This enum (no instances) provides static methods for managing the app's notification system.
 * It acts as a simplified interface that other parts of the app can use without knowing
 * the complexity of UserNotifications, permissions, scheduling, and widget updates.
 */
enum NotificationManager {
    /// Logger for debugging notification-related issues
    private static let logger = Logger(subsystem: "com.nicnark.nicnark-2", category: "NotificationManager")
    /// Widget identifier for targeting widget updates
    private static let widgetKind = "AbsorptionTimerWidget"

    /**
     * Initializes the notification system at app launch.
     * 
     * This method:
     * 1. Sets up the notification delegate to handle user interactions with notifications
     * 2. Requests permission from the user to show notifications
     * 3. Schedules any configured notifications if permission is granted
     * 
     * Called from the main app delegate or app initialization.
     */
    static func configure() {
        let center = UNUserNotificationCenter.current()
        
        // Set our custom delegate to handle notification interactions (taps, actions)
        Task { @MainActor in
            center.delegate = NotificationDelegate.shared
        }
        
        // Request permission to show notifications with alerts, sounds, and badge counts
        let authOptions: UNAuthorizationOptions = [.alert, .sound, .badge]
        
        center.requestAuthorization(options: authOptions) { granted, error in
            if let error = error {
                logger.error("Notification authorization error: \(error.localizedDescription)")
            } else {
                logger.info("Notification authorization granted: \(granted)")
                
                // If user granted permission, set up all the notifications based on current settings
                if granted {
                    Task { @MainActor in
                        scheduleConfiguredNotifications()
                    }
                }
            }
        }
    }
    
    /**
     * Schedules all notifications based on current user settings and data.
     * 
     * This delegates to NotificationScheduler which handles the complex logic of:
     * - Checking user notification preferences
     * - Scanning can inventory for low stock alerts
     * - Setting up recurring usage reminders
     * - Avoiding duplicate notifications
     * 
     * @MainActor ensures this runs on the main thread for Core Data access.
     */
    @MainActor
    static func scheduleConfiguredNotifications() {
        let context = PersistenceController.shared.container.viewContext
        NotificationScheduler.shared.scheduleAllNotifications(context: context)
    }

    /**
     * Clears the red notification badge from the app icon.
     * 
     * Called when:
     * - User opens the app (badges should disappear when user sees the content)
     * - All notifications are dismissed
     * - User interacts with notifications
     * 
     * Uses the modern iOS 17+ badge API with error handling.
     */
    static func clearBadge() {
        Task { @MainActor in
            do { 
                try await UNUserNotificationCenter.current().setBadgeCount(0) 
            } catch { 
                logger.error("Failed to clear badge: \(error.localizedDescription)") 
            }
        }
    }

    /**
     * Cancels all pending and delivered notifications.
     * 
     * This removes:
     * - Pending notifications (scheduled but not yet shown)
     * - Delivered notifications (currently in notification center)
     * - The app's badge count
     * 
     * Used when user wants to reset all notifications or when app is being reset.
     */
    static func cancelAllNotifications() {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()  // Cancel future notifications
        center.removeAllDeliveredNotifications()        // Remove current notifications
        clearBadge()                                   // Clear the badge
    }

    /**
     * Cancels a specific notification by its unique identifier.
     * 
     * This removes both pending (not yet fired) and delivered (currently visible) 
     * versions of the notification. If this was the last notification, also clears the badge.
     * 
     * Used when:
     * - User manually removes a pouch (cancel the completion alert)
     * - Pouch timer is reset or modified
     * - User interacts with the notification
     * 
     * - Parameter id: Unique identifier for the notification (usually pouch UUID)
     */
    static func cancelAlert(id: String) {
        let c = UNUserNotificationCenter.current()
        c.removePendingNotificationRequests(withIdentifiers: [id])  // Cancel if not yet fired
        c.removeDeliveredNotifications(withIdentifiers: [id])       // Remove if currently visible
        
        // Smart badge management - only clear if no other notifications exist
        Task {
            let deliveredNotifications = await c.deliveredNotifications()
            if deliveredNotifications.isEmpty {
                clearBadge()  // No more notifications, so clear the badge
            }
        }
    }

    /**
     * Schedules a notification to fire at a specific future time.
     * 
     * This is the core notification scheduling method used for pouch completion alerts.
     * The notification includes:
     * - Custom title and body text
     * - Sound and badge increment
     * - Optional priority boost for better delivery
     * 
     * Priority notifications (if enabled by user) get:
     * - Time-sensitive interruption level (breaks through Focus/Do Not Disturb)
     * - Higher relevance score for iOS notification ranking
     * 
     * - Parameters:
     *   - id: Unique identifier for the notification (for later cancellation)
     *   - title: Notification title (e.g., "Absorption complete")
     *   - body: Notification body (e.g., "Your 6mg pouch has finished absorbing")
     *   - fireDate: Exact time when notification should appear
     */
    static func scheduleCompletionAlert(id: String, title: String, body: String, fireDate: Date) {
        let content = UNMutableNotificationContent()
        content.title = title        // Main notification text
        content.body = body         // Detailed message
        content.sound = .default    // Play notification sound
        content.badge = 1          // Show red badge on app icon
        
        // Check if user enabled high-priority notifications in settings
        let priorityEnabled = UserDefaults.standard.bool(forKey: "priorityNotifications")
        if priorityEnabled {
            // Set interruption level to break through Focus modes and Do Not Disturb
            if #available(iOS 15.0, *) {
                content.interruptionLevel = .timeSensitive
            }
            // Give this notification higher priority in iOS notification ranking
            content.relevanceScore = 1.0
        }

        // Calculate time until notification should fire (minimum 1 second)
        let interval = max(1, fireDate.timeIntervalSinceNow)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error { 
                logger.error("scheduleCompletionAlert failed: \(error.localizedDescription)") 
            }
        }
    }

    /**
     * Convenience method for scheduling pouch completion notifications.
     * 
     * This automatically formats the notification text and calculates the fire date
     * based on the standard absorption time (FULL_RELEASE_TIME = 30 minutes).
     * 
     * - Parameters:
     *   - pouchId: Unique identifier for the pouch (usually UUID string)
     *   - mg: Nicotine amount for the notification text (e.g., 3.0, 6.0)
     */
    static func scheduleCompletionAlert(for pouchId: String, nicotineAmount mg: Double) {
        let title = "Absorption complete"
        let body = "Your \(Int(mg))mg pouch has finished absorbing."  // Format: "Your 6mg pouch..."
        let fireDate = Date().addingTimeInterval(FULL_RELEASE_TIME)    // 30 minutes from now
        scheduleCompletionAlert(id: pouchId, title: title, body: body, fireDate: fireDate)
    }
    /**
     * Handles when a user interacts with the "Remove Pouch" notification action.
     * 
     * This comprehensive cleanup process:
     * 1. Ends the Live Activity (Lock Screen/Dynamic Island display)
     * 2. Cancels the pending completion notification
     * 3. Notifies the app UI that the pouch was removed
     * 4. Updates home screen widgets
     * 5. Clears the notification badge
     * 
     * This can be triggered by:
     * - User tapping "Remove" on a notification
     * - Notification action buttons
     * - Interactive widget actions
     * 
     * - Parameter pouchId: Unique identifier of the pouch being removed
     */
    static func handlePouchRemovalAction(pouchId: String) {
        logger.info("Handling pouch removal: \(pouchId)")

        // End Live Activity (if present) and cancel any pending completion notifications.
        if #available(iOS 16.1, *) {
            Task { @MainActor in
                await LiveActivityManager.endLiveActivity(for: pouchId)
            }
        }
        cancelAlert(id: pouchId)

        // Persist removal in Core Data so the action works even when the app UI isn't open.
        Task { @MainActor in
            let ctx = PersistenceController.shared.container.viewContext
            _ = await PouchRemovalService.removePouch(withId: pouchId, in: ctx)
        }

        // Clear notification badge
        clearBadge()
    }
    
    /**
     * Re-schedules all notifications when user changes settings.
     * 
     * Called when user modifies:
     * - Notification preferences (enable/disable types)
     * - Notification timing settings
     * - Priority notification settings
     * 
     * This ensures notifications match current user preferences.
     */
    static func rescheduleNotifications() {
        Task { @MainActor in
            scheduleConfiguredNotifications()
        }
    }
    
    /**
     * Checks can inventory levels and schedules low stock alerts if needed.
     * 
     * Called after:
     * - User logs a pouch from a can (inventory decreases)
     * - User adds/removes cans
     * - Can pouch counts are updated
     * 
     * Delegates to NotificationScheduler for the actual inventory checking logic.
     * 
     * - Parameter context: Core Data context for accessing can inventory
     */
    static func checkCanInventory(context: NSManagedObjectContext) {
        Task {
            await NotificationScheduler.shared.checkCanInventory(context: context)
        }
    }
    
    /**
     * Schedules usage reminder notifications based on user's patterns.
     * 
     * Called after pouch logging to potentially set up reminders for:
     * - Daily usage goals
     * - Spacing between pouches
     * - Regular usage patterns
     * 
     * Delegates to NotificationScheduler for the complex scheduling logic.
     * 
     * - Parameter context: Core Data context for accessing usage history
     */
    static func scheduleUsageReminder(context: NSManagedObjectContext) {
        Task {
            await NotificationScheduler.shared.scheduleUsageReminder(context: context)
        }
    }
}
