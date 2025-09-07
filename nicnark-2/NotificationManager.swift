// NotificationManager.swift

import Foundation
import UserNotifications
import WidgetKit
import os.log

enum NotificationManager {
    private static let logger = Logger(subsystem: "com.nicnark.nicnark-2", category: "NotificationManager")
    private static let widgetKind = "AbsorptionTimerWidget"

    // Configure at app launch
    static func configure() {
        let center = UNUserNotificationCenter.current()
        Task { @MainActor in
            center.delegate = NotificationDelegate.shared
        }
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    // iOS17+ badge API
    static func clearBadge() {
        Task { @MainActor in
            do { try await UNUserNotificationCenter.current().setBadgeCount(0) }
            catch { logger.error("Failed to clear badge: \(error.localizedDescription)") }
        }
    }

    static func cancelAllNotifications() {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
        clearBadge()
    }

    static func cancelAlert(id: String) {
        let c = UNUserNotificationCenter.current()
        c.removePendingNotificationRequests(withIdentifiers: [id])
        c.removeDeliveredNotifications(withIdentifiers: [id])
        
        // Clear badge after removing notifications
        Task {
            // Check if there are any remaining delivered notifications
            let deliveredNotifications = await c.deliveredNotifications()
            if deliveredNotifications.isEmpty {
                // If no more notifications, clear the badge
                clearBadge()
            }
        }
    }

    static func scheduleCompletionAlert(id: String, title: String, body: String, fireDate: Date) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.badge = 1

        let interval = max(1, fireDate.timeIntervalSinceNow)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { logger.error("scheduleCompletionAlert failed: \(error.localizedDescription)") }
        }
    }

    // Convenience overload to support (pouchId, nicotineAmount)
    static func scheduleCompletionAlert(for pouchId: String, nicotineAmount mg: Double) {
        let title = "Absorption complete"
        let body = "Your \(Int(mg))mg pouch has finished absorbing."
        let fireDate = Date().addingTimeInterval(FULL_RELEASE_TIME)
        scheduleCompletionAlert(id: pouchId, title: title, body: body, fireDate: fireDate)
    }

    // Handle the “Remove pouch” action
    static func handlePouchRemovalAction(pouchId: String) {
        logger.info("Handling pouch removal: \(pouchId)")
        if #available(iOS 16.1, *) {
            Task { @MainActor in
                await LiveActivityManager.endLiveActivity(for: pouchId)
            }
        }
        cancelAlert(id: pouchId)

        Task { @MainActor in
            NotificationCenter.default.post(
                name: Notification.Name("PouchRemoved"),
                object: nil,
                userInfo: ["pouchId": pouchId]
            )
            WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
        }

        clearBadge()
    }
}
