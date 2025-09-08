//
//  NotificationScheduler.swift
//  nicnark-2
//
//  Centralized notification scheduling and management
//

import Foundation
import UserNotifications
import CoreData
import os.log

@MainActor
class NotificationScheduler: ObservableObject {
    static let shared = NotificationScheduler()
    private let logger = Logger(subsystem: "com.nicnark.nicnark-2", category: "NotificationScheduler")
    private let settings = NotificationSettings.shared
    
    // Notification identifiers
    private let canInventoryPrefix = "can.inventory."
    private let usageReminderID = "usage.reminder"
    private let dailySummaryID = "daily.summary"
    private let insightsPrefix = "insights."
    
    private init() {}
    
    // MARK: - Main Scheduling Method
    
    func scheduleAllNotifications(context: NSManagedObjectContext) {
        Task {
            // Can inventory alerts
            if settings.canLowInventoryEnabled {
                await checkCanInventory(context: context)
            }
            
            // Usage reminders
            if settings.reminderType != .disabled {
                await scheduleUsageReminder(context: context)
            }
            
            // Daily summary
            if settings.dailySummaryEnabled {
                scheduleDailySummary(context: context)
            }
            
            // Usage insights
            if settings.insightsEnabled {
                await checkUsageInsights(context: context)
            }
        }
    }
    
    // MARK: - Can Inventory Alerts
    
