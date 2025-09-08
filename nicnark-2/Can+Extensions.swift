//
//  Can+Extensions.swift
//  nicnark-2
//
//  Extensions to the Can Core Data entity to add computed properties and convenience methods.
//  
//  Core Data entities are generated classes based on the .xcdatamodeld file. Extensions allow
//  us to add custom functionality without modifying the generated code.
//

import Foundation
import CoreData

/**
 * Extension to the Can Core Data entity.
 * 
 * These methods and computed properties provide convenient ways to work with
 * can inventory data without cluttering the main Core Data model definition.
 */
extension Can {
    
    /// Returns true if the can has no pouches remaining.
    /// This is useful for UI logic to hide empty cans or show "out of stock" indicators.
    var isEmpty: Bool {
        return pouchCount <= 0
    }
    
    /// Returns the percentage of pouches remaining (0.0 to 1.0).
    /// 
    /// This is calculated by dividing current pouch count by the initial count.
    /// Used for progress bars, low stock warnings, and usage analytics.
    /// 
    /// - Returns: A value between 0.0 (empty) and 1.0 (full)
    var remainingPercentage: Double {
        guard initialCount > 0 else { return 0 }  // Prevent division by zero
        return Double(pouchCount) / Double(initialCount)
    }
    
    /// Decrements the pouch count by one (consumes a pouch from this can).
    /// 
    /// This method is called when logging a pouch that came from this specific can.
    /// It safely handles the case where the can is already empty by only decrementing
    /// if pouches are available.
    /// 
    /// Note: The caller is responsible for saving the Core Data context after calling this method.
    func usePouch() {
        if pouchCount > 0 {
            pouchCount -= 1  // Subtract one pouch from inventory
        }
        // If pouchCount is already 0, do nothing (can't use pouches from an empty can)
    }
}
