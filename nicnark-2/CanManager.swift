//
//  CanManager.swift
//  nicnark-2
//
//  Can inventory management for v2.0
//

import Foundation
import CoreData
import SwiftUI

@MainActor
class CanManager: ObservableObject {
    static let shared = CanManager()
    
    @Published var activeCans: [Can] = []
    @Published var showCanSelectionSheet = false
    @Published var pendingPouchLog: PouchLog?
    
    private init() {}
    
    // MARK: - Can Operations
    
    func createCan(
        brand: String,
        flavor: String?,
        strength: Double,
        pouchCount: Int,
        barcode: String? = nil,
        context: NSManagedObjectContext
    ) -> Can {
        let can = Can(context: context)
        can.id = UUID()
        can.brand = brand
        can.flavor = flavor
        can.strength = strength
        can.pouchCount = Int32(pouchCount)
        can.initialCount = Int32(pouchCount)
        can.barcode = barcode
        can.dateAdded = Date()
        
        do {
            try context.save()
        } catch {
            print("Failed to save can: \(error)")
        }
        
        return can
    }
    
    func fetchActiveCans(context: NSManagedObjectContext) {
        let request: NSFetchRequest<Can> = Can.fetchRequest()
        request.predicate = NSPredicate(format: "pouchCount > 0")
        request.sortDescriptors = [
            NSSortDescriptor(keyPath: \Can.dateAdded, ascending: false)
        ]
        
        do {
            activeCans = try context.fetch(request)
        } catch {
            print("Failed to fetch cans: \(error)")
        }
    }
    
    func logPouchFromCan(
        can: Can,
        amount: Double,
        context: NSManagedObjectContext
    ) -> Bool {
        guard can.pouchCount > 0 else { return false }
        
        // Create the pouch log
        let success = LogService.logPouch(amount: amount, ctx: context, can: can)
        
        if success {
            // Decrement can count
            can.usePouch()
            
            do {
                try context.save()
            } catch {
                print("Failed to update can count: \(error)")
            }
        }
        
        return success
    }
    
    func deleteCan(_ can: Can, context: NSManagedObjectContext) {
        context.delete(can)
        
        do {
            try context.save()
            fetchActiveCans(context: context)
        } catch {
            print("Failed to delete can: \(error)")
        }
    }
    
    // MARK: - Barcode Operations
    
    func findCanByBarcode(_ barcode: String, context: NSManagedObjectContext) -> Can? {
        let request: NSFetchRequest<Can> = Can.fetchRequest()
        request.predicate = NSPredicate(format: "barcode == %@", barcode)
        request.fetchLimit = 1
        
        do {
            return try context.fetch(request).first
        } catch {
            print("Failed to find can by barcode: \(error)")
        }
        
        return nil
    }
    
    // MARK: - Can Selection for Shortcuts
    
    func promptForCanSelection(for pouchLog: PouchLog) {
        pendingPouchLog = pouchLog
        showCanSelectionSheet = true
    }
    
    func associatePouchWithCan(_ pouchLog: PouchLog, can: Can?, context: NSManagedObjectContext) {
        if let can = can {
            can.addToPouchLogs(pouchLog)
            can.usePouch()
        }
        
        do {
            try context.save()
        } catch {
            print("Failed to associate pouch with can: \(error)")
        }
        
        pendingPouchLog = nil
        showCanSelectionSheet = false
    }
}