    func checkCanInventory(context: NSManagedObjectContext) async {
        let request: NSFetchRequest<Can> = Can.fetchRequest()
        request.predicate = NSPredicate(format: "pouchCount > 0 AND pouchCount <= %d", settings.canLowInventoryThreshold)
        
        do {
            let lowInventoryCans = try context.fetch(request)
            
            for can in lowInventoryCans {
                let canId = can.objectID.uriRepresentation().absoluteString
                let notificationId = "\(canInventoryPrefix)\(canId)"
                
                // Check if we've already notified about this can
                let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
                let alreadyScheduled = pending.contains { $0.identifier == notificationId }
                
                if !alreadyScheduled {
                    let content = UNMutableNotificationContent()
                    content.title = "Low Inventory Alert"
                    content.body = "\(can.brand ?? "Can") \(can.flavor ?? "") has only \(can.pouchCount) pouches remaining"
                    content.sound = .default
                    content.categoryIdentifier = "CAN_INVENTORY"
                    
                    if UserDefaults.standard.bool(forKey: "priorityNotifications") {
                        if #available(iOS 15.0, *) {
                            content.interruptionLevel = .timeSensitive
                        }
                    }
                    
                    let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
                    let request = UNNotificationRequest(identifier: notificationId, content: content, trigger: trigger)
                    
                    try? await UNUserNotificationCenter.current().add(request)
                    logger.info("Scheduled low inventory alert for \(can.brand ?? "unknown")")
                }
            }
        } catch {
            logger.error("Failed to check can inventory: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Usage Reminders
    
    func scheduleUsageReminder(context: NSManagedObjectContext) async {
        // Cancel existing reminder
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [usageReminderID])
        
        switch settings.reminderType {
        case .timeBased:
            await scheduleTimeBasedReminder(context: context)
        case .nicotineLevelBased:
            await scheduleNicotineLevelReminder(context: context)
        case .disabled:
            break
        }
    }
    
    private func scheduleTimeBasedReminder(context: NSManagedObjectContext) async {
        // Check when last pouch was used
        let request: NSFetchRequest<PouchLog> = PouchLog.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(keyPath: \PouchLog.insertionTime, ascending: false)]
        request.fetchLimit = 1
        
        do {
            let lastPouch = try context.fetch(request).first
            let lastUseTime = lastPouch?.insertionTime ?? Date.distantPast
            let interval = settings.getEffectiveReminderInterval()
            let nextReminderTime = lastUseTime.addingTimeInterval(interval)
            
            if nextReminderTime > Date() {
                let content = UNMutableNotificationContent()
                content.title = "Time for a Pouch"
                content.body = "It's been \(formatInterval(interval)) since your last pouch"
                content.sound = .default
                content.categoryIdentifier = "USAGE_REMINDER"
                
                let triggerInterval = nextReminderTime.timeIntervalSinceNow
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, triggerInterval), repeats: false)
                let request = UNNotificationRequest(identifier: usageReminderID, content: content, trigger: trigger)
                
                try? await UNUserNotificationCenter.current().add(request)
                logger.info("Scheduled time-based reminder for \(nextReminderTime)")
            }
        } catch {
            logger.error("Failed to schedule time-based reminder: \(error.localizedDescription)")
        }
    }
    
    private func scheduleNicotineLevelReminder(context: NSManagedObjectContext) async {
        // Calculate current nicotine level
        let currentLevel = await calculateCurrentNicotineLevel(context: context)
        
        if settings.shouldAlertForLowNicotine(currentLevel: currentLevel) {
            let content = UNMutableNotificationContent()
            content.title = "Nicotine Level Low"
            content.body = String(format: "Your nicotine level (%.1fmg) is approaching the lower limit of your target range", currentLevel)
            content.sound = .default
            content.categoryIdentifier = "NICOTINE_LEVEL"
            
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            let request = UNNotificationRequest(identifier: usageReminderID, content: content, trigger: trigger)
            
            try? await UNUserNotificationCenter.current().add(request)
            logger.info("Scheduled low nicotine level reminder")
        } else if settings.shouldAlertForHighNicotine(currentLevel: currentLevel) {
            let content = UNMutableNotificationContent()
            content.title = "Nicotine Level High"
            content.body = String(format: "Your nicotine level (%.1fmg) is above your target range", currentLevel)
            content.sound = .default
            content.categoryIdentifier = "NICOTINE_LEVEL"
            
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            let request = UNNotificationRequest(identifier: usageReminderID, content: content, trigger: trigger)
            
            try? await UNUserNotificationCenter.current().add(request)
            logger.info("Scheduled high nicotine level reminder")
        }
    }
    
    // MARK: - Daily Summary
    
    func scheduleDailySummary(context: NSManagedObjectContext) {
        // Cancel existing summary
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [dailySummaryID])
        
        Task {
            let stats = await calculateDailyStats(context: context, forPreviousDay: settings.dailySummaryShowPreviousDay)
            
            let content = UNMutableNotificationContent()
            content.title = settings.dailySummaryShowPreviousDay ? "Yesterday's Summary" : "Today's Summary"
            content.body = "Pouches: \(stats.pouchCount) | Nicotine: \(String(format: "%.1f", stats.totalNicotine))mg | Avg: \(String(format: "%.1f", stats.averageStrength))mg"
            content.sound = .default
            content.categoryIdentifier = "DAILY_SUMMARY"
            content.userInfo = [
                "pouchCount": stats.pouchCount,
                "totalNicotine": stats.totalNicotine,
                "averageStrength": stats.averageStrength
            ]
            
            // Schedule for the specified time
            let calendar = Calendar.current
            var dateComponents = calendar.dateComponents([.hour, .minute], from: settings.dailySummaryDate)
            
            // If showing previous day summary, schedule for tomorrow at the specified time
            if !settings.dailySummaryShowPreviousDay {
                dateComponents.day = calendar.component(.day, from: Date())
            }
            
            let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
            let request = UNNotificationRequest(identifier: dailySummaryID, content: content, trigger: trigger)
            
            do {
                try await UNUserNotificationCenter.current().add(request)
                logger.info("Scheduled daily summary for \(dateComponents.hour ?? 0):\(dateComponents.minute ?? 0)")
            } catch {
                logger.error("Failed to schedule daily summary: \(error.localizedDescription)")
            }
        }
    }
    
    // MARK: - Usage Insights
    
    func checkUsageInsights(context: NSManagedObjectContext) async {
        let currentPeriodUsage = await calculatePeriodUsage(context: context, period: settings.insightsPeriod.timeInterval)
        let averageUsage = await calculateAverageUsage(context: context, period: settings.insightsPeriod.timeInterval)
        
        let percentageIncrease = averageUsage > 0 ? ((currentPeriodUsage - averageUsage) / averageUsage) * 100 : 0
        
        if percentageIncrease >= settings.insightsThresholdPercentage {
            let notificationId = "\(insightsPrefix)\(Date().timeIntervalSince1970)"
            
            let content = UNMutableNotificationContent()
            content.title = "Usage Trend Alert"
            content.body = String(format: "Your usage in the last %@ is %.0f%% above normal (%.1fmg vs %.1fmg average)",
                                 settings.insightsPeriod.displayName,
                                 percentageIncrease,
                                 currentPeriodUsage,
                                 averageUsage)
            content.sound = .default
            content.categoryIdentifier = "USAGE_INSIGHTS"
            
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            let request = UNNotificationRequest(identifier: notificationId, content: content, trigger: trigger)
            
            try? await UNUserNotificationCenter.current().add(request)
            logger.info("Scheduled usage insight alert: \(percentageIncrease)% increase")
        }
    }
    
    // MARK: - Helper Methods
    
    private func calculateCurrentNicotineLevel(context: NSManagedObjectContext) async -> Double {
        let request: NSFetchRequest<PouchLog> = PouchLog.fetchRequest()
        request.predicate = NSPredicate(format: "removalTime == nil")
        
        do {
            let activePouches = try context.fetch(request)
            var totalLevel = 0.0
            
            for pouch in activePouches {
                guard let insertionTime = pouch.insertionTime else { continue }
                let elapsed = Date().timeIntervalSince(insertionTime)
                let level = AbsorptionConstants.shared.calculateCurrentNicotineLevel(
                    nicotineContent: pouch.nicotineAmount,
                    elapsedTime: elapsed
                )
                totalLevel += level
            }
            
            return totalLevel
        } catch {
            logger.error("Failed to calculate nicotine level: \(error.localizedDescription)")
            return 0
        }
    }
    
    private func calculateDailyStats(context: NSManagedObjectContext, forPreviousDay: Bool) async -> (pouchCount: Int, totalNicotine: Double, averageStrength: Double) {
        let calendar = Calendar.current
        let now = Date()
        let startOfDay = forPreviousDay 
            ? calendar.startOfDay(for: calendar.date(byAdding: .day, value: -1, to: now)!)
            : calendar.startOfDay(for: now)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!
        
        let request: NSFetchRequest<PouchLog> = PouchLog.fetchRequest()
        request.predicate = NSPredicate(format: "insertionTime >= %@ AND insertionTime < %@", startOfDay as NSDate, endOfDay as NSDate)
        
        do {
            let pouches = try context.fetch(request)
            let count = pouches.count
            let total = pouches.reduce(0) { $0 + $1.nicotineAmount }
            let average = count > 0 ? total / Double(count) : 0
            
            return (count, total, average)
        } catch {
            logger.error("Failed to calculate daily stats: \(error.localizedDescription)")
            return (0, 0, 0)
        }
    }
    
    private func calculatePeriodUsage(context: NSManagedObjectContext, period: TimeInterval) async -> Double {
        let startTime = Date().addingTimeInterval(-period)
        
        let request: NSFetchRequest<PouchLog> = PouchLog.fetchRequest()
        request.predicate = NSPredicate(format: "insertionTime >= %@", startTime as NSDate)
        
        do {
            let pouches = try context.fetch(request)
            return pouches.reduce(0) { $0 + $1.nicotineAmount }
        } catch {
            logger.error("Failed to calculate period usage: \(error.localizedDescription)")
            return 0
        }
    }
    
    private func calculateAverageUsage(context: NSManagedObjectContext, period: TimeInterval) async -> Double {
        // Calculate average over the last 7 days
        let periods = 7
        var totalUsage = 0.0
        
        for i in 1...periods {
            let startTime = Date().addingTimeInterval(-period * Double(i + 1))
            let endTime = Date().addingTimeInterval(-period * Double(i))
            
            let request: NSFetchRequest<PouchLog> = PouchLog.fetchRequest()
            request.predicate = NSPredicate(format: "insertionTime >= %@ AND insertionTime < %@", 
                                           startTime as NSDate, endTime as NSDate)
            
            do {
                let pouches = try context.fetch(request)
                totalUsage += pouches.reduce(0) { $0 + $1.nicotineAmount }
            } catch {
                logger.error("Failed to calculate average usage: \(error.localizedDescription)")
            }
        }
        
        return totalUsage / Double(periods)
    }
    
    private func formatInterval(_ interval: TimeInterval) -> String {
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        
        if hours > 0 && minutes > 0 {
            return "\(hours)h \(minutes)m"
        } else if hours > 0 {
            return "\(hours) hour\(hours > 1 ? "s" : "")"
        } else {
            return "\(minutes) minute\(minutes > 1 ? "s" : "")"
        }
    }
}
