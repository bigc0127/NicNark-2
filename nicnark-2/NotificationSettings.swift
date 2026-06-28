//
//  NotificationSettings.swift
//  nicnark-2
//
//  Centralized notification preferences and helper logic
//
//  This module defines all user-facing notification settings and
//  provides helpers to derive effective thresholds and intervals.
//
//  Features:
//  • Time-based usage reminders (configurable intervals, including custom)
//  • Nicotine-level-based reminders with target range and alert threshold
//  • Daily summary scheduling with configurable time
//  • Usage insights period and deviation threshold
//  • Can inventory low-stock alerts
//
//  The class is @MainActor to ensure settings changes update UI-bound
//  views safely. Backing storage uses @Published properties persisted to UserDefaults.
//

import Foundation
import Combine
import SwiftUI

// MARK: - Reminder Types
enum ReminderType: String, CaseIterable, Codable {
    case timeBased = "time"
    case nicotineLevelBased = "level"
    case disabled = "disabled"
    
    var displayName: String {
        switch self {
        case .timeBased: return "Time-Based"
        case .nicotineLevelBased: return "Nicotine Level-Based"
        case .disabled: return "Disabled"
        }
    }
}

enum ReminderInterval: String, CaseIterable, Codable {
    case oneHour = "1h"
    case oneAndHalfHours = "1.5h"
    case twoHours = "2h"
    case threeHours = "3h"
    case fourHours = "4h"
    case custom = "custom"
    
    var displayName: String {
        switch self {
        case .oneHour: return "Every 1 hour"
        case .oneAndHalfHours: return "Every 1.5 hours"
        case .twoHours: return "Every 2 hours"
        case .threeHours: return "Every 3 hours"
        case .fourHours: return "Every 4 hours"
        case .custom: return "Custom"
        }
    }
    
    var timeInterval: TimeInterval {
        switch self {
        case .oneHour: return 3600
        case .oneAndHalfHours: return 5400
        case .twoHours: return 7200
        case .threeHours: return 10800
        case .fourHours: return 14400
        case .custom: return 3600 // Default to 1 hour for custom
        }
    }
}

enum InsightPeriod: String, CaseIterable, Codable {
    case threeHours = "3h"
    case sixHours = "6h"
    case twelveHours = "12h"
    case twentyFourHours = "24h"
    
    var displayName: String {
        switch self {
        case .threeHours: return "3 hours"
        case .sixHours: return "6 hours"
        case .twelveHours: return "12 hours"
        case .twentyFourHours: return "24 hours"
        }
    }
    
    var timeInterval: TimeInterval {
        switch self {
        case .threeHours: return 10800
        case .sixHours: return 21600
        case .twelveHours: return 43200
        case .twentyFourHours: return 86400
        }
    }
}

// MARK: - Main Settings Class

/**
 * NotificationSettings: Central store for notification preferences.
 * 
 * Responsibilities:
 * - Persist user choices for reminders, daily summaries, and insights
 * - Provide derived values for scheduling logic (effective intervals, boundaries)
 * - Encapsulate decision-making helpers (shouldAlertForLow/HighNicotine)
 * 
 * Storage Strategy:
 * - Uses @Published properties persisted to UserDefaults (so changes are observable)
 * - Exposes Swift-friendly computed properties for enum-backed selections
 * 
 * Threading:
 * - Annotated @MainActor so property updates remain UI-safe
 */
@MainActor
class NotificationSettings: ObservableObject {
    static let shared = NotificationSettings()
    
    // NOTE: These are @Published (not @AppStorage) so that mutating them inside
    // this ObservableObject fires objectWillChange. @AppStorage only tracks
    // changes when it lives directly in a View, so as class storage it persisted
    // silently and never notified observers — leaving settings UI / .onChange
    // (rescheduleNotifications) stale. The didSet persisters keep the same
    // UserDefaults keys/values, so existing users' preferences are preserved.

    // MARK: - Can Inventory Alerts
    @Published var canLowInventoryEnabled: Bool {
        didSet { UserDefaults.standard.set(canLowInventoryEnabled, forKey: "canLowInventoryEnabled") }
    }
    @Published var canLowInventoryThreshold: Int {
        didSet { UserDefaults.standard.set(canLowInventoryThreshold, forKey: "canLowInventoryThreshold") }
    }

    // MARK: - Usage Reminders
    @Published private var reminderTypeRaw: String {
        didSet { UserDefaults.standard.set(reminderTypeRaw, forKey: "reminderType") }
    }
    var reminderType: ReminderType {
        get { ReminderType(rawValue: reminderTypeRaw) ?? .disabled }
        set { reminderTypeRaw = newValue.rawValue }
    }

    // Time-based reminders
    @Published private var reminderIntervalRaw: String {
        didSet { UserDefaults.standard.set(reminderIntervalRaw, forKey: "reminderInterval") }
    }
    var reminderInterval: ReminderInterval {
        get { ReminderInterval(rawValue: reminderIntervalRaw) ?? .oneHour }
        set { reminderIntervalRaw = newValue.rawValue }
    }
    @Published var customReminderMinutes: Int {
        didSet { UserDefaults.standard.set(customReminderMinutes, forKey: "customReminderMinutes") }
    }

