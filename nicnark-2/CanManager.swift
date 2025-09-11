//
//  CanManager.swift
//  nicnark-2
//
//  Inventory Management System for Nicotine Pouch Cans
//
//  This manager handles all operations related to can inventory tracking:
//  - Creating and deleting cans with barcode support
//  - Tracking pouch count as users log usage
//  - Managing can templates (reusable can data for faster re-stocking)
//  - Associating pouch logs with specific cans for usage analytics
//  - Barcode scanning integration for quick can identification
//

import Foundation
import CoreData
import SwiftUI

/**
 * CanManager: Singleton class that manages can inventory throughout the app.
 * 
 * @MainActor ensures all operations run on the main thread since this class updates UI
 * ObservableObject allows SwiftUI views to automatically update when @Published properties change
 */
@MainActor
class CanManager: ObservableObject {
    /// Shared singleton instance used throughout the app
    static let shared = CanManager()
    
    /// List of cans that still have pouches remaining (automatically updates UI when changed)
    @Published var activeCans: [Can] = []
    /// Controls whether the can selection sheet is shown to the user
    @Published var showCanSelectionSheet = false
    /// Temporarily holds a pouch log while user selects which can to associate it with
    @Published var pendingPouchLog: PouchLog?
    
    /// Private initializer ensures only one instance exists (singleton pattern)
    private init() {}
    
    // MARK: - Can Operations
    
