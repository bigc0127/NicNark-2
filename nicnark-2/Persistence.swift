//
//  Persistence.swift
//  nicnark-2
//
//  Created by Connor Needling on 8/3/25.
//  Updated for CloudKit support with existing model
//

import CoreData
import CloudKit

struct PersistenceController {
    static let shared = PersistenceController()

    @MainActor
    static let preview: PersistenceController = {
        let result = PersistenceController(inMemory: true)
        let viewContext = result.container.viewContext

        // Sample data for previews using your existing model
        let samplePouch = PouchLog(context: viewContext)
        samplePouch.pouchId = UUID()
        samplePouch.insertionTime = Date()
        samplePouch.nicotineAmount = 3.0

        do {
            try viewContext.save()
        } catch {
            let nsError = error as NSError
            fatalError("Unresolved error \(nsError), \(nsError.userInfo)")
        }

        return result
    }()

    let container: NSPersistentCloudKitContainer

    init(inMemory: Bool = false) {
        container = NSPersistentCloudKitContainer(name: "nicnark_2")

        if inMemory {
            container.persistentStoreDescriptions.first!.url = URL(fileURLWithPath: "/dev/null")
        } else {
            // Configure store description for CloudKit
            guard let storeDescription = container.persistentStoreDescriptions.first else {
                fatalError("Failed to get store description")
            }
            
            // Set App Group container URL so widgets can access the same data
            if let appGroupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.ConnorNeedling.nicnark-2") {
                let storeURL = appGroupURL.appendingPathComponent("nicnark_2.sqlite")
                storeDescription.url = storeURL
                print("📱 Main app Core Data will use App Group URL: \(storeURL.path)")
            }

            // Enable history tracking and remote change notifications
            storeDescription.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
            storeDescription.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)

            // CloudKit configuration
            let cloudKitOptions = NSPersistentCloudKitContainerOptions(
                containerIdentifier: "iCloud.ConnorNeedling.nicnark-2"
            )
            storeDescription.cloudKitContainerOptions = cloudKitOptions
        }

        container.loadPersistentStores { _, error in
            if let error = error as NSError? {
                // Log instead of crashing in production; crash in DEBUG to surface issues early
                print("Core Data CloudKit error: \(error), \(error.userInfo)")
                #if DEBUG
                fatalError("Unresolved error \(error), \(error.userInfo)")
                #endif
            }
        }

        // Context configuration
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy

        // Listen for remote changes (CloudKit merges)
        NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange,
            object: container.persistentStoreCoordinator,
            queue: .main
        ) { _ in
            // Handle remote changes if needed
            print("Remote CloudKit changes detected")
        }
    }

    func save() {
        let context = container.viewContext
        if context.hasChanges {
            do {
                try context.save()
            } catch {
                let nsError = error as NSError
                print("Save error: \(nsError), \(nsError.userInfo)")
            }
        }
    }
}
