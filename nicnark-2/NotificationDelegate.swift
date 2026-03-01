// NotificationDelegate.swift (APP target)

import Foundation
import UserNotifications
import os.log
import ActivityKit
import CoreData

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
        let categoryId = response.notification.request.content.categoryIdentifier
        logger.info("Action: \(response.actionIdentifier, privacy: .public) id: \(id, privacy: .public) category: \(categoryId)")

        // Handle different notification categories
        switch categoryId {
        case "CAN_INVENTORY":
            handleCanInventoryNotification(response: response, completion: completion)
        case "USAGE_REMINDER":
            handleUsageReminderNotification(response: response, completion: completion)
        case "NICOTINE_LEVEL":
            handleNicotineLevelNotification(response: response, completion: completion)
        case "DAILY_SUMMARY":
            handleDailySummaryNotification(response: response, completion: completion)
        case "USAGE_INSIGHTS":
            handleUsageInsightsNotification(response: response, completion: completion)
        default:
            // Handle legacy pouch removal action
            if response.actionIdentifier == "REMOVE_POUCH_ACTION" {
                struct C: @unchecked Sendable { let c: () -> Void }
                let t = C(c: completion)
                Task { @MainActor in
                    NotificationManager.handlePouchRemovalAction(pouchId: id)

                    // Keep badge/state aligned with current activities
                    if #available(iOS 16.1, *) {
                        let count = Activity<PouchActivityAttributes>.activities.count
                        // Use a transient manager instance just to flip the published property.
                        LiveActivityManager().hasActiveNotification = (count > 0)
                    }
                    t.c()
                }
            } else {
                completion()
            }
        }
    }
    
    // MARK: - Category Handlers
    
    private nonisolated func handleCanInventoryNotification(response: UNNotificationResponse, completion: @escaping () -> Void) {
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            struct C: @unchecked Sendable { let c: () -> Void }
            let t = C(c: completion)
            Task { @MainActor in
                NotificationCenter.default.post(name: Notification.Name("NavigateToCanManagement"), object: nil)
                t.c()
            }
        } else {
            completion()
        }
    }

    private nonisolated func handleUsageReminderNotification(response: UNNotificationResponse, completion: @escaping () -> Void) {
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            struct C: @unchecked Sendable { let c: () -> Void }
            let t = C(c: completion)
            Task { @MainActor in
                NotificationCenter.default.post(name: Notification.Name("ShowQuickLog"), object: nil)
                t.c()
            }
        } else {
            completion()
        }
    }

    private nonisolated func handleNicotineLevelNotification(response: UNNotificationResponse, completion: @escaping () -> Void) {
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            struct C: @unchecked Sendable { let c: () -> Void }
            let t = C(c: completion)
            Task { @MainActor in
                NotificationCenter.default.post(name: Notification.Name("NavigateToNicotineLevels"), object: nil)
                t.c()
            }
        } else {
            completion()
        }
    }

    private nonisolated func handleDailySummaryNotification(response: UNNotificationResponse, completion: @escaping () -> Void) {
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            let userInfo = response.notification.request.content.userInfo
            struct Transfer: @unchecked Sendable { let userInfo: [AnyHashable: Any]; let c: () -> Void }
            let t = Transfer(userInfo: userInfo, c: completion)
            Task { @MainActor in
                NotificationCenter.default.post(name: Notification.Name("NavigateToUsageStats"), object: nil, userInfo: t.userInfo)
                t.c()
            }
        } else {
            completion()
        }
    }

    private nonisolated func handleUsageInsightsNotification(response: UNNotificationResponse, completion: @escaping () -> Void) {
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            struct C: @unchecked Sendable { let c: () -> Void }
            let t = C(c: completion)
            Task { @MainActor in
                NotificationCenter.default.post(name: Notification.Name("NavigateToUsageGraph"), object: nil)
                t.c()
            }
        } else {
            completion()
        }
    }
}
