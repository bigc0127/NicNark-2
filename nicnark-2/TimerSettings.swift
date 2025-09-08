//
//  TimerSettings.swift
//  nicnark-2
//
//  Timer duration configuration for v2.0
//

import Foundation
import SwiftUI

enum TimerDuration: Int, CaseIterable {
    case thirtyMinutes = 30
    case fortyFiveMinutes = 45
    case sixtyMinutes = 60
    
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
    
    var timeInterval: TimeInterval {
        return TimeInterval(self.rawValue * 60)
    }
    
    static var defaultDuration: TimerDuration {
        return .thirtyMinutes
    }
}

@MainActor
class TimerSettings: ObservableObject {
    static let shared = TimerSettings()
    
    private let userDefaultsKey = "selectedTimerDuration"
    
    @Published var selectedDuration: TimerDuration {
        didSet {
            UserDefaults.standard.set(selectedDuration.rawValue, forKey: userDefaultsKey)
        }
    }
    
    init() {
        let savedValue = UserDefaults.standard.integer(forKey: userDefaultsKey)
        if let duration = TimerDuration(rawValue: savedValue) {
            self.selectedDuration = duration
        } else {
            self.selectedDuration = .defaultDuration
        }
    }
    
    var currentTimerInterval: TimeInterval {
        return selectedDuration.timeInterval
    }
}

// Update global constant to use the selected duration
var FULL_RELEASE_TIME: TimeInterval {
    return TimerSettings.shared.currentTimerInterval
}