    // Nicotine level-based reminders
    @Published var nicotineRangeLow: Double {
        didSet { UserDefaults.standard.set(nicotineRangeLow, forKey: "nicotineRangeLow") }
    }
    @Published var nicotineRangeHigh: Double {
        didSet { UserDefaults.standard.set(nicotineRangeHigh, forKey: "nicotineRangeHigh") }
    }
    @Published var nicotineAlertThreshold: Double {
        didSet { UserDefaults.standard.set(nicotineAlertThreshold, forKey: "nicotineAlertThreshold") }
    }

    // MARK: - Daily Summary
    @Published var dailySummaryEnabled: Bool {
        didSet { UserDefaults.standard.set(dailySummaryEnabled, forKey: "dailySummaryEnabled") }
    }
    @Published var dailySummaryTime: Double {
        didSet { UserDefaults.standard.set(dailySummaryTime, forKey: "dailySummaryTime") }
    }
    @Published var dailySummaryShowPreviousDay: Bool {
        didSet { UserDefaults.standard.set(dailySummaryShowPreviousDay, forKey: "dailySummaryShowPreviousDay") }
    }

    var dailySummaryDate: Date {
        get { Date(timeIntervalSince1970: dailySummaryTime) }
        set { dailySummaryTime = newValue.timeIntervalSince1970 }
    }

    // MARK: - Usage Insights
    @Published var insightsEnabled: Bool {
        didSet { UserDefaults.standard.set(insightsEnabled, forKey: "insightsEnabled") }
    }
    @Published private var insightsPeriodRaw: String {
        didSet { UserDefaults.standard.set(insightsPeriodRaw, forKey: "insightsPeriod") }
    }
    var insightsPeriod: InsightPeriod {
        get { InsightPeriod(rawValue: insightsPeriodRaw) ?? .sixHours }
        set { insightsPeriodRaw = newValue.rawValue }
    }
    // Alert if usage is 20% above normal
    @Published var insightsThresholdPercentage: Double {
        didSet { UserDefaults.standard.set(insightsThresholdPercentage, forKey: "insightsThresholdPercentage") }
    }

    /// Loads each stored preference from UserDefaults, falling back to the prior
    /// @AppStorage defaults so existing keys/values are preserved for current users.
    private init() {
        let defaults = UserDefaults.standard
        canLowInventoryEnabled = defaults.object(forKey: "canLowInventoryEnabled") as? Bool ?? false
        canLowInventoryThreshold = defaults.object(forKey: "canLowInventoryThreshold") as? Int ?? 5
        reminderTypeRaw = defaults.string(forKey: "reminderType") ?? ReminderType.disabled.rawValue
        reminderIntervalRaw = defaults.string(forKey: "reminderInterval") ?? ReminderInterval.oneHour.rawValue
        customReminderMinutes = defaults.object(forKey: "customReminderMinutes") as? Int ?? 60
        nicotineRangeLow = defaults.object(forKey: "nicotineRangeLow") as? Double ?? 2.5
        nicotineRangeHigh = defaults.object(forKey: "nicotineRangeHigh") as? Double ?? 3.2
        nicotineAlertThreshold = defaults.object(forKey: "nicotineAlertThreshold") as? Double ?? 0.2
        dailySummaryEnabled = defaults.object(forKey: "dailySummaryEnabled") as? Bool ?? false
        dailySummaryTime = defaults.object(forKey: "dailySummaryTime") as? Double ?? Date.now.timeIntervalSince1970
        dailySummaryShowPreviousDay = defaults.object(forKey: "dailySummaryShowPreviousDay") as? Bool ?? false
        insightsEnabled = defaults.object(forKey: "insightsEnabled") as? Bool ?? false
        insightsPeriodRaw = defaults.string(forKey: "insightsPeriod") ?? InsightPeriod.sixHours.rawValue
        insightsThresholdPercentage = defaults.object(forKey: "insightsThresholdPercentage") as? Double ?? 20.0
    }
    
    // MARK: - Helper Methods
    
    /**
     * Returns the effective reminder interval in seconds.
     * 
     * If the user selected a custom interval, converts the custom minutes
     * to seconds. Otherwise returns the pre-defined interval for the
     * selected ReminderInterval value.
     */
    func getEffectiveReminderInterval() -> TimeInterval {
        if reminderInterval == .custom {
            return TimeInterval(customReminderMinutes * 60)
        }
        return reminderInterval.timeInterval
    }
    
    /// The effective reminder interval in minutes, used for UI labels
    var effectiveReminderMinutes: Int {
        if reminderInterval == .custom {
            return customReminderMinutes
        }
        return Int(reminderInterval.timeInterval / 60)
    }
    
    /// The effective lower boundary for nicotine level alerts (target low minus threshold).
    /// If currentLevel <= this boundary, a low-level alert is warranted.
    var effectiveLowBoundary: Double {
        return nicotineRangeLow - nicotineAlertThreshold
    }
    
    /// The effective upper boundary for nicotine level alerts (target high).
    /// If currentLevel > this boundary, a high-level alert is warranted.
    var effectiveHighBoundary: Double {
        return nicotineRangeHigh
    }
    
    /// Determines if the current nicotine level should trigger a low-level alert.
    /// Fixed bug: previously used (low + threshold), now correct with (low - threshold).
    func shouldAlertForLowNicotine(currentLevel: Double) -> Bool {
        guard reminderType == .nicotineLevelBased else { return false }
        return currentLevel <= effectiveLowBoundary
    }
    
    /// Determines if the current nicotine level should trigger a high-level alert
    func shouldAlertForHighNicotine(currentLevel: Double) -> Bool {
        guard reminderType == .nicotineLevelBased else { return false }
        return currentLevel > effectiveHighBoundary
    }
}
