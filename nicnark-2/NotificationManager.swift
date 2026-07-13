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
    private nonisolated static let logger = Logger(subsystem: "com.nicnark.nicnark-2", category: "NotificationManager")
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
    @MainActor private static var didConfigure = false

    static func configure() {
        Task { @MainActor in
            // Idempotent: configure() is called from both app init and ContentView/app
            // onAppear. Re-requesting authorization and re-scheduling on every onAppear is
            // wasted work, so run the one-time setup only once.
            guard !didConfigure else { return }
            didConfigure = true

            let center = UNUserNotificationCenter.current()

            // Set our custom delegate to handle notification interactions (taps, actions)
            center.delegate = NotificationDelegate.shared

            // Register actionable categories so action buttons (e.g. "Remove" on a pouch
            // completion alert) actually appear and route to NotificationDelegate. Without
            // this the REMOVE_POUCH_ACTION handler is unreachable.
            registerNotificationCategories(on: center)

            // Request permission to show notifications with alerts, sounds, and badge counts
            let authOptions: UNAuthorizationOptions = [.alert, .sound, .badge]
            do {
                let granted = try await center.requestAuthorization(options: authOptions)
                logger.info("Notification authorization granted: \(granted)")
                // If user granted permission, set up all notifications based on current settings
                if granted {
                    scheduleConfiguredNotifications()
                }
            } catch {
                logger.error("Notification authorization error: \(error.localizedDescription)")
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
     * Registers actionable notification categories.
     *
     * The pouch-completion alert carries a "Remove" action button (REMOVE_POUCH_ACTION),
     * handled in NotificationDelegate. A category must be registered for the button to
     * appear at all. setNotificationCategories replaces the registered set; only the
     * completion category needs registered actions — the other categories (CAN_INVENTORY,
     * USAGE_REMINDER, …) are tap-only and work without registration.
     */
    static func registerNotificationCategories(on center: UNUserNotificationCenter = .current()) {
        let removeAction = UNNotificationAction(
            identifier: "REMOVE_POUCH_ACTION",
            title: "Remove",
            options: [.destructive]
        )
        let completionCategory = UNNotificationCategory(
            identifier: "POUCH_COMPLETION",
            actions: [removeAction],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([completionCategory])
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
    // MARK: - Grouped completion alerts
    //
    // Multi-pouch batches: ONE UNNotificationRequest per proximity cluster.
    // request.identifier may be a real pouch UUID (single) or `completion.group.<uuid>`.
    // Maps: pouchId → requestId, requestId → [pouchIds], requestId → {fire, mgs}.
    // Consumers that parse identifiers: cancelAlert, handlePouchRemovalAction (Remove btn).

    private static let pouchToRequestKey = "completionAlert.pouchToRequestId"
    private static let requestMembersKey = "completionAlert.requestMembers"
    private static let requestMetaKey = "completionAlert.requestMeta"

    /// Resolve a notification request identifier (or pouch id) → pouch UUID strings to act on.
    static func pouchIds(forNotificationId id: String) -> [String] {
        pruneExpiredAlertMaps()
        let defaults = UserDefaults.standard
        let requestMembers = defaults.dictionary(forKey: requestMembersKey) as? [String: [String]] ?? [:]
        let pouchToRequest = defaults.dictionary(forKey: pouchToRequestKey) as? [String: String] ?? [:]
        if let members = requestMembers[id], !members.isEmpty { return members }
        if let req = pouchToRequest[id], let members = requestMembers[req], !members.isEmpty {
            return members
        }
        return [id]
    }

    /// Cancel pending/delivered alert for this pouch (or group id).
    /// Partial group cancel reschedules remaining **only if fire is still in the future**.
    static func cancelAlert(id: String) {
        pruneExpiredAlertMaps()
        let defaults = UserDefaults.standard
        var pouchToRequest = defaults.dictionary(forKey: pouchToRequestKey) as? [String: String] ?? [:]
        var requestMembers = defaults.dictionary(forKey: requestMembersKey) as? [String: [String]] ?? [:]
        var requestMeta = defaults.dictionary(forKey: requestMetaKey) as? [String: [String: Any]] ?? [:]

        let requestId = pouchToRequest[id] ?? id
        let c = UNUserNotificationCenter.current()
        c.removePendingNotificationRequests(withIdentifiers: [requestId, id])
        c.removeDeliveredNotifications(withIdentifiers: [requestId, id])

        // Drop this pouch from maps; may be a member id or the request id itself.
        pouchToRequest.removeValue(forKey: id)
        var members = requestMembers[requestId] ?? []
        members.removeAll { $0 == id }
        // If `id` was the request id, drop all members' reverse map entries for this request.
        if id == requestId || id.hasPrefix("completion.group.") {
            for pid in requestMembers[requestId] ?? [] {
                pouchToRequest.removeValue(forKey: pid)
            }
            members = []
        }

        if members.isEmpty {
            requestMembers.removeValue(forKey: requestId)
            requestMeta.removeValue(forKey: requestId)
            defaults.set(pouchToRequest, forKey: pouchToRequestKey)
            defaults.set(requestMembers, forKey: requestMembersKey)
            defaults.set(requestMeta, forKey: requestMetaKey)
        } else if let meta = requestMeta[requestId],
                  let fireTs = meta["fire"] as? Double,
                  let mgs = meta["mgs"] as? [String: Double] {
            let fire = Date(timeIntervalSince1970: fireTs)
            // Past-fire guard: never re-enqueue a completion banner that already fired.
            // Still prune maps + clear badge (early return used to skip trailing cleanup → sticky badge).
            guard fire.timeIntervalSinceNow > 1 else {
                for pid in members { pouchToRequest.removeValue(forKey: pid) }
                requestMembers.removeValue(forKey: requestId)
                requestMeta.removeValue(forKey: requestId)
                defaults.set(pouchToRequest, forKey: pouchToRequestKey)
                defaults.set(requestMembers, forKey: requestMembersKey)
                defaults.set(requestMeta, forKey: requestMetaKey)
                Task {
                    let delivered = await c.deliveredNotifications()
                    if delivered.isEmpty { clearBadge() }
                }
                return
            }
            let remainingItems: [(id: String, mg: Double, fireDate: Date)] = members.compactMap { pid in
                guard let mg = mgs[pid] else { return nil }
                return (pid, mg, fire)
            }
            for pid in members { pouchToRequest.removeValue(forKey: pid) }
            requestMembers.removeValue(forKey: requestId)
            requestMeta.removeValue(forKey: requestId)
            defaults.set(pouchToRequest, forKey: pouchToRequestKey)
            defaults.set(requestMembers, forKey: requestMembersKey)
            defaults.set(requestMeta, forKey: requestMetaKey)
            scheduleGroupedCompletionAlerts(remainingItems)
        } else {
            defaults.set(pouchToRequest, forKey: pouchToRequestKey)
            defaults.set(requestMembers, forKey: requestMembersKey)
            defaults.set(requestMeta, forKey: requestMetaKey)
        }

        Task {
            let delivered = await c.deliveredNotifications()
            if delivered.isEmpty { clearBadge() }
        }
    }

    /// Single-pouch completion alert. `mg` stored for group remap accuracy.
    static func scheduleCompletionAlert(id: String, title: String, body: String, fireDate: Date, mg: Double = 0) {
        let dose = mg > 0 ? mg : 0
        let resolvedBody = dose > 0
            ? "Your \(Int(dose))mg pouch has finished absorbing."
            : body
        enqueueNotificationRequest(
            id: id,
            title: title,
            body: resolvedBody,
            fireDate: fireDate,
            memberPouchIds: [id]
        )
        rememberMapping(pouchIds: [id], requestId: id, fire: fireDate, mgs: [id: dose])
    }

    /// Cluster by gap-to-previous ≤ proximity; one system notification per cluster.
    static func scheduleGroupedCompletionAlerts(
        _ items: [(id: String, mg: Double, fireDate: Date)],
        proximity: TimeInterval = 2.0
    ) {
        guard !items.isEmpty else { return }
        pruneExpiredAlertMaps()

        let sorted = items.sorted { $0.fireDate < $1.fireDate }
        var clusters: [[(id: String, mg: Double, fireDate: Date)]] = []
        var current: [(id: String, mg: Double, fireDate: Date)] = []

        for item in sorted {
            if current.isEmpty {
                current = [item]
            } else if let last = current.last, item.fireDate.timeIntervalSince(last.fireDate) <= proximity {
                current.append(item)
            } else {
                clusters.append(current)
                current = [item]
            }
        }
        if !current.isEmpty { clusters.append(current) }

        for cluster in clusters {
            let fire = cluster.map(\.fireDate).max() ?? cluster[0].fireDate
            // Skip past-due (would fire immediately as spurious "finished").
            guard fire.timeIntervalSinceNow > 1 else { continue }

            let requestId: String
            let body: String
            if cluster.count == 1 {
                requestId = cluster[0].id
                body = "Your \(Int(cluster[0].mg))mg pouch has finished absorbing."
            } else {
                requestId = "completion.group.\(UUID().uuidString)"
                let totalMg = cluster.reduce(0.0) { $0 + $1.mg }
                body = "Your \(cluster.count) pouches (\(Int(totalMg.rounded()))mg) have finished absorbing."
            }
            let memberIds = cluster.map(\.id)
            enqueueNotificationRequest(
                id: requestId,
                title: "Absorption complete",
                body: body,
                fireDate: fire,
                memberPouchIds: memberIds
            )
            var mgs: [String: Double] = [:]
            for p in cluster { mgs[p.id] = p.mg }
            rememberMapping(pouchIds: memberIds, requestId: requestId, fire: fire, mgs: mgs)
        }
    }

    private static func enqueueNotificationRequest(
        id: String,
        title: String,
        body: String,
        fireDate: Date,
        memberPouchIds: [String]
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.badge = 1
        content.categoryIdentifier = "POUCH_COMPLETION"
        // So REMOVE_POUCH_ACTION can resolve group → member pouch UUIDs without UserDefaults.
        content.userInfo = [
            "requestId": id,
            "pouchIds": memberPouchIds
        ]

        if UserDefaults.standard.bool(forKey: "priorityNotifications") {
            content.interruptionLevel = .timeSensitive
            content.relevanceScore = 1.0
        }

        let interval = max(1, fireDate.timeIntervalSinceNow)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                logger.error("scheduleCompletionAlert failed: \(error.localizedDescription)")
            }
        }
    }

    private static func rememberMapping(
        pouchIds: [String],
        requestId: String,
        fire: Date,
        mgs: [String: Double]
    ) {
        let defaults = UserDefaults.standard
        var pouchToRequest = defaults.dictionary(forKey: pouchToRequestKey) as? [String: String] ?? [:]
        var requestMembers = defaults.dictionary(forKey: requestMembersKey) as? [String: [String]] ?? [:]
        var requestMeta = defaults.dictionary(forKey: requestMetaKey) as? [String: [String: Any]] ?? [:]

        for pid in pouchIds {
            if let old = pouchToRequest[pid], old != requestId {
                UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [old])
            }
            pouchToRequest[pid] = requestId
        }
        requestMembers[requestId] = pouchIds
        requestMeta[requestId] = [
            "fire": fire.timeIntervalSince1970,
            "mgs": mgs
        ]
        defaults.set(pouchToRequest, forKey: pouchToRequestKey)
        defaults.set(requestMembers, forKey: requestMembersKey)
        defaults.set(requestMeta, forKey: requestMetaKey)
    }

    /// Drop map entries whose fire time is in the past (natural fire or stale CloudKit).
    private static func pruneExpiredAlertMaps() {
        let defaults = UserDefaults.standard
        var pouchToRequest = defaults.dictionary(forKey: pouchToRequestKey) as? [String: String] ?? [:]
        var requestMembers = defaults.dictionary(forKey: requestMembersKey) as? [String: [String]] ?? [:]
        var requestMeta = defaults.dictionary(forKey: requestMetaKey) as? [String: [String: Any]] ?? [:]
        let now = Date().timeIntervalSince1970
        var dirty = false
        for (reqId, meta) in requestMeta {
            guard let fireTs = meta["fire"] as? Double else { continue }
            if fireTs + 60 < now { // 60s grace after fire
                for pid in requestMembers[reqId] ?? [] {
                    pouchToRequest.removeValue(forKey: pid)
                }
                requestMembers.removeValue(forKey: reqId)
                requestMeta.removeValue(forKey: reqId)
                dirty = true
            }
        }
        if dirty {
            defaults.set(pouchToRequest, forKey: pouchToRequestKey)
            defaults.set(requestMembers, forKey: requestMembersKey)
            defaults.set(requestMeta, forKey: requestMetaKey)
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
    /// - Parameter notificationId: UNNotificationRequest.identifier — either a pouch UUID
    ///   or `completion.group.<uuid>`. Never treat group ids as Core Data pouchIds.
    static func handlePouchRemovalAction(pouchId notificationId: String) {
        logger.info("Handling pouch removal for notification id: \(notificationId)")

        let ids = pouchIds(forNotificationId: notificationId)
        // Cancel group/request once (maps all members) before batch remove.
        cancelAlert(id: notificationId)

        Task { @MainActor in
            let ctx = PersistenceController.shared.container.viewContext
            // One save + one LA/widget/watch pass — not N× removePouch side effects.
            _ = await PouchRemovalService.removePouches(withIds: ids, in: ctx)
            clearBadge()
        }
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
    @MainActor private static var rescheduleTask: Task<Void, Never>?

    static func rescheduleNotifications() {
        Task { @MainActor in
            // Debounce: settings sliders/steppers fire onChange many times per drag, and each
            // reschedule re-runs the projection + inventory + daily-summary scheduling. Coalesce
            // a burst into a single reschedule once the edits settle.
            rescheduleTask?.cancel()
            rescheduleTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000)
                if Task.isCancelled { return }
                scheduleConfiguredNotifications()
            }
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
