//
//  Can+CoreDataProperties.swift
//  nicnark-2
//
//  Can inventory properties for v2.0
//

import Foundation
import CoreData

extension Can {
    
    @nonobjc public class func fetchRequest() -> NSFetchRequest<Can> {
        return NSFetchRequest<Can>(entityName: "Can")
    }
    
    @NSManaged public var id: UUID?
    @NSManaged public var brand: String?
    @NSManaged public var flavor: String?
    @NSManaged public var strength: Double
    @NSManaged public var pouchCount: Int32
    @NSManaged public var initialCount: Int32
    @NSManaged public var barcode: String?
    @NSManaged public var dateAdded: Date?
    @NSManaged public var pouchLogs: NSSet?
    
}

// MARK: Generated accessors for pouchLogs
extension Can {
    
    @objc(addPouchLogsObject:)
    @NSManaged public func addToPouchLogs(_ value: PouchLog)
    
    @objc(removePouchLogsObject:)
    @NSManaged public func removeFromPouchLogs(_ value: PouchLog)
    
    @objc(addPouchLogs:)
    @NSManaged public func addToPouchLogs(_ values: NSSet)
    
    @objc(removePouchLogs:)
    @NSManaged public func removeFromPouchLogs(_ values: NSSet)
    
}

extension Can : Identifiable {
    
}
