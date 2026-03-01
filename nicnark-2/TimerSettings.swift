//
//  TimerSettings.swift
//  nicnark-2
//
//  Configurable Timer Duration System for Personalized Absorption Times
//
//  This system allows users to customize how long their pouch countdown timers run.
//  Different users have different preferences and different nicotine pouches may have
//  varying absorption characteristics, so the app provides flexibility:
//
//  • 30 minutes (default) - Standard absorption time based on research
//  • 45 minutes - For users who prefer longer sessions
//  • 60 minutes - Maximum duration for slow-release or strong pouches
//
//  The setting affects:
//  • Live Activity countdown duration
//  • Completion notification timing
//  • Widget display calculations
//  • Nicotine absorption progress calculations
//  • Can-specific custom durations (if not overridden)
//

import Foundation
import Combine
import SwiftUI

/**
 * TimerDuration: Enumeration of available timer duration options.
 * 
 * Raw values are stored in minutes for easy UserDefaults persistence.
 * CaseIterable allows the settings UI to automatically list all available options.
 * Int raw values make the enum Codable and compatible with UserDefaults storage.
 */
enum TimerDuration: Int, CaseIterable {
    case thirtyMinutes = 30      // Default 30-minute absorption time
    case fortyFiveMinutes = 45   // Extended 45-minute option
    case sixtyMinutes = 60       // Maximum 60-minute duration
    
    /// Human-readable name for display in settings UI
    var displayName: String {
        switch self {
        case .thirtyMinutes:
            return "30 minutes"
        case .fortyFiveMinutes:
            return "45 minutes"
        case .sixtyMinutes:
            return "60 minutes"
        }
    }
    
    /// Converts minutes to seconds (TimeInterval) for timer calculations
    var timeInterval: TimeInterval {
        return TimeInterval(self.rawValue * 60)  // Convert minutes to seconds
    }
    
    /// The default timer duration for new users (30 minutes based on research)
    static var defaultDuration: TimerDuration {
        return .thirtyMinutes
    }
}

/**
 * TimerSettings: Manages user's preferred timer duration across the entire app.
 * 
 * This singleton class:
 * - Persists the user's timer preference in UserDefaults
 * - Notifies UI components when the setting changes via @Published
 * - Provides the current timer interval for calculations throughout the app
 * 
 * @MainActor ensures all property updates happen on the main thread (required for @Published)
 * ObservableObject allows SwiftUI views to automatically update when settings change
 */
@MainActor
class TimerSettings: ObservableObject {
    /// Shared singleton instance used throughout the app
    static let shared = TimerSettings()
    
    /// UserDefaults key for persisting the selected duration
    private let userDefaultsKey = "selectedTimerDuration"
    
    /// The user's currently selected timer duration
    /// @Published means SwiftUI views will automatically update when this changes
    /// didSet observer saves changes to UserDefaults immediately
    @Published var selectedDuration: TimerDuration {
        didSet {
            // Persist the change immediately when user selects new duration
            UserDefaults.standard.set(selectedDuration.rawValue, forKey: userDefaultsKey)
        }
    }
    
    /**
     * Initializes TimerSettings by loading the saved preference or using default.
     * 
     * This constructor:
     * 1. Attempts to load previously saved duration from UserDefaults
     * 2. Validates the saved value is still a valid TimerDuration option
     * 3. Falls back to default (30 minutes) if no valid saved value exists
     */
    init() {
        let savedValue = UserDefaults.standard.integer(forKey: userDefaultsKey)
        if let duration = TimerDuration(rawValue: savedValue) {
            // Valid saved duration found, use it
            self.selectedDuration = duration
        } else {
            // No valid saved duration, use default
            self.selectedDuration = .defaultDuration
        }
    }
    
    /// Convenience property for getting the current timer duration in seconds.
    /// Used throughout the app for timer calculations, notifications, and Live Activities.
    var currentTimerInterval: TimeInterval {
        return selectedDuration.timeInterval
    }
}
