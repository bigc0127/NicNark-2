// NotificationDelegate.swift (APP target)

import Foundation
import UserNotifications
import os.log
import ActivityKit

/// Do NOT make the whole type @MainActor.
/// UNUserNotificationCenterDelegate methods are not main-actor isolated.
/// Hop to the main actor only where needed.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()
    private let logger = Logger(subsystem: "com.nicnark.nicnark-2", category: "NotificationDelegate")

    // Foreground presentation while app is open.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completion: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completion([.banner, .list, .sound, .badge])
    }

    // Handle user actions or taps on notifications.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completion: @escaping () -> Void
    ) {
        let id = response.notification.request.identifier
        logger.info("Action: \(response.actionIdentifier, privacy: .public) id: \(id, privacy: .public)")

        if response.actionIdentifier == "REMOVE_POUCH_ACTION" {
            Task { @MainActor in
                NotificationManager.handlePouchRemovalAction(pouchId: id)

                // Keep badge/state aligned with current activities
                if #available(iOS 16.1, *) {
                    let count = Activity<PouchActivityAttributes>.activities.count
                    // Use a transient manager instance just to flip the published property.
                    LiveActivityManager().hasActiveNotification = (count > 0)
                }
                completion()
            }
        } else {
            completion()
        }
    }
}
