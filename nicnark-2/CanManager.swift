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
        
        // Also create or update CanTemplate if barcode is provided
        if let barcode = barcode, !barcode.isEmpty {
            createOrUpdateCanTemplate(
                barcode: barcode,
                brand: brand,
                flavor: flavor,
                strength: strength,
                context: context
            )
        }
        
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
        
        // Create the pouch log (LogService now handles decrementing the count)
        let success = LogService.logPouch(amount: amount, ctx: context, can: can)
        
        if success {
            // Save context to persist the count change
            do {
                try context.save()
            } catch {
                print("Failed to update can count: \(error)")
            }
        }
        
        return success
    }
    
    func deleteCan(_ can: Can, context: NSManagedObjectContext) {
        // Ensure CanTemplate is preserved before deleting can
        if let barcode = can.barcode, !barcode.isEmpty {
            createOrUpdateCanTemplate(
                barcode: barcode,
                brand: can.brand ?? "",
                flavor: can.flavor,
                strength: can.strength,
                context: context
            )
        }
        
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
    
    func findActiveCanByBarcode(_ barcode: String, context: NSManagedObjectContext) -> Can? {
        let request: NSFetchRequest<Can> = Can.fetchRequest()
        request.predicate = NSPredicate(format: "barcode == %@ AND pouchCount > 0", barcode)
        request.fetchLimit = 1
        
        do {
            return try context.fetch(request).first
        } catch {
            print("Failed to find active can by barcode: \(error)")
        }
        
        return nil
    }
    
    // MARK: - CanTemplate Operations
    
    func findCanTemplateByBarcode(_ barcode: String, context: NSManagedObjectContext) -> CanTemplate? {
        let request: NSFetchRequest<CanTemplate> = CanTemplate.fetchRequest()
        request.predicate = NSPredicate(format: "barcode == %@", barcode)
        request.fetchLimit = 1
        
        do {
            return try context.fetch(request).first
        } catch {
            print("Failed to find can template by barcode: \(error)")
        }
        
        return nil
    }
    
    func createOrUpdateCanTemplate(
        barcode: String,
        brand: String,
        flavor: String?,
        strength: Double,
        context: NSManagedObjectContext
    ) {
        let template = findCanTemplateByBarcode(barcode, context: context) ?? CanTemplate(context: context)
        
        if template.id == nil {
            template.id = UUID()
            template.barcode = barcode
            template.dateCreated = Date()
        }
        
        template.brand = brand
        template.flavor = flavor
        template.strength = strength
        template.lastUpdated = Date()
        
        do {
            try context.save()
        } catch {
            print("Failed to save can template: \(error)")
        }
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
