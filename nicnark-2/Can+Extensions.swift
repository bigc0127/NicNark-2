//
//  Can+Extensions.swift
//  nicnark-2
//
//  Helper methods and computed properties for Can entity
//

import Foundation
import CoreData

extension Can {
    /// Computed property to check if the can is empty
    var isEmpty: Bool {
        return pouchCount <= 0
    }
    
    /// Computed property to get the remaining percentage of pouches
    var remainingPercentage: Double {
        guard initialCount > 0 else { return 0 }
        return Double(pouchCount) / Double(initialCount)
    }
    
    /// Use a pouch from this can
    func usePouch() {
        if pouchCount > 0 {
            pouchCount -= 1
        }
    }
}