    /**
     * Creates a new can in the inventory system.
     * 
     * This method:
     * 1. Creates a new Can entity in Core Data
     * 2. Sets up all the can properties (brand, flavor, strength, etc.)
     * 3. Creates or updates a CanTemplate if a barcode is provided (for future restocking)
     * 4. Saves everything to the database
     * 
     * - Parameters:
     *   - brand: Can manufacturer (e.g., "ZYN", "Rogue")
     *   - flavor: Flavor name (e.g., "Cool Mint", "Wintergreen") - optional
     *   - strength: Nicotine strength per pouch in milligrams (e.g., 3.0, 6.0)
     *   - pouchCount: How many pouches are in this can (usually 15-20)
     *   - barcode: Scanned barcode for quick identification - optional
     *   - duration: Custom absorption time in minutes (0 = use default 30 minutes)
     *   - context: Core Data context for database operations
     * - Returns: The newly created Can object
     */
    func createCan(
        brand: String,
        flavor: String?,
        strength: Double,
        pouchCount: Int,
        barcode: String? = nil,
        duration: Int = 0,
        context: NSManagedObjectContext
    ) -> Can {
        // Create new Can entity and populate with provided data
        let can = Can(context: context)
        can.id = UUID()                        // Unique identifier for CloudKit sync
        can.brand = brand                      // Manufacturer name
        can.flavor = flavor                    // Flavor description (optional)
        can.strength = round(strength)         // Nicotine mg per pouch (rounded to avoid precision issues)
        can.pouchCount = Int32(pouchCount)     // Current remaining pouches
        can.initialCount = Int32(pouchCount)   // Original pouch count (for analytics)
        can.barcode = barcode                  // For barcode scanning (optional)
        can.dateAdded = Date()                 // When this can was added to inventory
        can.duration = Int32(duration)         // Custom timer duration in minutes
        
        // If this can has a barcode, save it as a template for easy restocking
        // Templates remember can details so users don't have to re-enter everything
        if let barcode = barcode, !barcode.isEmpty {
            createOrUpdateCanTemplate(
                barcode: barcode,
                brand: brand,
                flavor: flavor,
                strength: round(strength),  // Use rounded strength for consistency
                duration: duration,
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
    
    /**
     * Loads all cans that still have pouches remaining.
     * 
     * "Active" means pouchCount > 0. Empty cans are hidden from the main inventory view
     * but remain in the database for historical tracking. Results are sorted by date added
     * (newest first) so recently added cans appear at the top.
     * 
     * - Parameter context: Core Data context for database access
     */
    func fetchActiveCans(context: NSManagedObjectContext) {
        let request: NSFetchRequest<Can> = Can.fetchRequest()
        request.predicate = NSPredicate(format: "pouchCount > 0")  // Only cans with pouches remaining
        request.sortDescriptors = [
            NSSortDescriptor(keyPath: \Can.dateAdded, ascending: false)  // Newest cans first
        ]
        
        do {
            activeCans = try context.fetch(request)
        } catch {
            print("Failed to fetch cans: \(error)")
        }
    }
    
    /**
     * Logs a pouch from a specific can, decrementing the can's inventory.
     * 
     * This is a convenience method that combines pouch logging with inventory tracking.
     * It delegates the actual logging to LogService (which handles all the side effects)
     * then ensures the database changes are saved.
     * 
     * - Parameters:
     *   - can: The can to take a pouch from
     *   - amount: Nicotine amount in milligrams
     *   - context: Core Data context for database operations
     * - Returns: true if logging succeeded, false if can was empty or logging failed
     */
    func logPouchFromCan(
        can: Can,
        amount: Double,
        context: NSManagedObjectContext
    ) -> Bool {
        guard can.pouchCount > 0 else { return false }  // Can't log from empty can
        
        // Round amount to avoid floating-point precision issues (9.0000000001 -> 9.0)
        let roundedAmount = round(amount)
        
        // LogService handles the complete logging process including decrementing the can's count
        let success = LogService.logPouch(amount: roundedAmount, ctx: context, can: can)
        
        if success {
            // Ensure the database changes are saved (LogService already saves, but this is extra safety)
            do {
                try context.save()
            } catch {
                print("Failed to update can count: \(error)")
            }
        }
        
        return success
    }
    
    /**
     * Removes a can from the inventory.
     * 
     * Before deleting, this method preserves the can's information as a CanTemplate
     * (if it has a barcode). This allows users to quickly recreate the can when restocking
     * without re-entering all the details.
     * 
     * - Parameters:
     *   - can: The can to delete
     *   - context: Core Data context for database operations
     */
    func deleteCan(_ can: Can, context: NSManagedObjectContext) {
        // Save can details as a template for future restocking (if barcode exists)
        if let barcode = can.barcode, !barcode.isEmpty {
            createOrUpdateCanTemplate(
                barcode: barcode,
                brand: can.brand ?? "",
                flavor: can.flavor,
                strength: round(can.strength),  // Round strength to avoid precision issues
                duration: Int(can.duration),
                context: context
            )
        }
        
        context.delete(can)  // Remove from Core Data
        
        do {
            try context.save()                      // Persist the deletion
            fetchActiveCans(context: context)       // Refresh the active cans list
        } catch {
            print("Failed to delete can: \(error)")
        }
    }
    
    // MARK: - Barcode Operations
    
    /**
     * Finds any can (active or empty) with the given barcode.
     * 
     * This is useful for checking if a scanned barcode matches an existing can,
     * regardless of whether that can still has pouches.
     * 
     * - Parameters:
     *   - barcode: The barcode string to search for
     *   - context: Core Data context for database access
     * - Returns: The matching Can if found, nil otherwise
     */
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
    
    /**
     * Finds a can with the given barcode that still has pouches remaining.
     * 
     * This is used when logging pouches to find which active can to decrement.
     * Only returns cans with pouchCount > 0.
     * 
     * - Parameters:
     *   - barcode: The barcode string to search for
     *   - context: Core Data context for database access
     * - Returns: The matching active Can if found, nil if no active can matches
     */
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
    // Templates store can information for quick restocking without re-entering details
    
    /**
     * Finds a saved can template by barcode.
     * 
     * CanTemplates store can details (brand, flavor, strength) associated with barcodes.
     * When users scan a barcode, we check if we have a template to auto-fill can information.
     * 
     * - Parameters:
     *   - barcode: The barcode to search for
     *   - context: Core Data context for database access
     * - Returns: The matching CanTemplate if found, nil otherwise
     */
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
    
    /**
     * Creates a new CanTemplate or updates an existing one.
     * 
     * Templates are created automatically when:
     * 1. A user adds a can with a barcode
     * 2. A user deletes a can (to preserve the information)
     * 
     * This allows quick restocking - scan a barcode and the app remembers
     * the brand, flavor, and strength details.
     * 
     * - Parameters:
     *   - barcode: Unique barcode identifier
     *   - brand: Can manufacturer
     *   - flavor: Flavor name (optional)
     *   - strength: Nicotine strength per pouch
     *   - duration: Custom timer duration in minutes
     *   - context: Core Data context for database operations
     */
    func createOrUpdateCanTemplate(
        barcode: String,
        brand: String,
        flavor: String?,
        strength: Double,
        duration: Int = 0,
        context: NSManagedObjectContext
    ) {
        // Find existing template or create new one
        let template = findCanTemplateByBarcode(barcode, context: context) ?? CanTemplate(context: context)
        
        // If this is a new template, set up the permanent fields
        if template.id == nil {
            template.id = UUID()              // Unique ID for CloudKit
            template.barcode = barcode        // The barcode this template is for
            template.dateCreated = Date()     // When template was first created
        }
        
        // Always update the can details (in case information changed)
        template.brand = brand                  // Manufacturer name
        template.flavor = flavor               // Flavor description
        template.strength = round(strength)    // Nicotine strength (rounded to avoid precision issues)
        template.duration = Int32(duration)    // Custom timer duration
        template.lastUpdated = Date()          // Track when template was last modified
        
        do {
            try context.save()
        } catch {
            print("Failed to save can template: \(error)")
        }
    }
    
    // MARK: - Can Selection for Shortcuts
    // These methods handle retroactively associating pouch logs with cans
    
    /**
     * Shows a sheet for the user to select which can a pouch came from.
     * 
     * This is used when a pouch is logged through Shortcuts or URL schemes
     * without specifying which can it came from. The UI presents a list
     * of active cans for the user to choose from.
     * 
     * - Parameter pouchLog: The pouch log that needs can association
     */
    func promptForCanSelection(for pouchLog: PouchLog) {
        pendingPouchLog = pouchLog         // Store the pouch log temporarily
        showCanSelectionSheet = true       // Show the selection UI
    }
    
    /**
     * Associates a pouch log with a selected can and decrements the can's inventory.
     * 
     * This is called after the user selects a can from the selection sheet.
     * It creates the Core Data relationship and decrements the pouch count.
     * 
     * - Parameters:
     *   - pouchLog: The pouch log to associate
     *   - can: The selected can (nil if user chose "No Can")
     *   - context: Core Data context for database operations
     */
    func associatePouchWithCan(_ pouchLog: PouchLog, can: Can?, context: NSManagedObjectContext) {
        if let can = can {
            can.addToPouchLogs(pouchLog)  // Create Core Data relationship
            can.usePouch()                // Decrement the can's pouch count
        }
        // If can is nil, the pouch log remains unassociated (user chose "No Can")
        
        do {
            try context.save()            // Persist changes
        } catch {
            print("Failed to associate pouch with can: \(error)")
        }
        
        // Clean up the selection process
        pendingPouchLog = nil             // Clear the temporary storage
        showCanSelectionSheet = false     // Hide the selection sheet
    }
}
