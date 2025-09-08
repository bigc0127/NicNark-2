//
//  Can+CoreDataClass.swift
//  nicnark-2
//
//  Can inventory entity for v2.0
//

import Foundation
import CoreData

@objc(Can)
public class Can: NSManagedObject {
    
    // Computed property for display name
    var displayName: String {
        let brandText = brand ?? "Unknown"
        let flavorText = flavor ?? ""
        let strengthText = String(format: "%.0fmg", strength)
        
        if flavorText.isEmpty {
            return "\(brandText) \(strengthText)"
        } else {
            return "\(brandText) \(flavorText) \(strengthText)"
        }
    }
    
    // Computed property for remaining pouches percentage
    var remainingPercentage: Double {
        guard initialCount > 0 else { return 0 }
        return Double(pouchCount) / Double(initialCount)
    }
    
    // Method to use a pouch from this can
    func usePouch() {
        if pouchCount > 0 {
            pouchCount -= 1
        }
    }
    
    // Method to check if can is empty
    var isEmpty: Bool {
        return pouchCount <= 0
    }
}
