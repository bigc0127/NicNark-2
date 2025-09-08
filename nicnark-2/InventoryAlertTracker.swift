//
//  InventoryAlertTracker.swift
//  nicnark-2
//
//  Manages 24-hour cooldown periods for inventory alerts per can
//

import Foundation

struct InventoryAlertTracker {
    private static let key = "canInventoryLastAlert"
    private static let cooldownPeriod: TimeInterval = 86400 // 24 hours in seconds
    
    /// Retrieves the last alert date for a specific can ID
    static func lastAlert(for canId: String) -> Date? {
        let alertDict = UserDefaults.standard.dictionary(forKey: key) as? [String: TimeInterval] ?? [:]
        guard let timestamp = alertDict[canId] else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }
    
    /// Records that an alert was sent for a specific can ID at the given date
    static func recordAlert(for canId: String, date: Date = Date()) {
        var alertDict = UserDefaults.standard.dictionary(forKey: key) as? [String: TimeInterval] ?? [:]
        alertDict[canId] = date.timeIntervalSince1970
        UserDefaults.standard.set(alertDict, forKey: key)
    }
    
    /// Checks if enough time has elapsed since the last alert for a specific can
    static func canShowAlert(for canId: String) -> Bool {
        guard let lastAlertDate = lastAlert(for: canId) else {
            // No previous alert recorded, can show alert
            return true
        }
        
        let timeSinceLastAlert = Date().timeIntervalSince(lastAlertDate)
        return timeSinceLastAlert >= cooldownPeriod
    }
    
    /// Removes alert records for can IDs that no longer exist
    /// This helps keep the UserDefaults dictionary clean over time
    static func purge(matching validIds: Set<String>) {
        let alertDict = UserDefaults.standard.dictionary(forKey: key) as? [String: TimeInterval] ?? [:]
        let filteredDict = alertDict.filter { validIds.contains($0.key) }
        
        // Only update UserDefaults if something was actually removed
        if filteredDict.count != alertDict.count {
            UserDefaults.standard.set(filteredDict, forKey: key)
        }
    }
    
    /// Resets all alert records (useful for testing or user preference reset)
    static func reset() {
        UserDefaults.standard.removeObject(forKey: key)
    }
    
    /// Debug helper to view all stored alert timestamps
    static func getAllAlertRecords() -> [String: Date] {
        let alertDict = UserDefaults.standard.dictionary(forKey: key) as? [String: TimeInterval] ?? [:]
        return alertDict.mapValues { Date(timeIntervalSince1970: $0) }
    }
}
