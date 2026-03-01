//
//  NotificationScheduler.swift
//  nicnark-2
//
//  Centralized notification scheduling and management
//

import Foundation
import Combine
import UserNotifications
import CoreData
import os.log

@MainActor
class NotificationScheduler: ObservableObject {
    static let shared = NotificationScheduler()
    private let logger = Logger(subsystem: "com.nicnark.nicnark-2", category: "NotificationScheduler")
    private let settings = NotificationSettings.shared
    private let alertTracker = InventoryAlertTracker.self
    
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
            
            // Collect all valid can IDs for cleanup
            let allCansRequest: NSFetchRequest<Can> = Can.fetchRequest()
            let allCans = try context.fetch(allCansRequest)
            let validCanIds = Set(allCans.map { $0.objectID.uriRepresentation().absoluteString })
            
            // Clean up stale alert records
            alertTracker.purge(matching: validCanIds)
            
            for can in lowInventoryCans {
                let canId = can.objectID.uriRepresentation().absoluteString
                let notificationId = "\(canInventoryPrefix)\(canId)"
                
                // Check if we've already notified about this can
                let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
                let alreadyScheduled = pending.contains { $0.identifier == notificationId }
                
                // Check 24-hour cooldown period
                let canShowAlert = alertTracker.canShowAlert(for: canId)
                
                if !alreadyScheduled && canShowAlert {
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
                    
                    // Record that we sent an alert for this can
                    alertTracker.recordAlert(for: canId)
                    
                    logger.info("Scheduled low inventory alert for \(can.brand ?? "unknown") (ID: \(canId))")
                } else if alreadyScheduled {
                    logger.debug("Skipped inventory alert for \(can.brand ?? "unknown") - already scheduled")
                } else {
                    logger.debug("Skipped inventory alert for \(can.brand ?? "unknown") - within 24h cooldown")
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
        // Use the comprehensive nicotine calculator that includes decay from removed pouches
        let calculator = NicotineCalculator()
        
        // Get current level and project future levels to find boundary crossings
        let projection = await calculator.projectNicotineLevels(
            context: context,
            settings: settings
        )
        
        logger.info("Current nicotine level: \(String(format: "%.3f", projection.currentLevel))mg")
        
        // Check if user is currently outside their target range (immediate alert)
        let currentLevel = projection.currentLevel
        
        if settings.shouldAlertForLowNicotine(currentLevel: currentLevel) {
            await scheduleImmediateNicotineLevelAlert(
                title: "Nicotine Level Low",
                body: String(format: "Your nicotine level (%.2fmg) is below your target range (%.1f-%.1fmg)", 
                             currentLevel, settings.nicotineRangeLow, settings.nicotineRangeHigh),
                isLowAlert: true
            )
            return
        } else if settings.shouldAlertForHighNicotine(currentLevel: currentLevel) {
            await scheduleImmediateNicotineLevelAlert(
                title: "Nicotine Level High",
                body: String(format: "Your nicotine level (%.2fmg) is above your target range (%.1f-%.1fmg)", 
                             currentLevel, settings.nicotineRangeLow, settings.nicotineRangeHigh),
                isLowAlert: false
            )
            return
        }
        
        // Schedule future alerts for predicted boundary crossings
        var nextAlert: (date: Date, isLow: Bool, level: Double)? = nil
        
        // Check for low boundary crossing
        if let lowCrossing = projection.lowBoundaryCrossing {
            // Find the projected level at the crossing time for accurate notification text
            let crossingLevel = projection.projectedPoints.first { abs($0.timestamp.timeIntervalSince(lowCrossing)) < 300 }?.level ?? settings.effectiveLowBoundary
            nextAlert = (date: lowCrossing, isLow: true, level: crossingLevel)
        }
        
        // Check for high boundary crossing (if it's sooner than low crossing)
        if let highCrossing = projection.highBoundaryCrossing {
            let crossingLevel = projection.projectedPoints.first { abs($0.timestamp.timeIntervalSince(highCrossing)) < 300 }?.level ?? settings.effectiveHighBoundary
            
            if let existing = nextAlert {
                if highCrossing < existing.date {
                    nextAlert = (date: highCrossing, isLow: false, level: crossingLevel)
                }
            } else {
                nextAlert = (date: highCrossing, isLow: false, level: crossingLevel)
            }
        }
        
        // Schedule the next boundary crossing alert
        if let alert = nextAlert {
            let timeInterval = max(1, alert.date.timeIntervalSinceNow)
            
            // Only schedule if it's within the next 24 hours (avoid stale notifications)
            if timeInterval < 24 * 3600 {
                let content = UNMutableNotificationContent()
                
                if alert.isLow {
                    content.title = "Nicotine Level Dropping"
                    content.body = String(format: "Your nicotine level will reach %.2fmg, below your target range", alert.level)
                } else {
                    content.title = "Nicotine Level Rising"
                    content.body = String(format: "Your nicotine level will reach %.2fmg, above your target range", alert.level)
                }
                
                content.sound = .default
                content.categoryIdentifier = "NICOTINE_LEVEL"
                
                // Apply priority settings if enabled
                if UserDefaults.standard.bool(forKey: "priorityNotifications") {
                    if #available(iOS 15.0, *) {
                        content.interruptionLevel = .timeSensitive
                    }
                }
                
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: timeInterval, repeats: false)
                let request = UNNotificationRequest(identifier: usageReminderID, content: content, trigger: trigger)
                
                try? await UNUserNotificationCenter.current().add(request)
                
                let alertType = alert.isLow ? "low" : "high"
                logger.info("Scheduled \(alertType) nicotine level reminder for \(alert.date) (\(String(format: "%.1f", timeInterval/60)) mins)")
            } else {
                logger.debug("Skipped scheduling reminder - crossing time too far in future: \(alert.date)")
            }
        } else {
            logger.info("No boundary crossings predicted within projection window - no reminder scheduled")
        }
    }
    
    /// Schedules an immediate nicotine level alert for current violations
    private func scheduleImmediateNicotineLevelAlert(title: String, body: String, isLowAlert: Bool) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = "NICOTINE_LEVEL"
        
        // Apply priority settings if enabled
        if UserDefaults.standard.bool(forKey: "priorityNotifications") {
            if #available(iOS 15.0, *) {
                content.interruptionLevel = .timeSensitive
            }
        }
        
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: usageReminderID, content: content, trigger: trigger)
        
        try? await UNUserNotificationCenter.current().add(request)
        
        let alertType = isLowAlert ? "low" : "high"
        logger.info("Scheduled immediate \(alertType) nicotine level reminder")
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
    
    /// Calculates current comprehensive nicotine level including decay from removed pouches
    /// 
    /// **DEPRECATED**: This method previously only considered active pouches, missing decay
    /// from recently removed pouches. Now uses NicotineCalculator for comprehensive calculation.
    private func calculateCurrentNicotineLevel(context: NSManagedObjectContext) async -> Double {
        let calculator = NicotineCalculator()
        return await calculator.calculateTotalNicotineLevel(context: context)
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
