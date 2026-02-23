import Foundation
import CoreData
import WidgetKit

@MainActor
enum PouchRemovalService {
    private static var pouchesBeingRemoved: Set<String> = []

    /// Removes a specific pouch log (marks `removalTime`) and performs side effects.
    static func removePouch(_ pouch: PouchLog, in context: NSManagedObjectContext) async {
        let pouchId = pouch.pouchId?.uuidString ?? pouch.objectID.uriRepresentation().absoluteString
        await removePouch(withId: pouchId, in: context)
    }

    /// Removes a pouch by its stable ID (UUID string or Core Data URI string).
    /// Returns true if the pouch was found and removal was attempted.
    @discardableResult
    static func removePouch(withId pouchId: String, in context: NSManagedObjectContext) async -> Bool {
        guard !pouchId.isEmpty else { return false }

        // Idempotent guard: prevent duplicate removal operations
        guard !pouchesBeingRemoved.contains(pouchId) else {
            print("⚠️ Pouch removal already in progress for: \(pouchId)")
            return false
        }

        pouchesBeingRemoved.insert(pouchId)
        defer { pouchesBeingRemoved.remove(pouchId) }

        // Fetch the pouch (prefer UUID lookup)
        guard let pouch = fetchPouch(withId: pouchId, in: context) else {
            print("⚠️ Could not find pouch to remove: \(pouchId)")
            return false
        }

        // If already removed, treat as success.
        if pouch.removalTime != nil {
            return true
        }

        // End the Live Activity first (prevents background re-creation).
        if #available(iOS 16.1, *) {
            await LiveActivityManager.endLiveActivity(for: pouchId)
        }

        let removalTime = Date.now
        pouch.removalTime = removalTime

        do {
            try context.save()
        } catch {
            print("❌ Failed to save pouch removal: \(error.localizedDescription)")
            print("❌ Full error: \(error)")
        }

        // Cancel completion notification
        NotificationManager.cancelAlert(id: pouchId)

        // Update widgets snapshot + reload timelines
        await updateWidgetSnapshot(in: context)
        WidgetCenter.shared.reloadAllTimelines()

        // Nudge CloudKit
        Task {
            await PersistenceController.shared.triggerCloudKitSync()
        }

        return true
    }

    /// Removes all active pouches (`removalTime == nil`). Returns count removed.
    static func removeAllActivePouches(in context: NSManagedObjectContext) async -> Int {
        let request: NSFetchRequest<PouchLog> = PouchLog.fetchRequest()
        request.predicate = NSPredicate(format: "removalTime == nil")

        do {
            let active = try context.fetch(request)
            guard !active.isEmpty else { return 0 }

            var removedCount = 0
            for pouch in active {
                let pouchId = pouch.pouchId?.uuidString ?? pouch.objectID.uriRepresentation().absoluteString
                let removed = await removePouch(withId: pouchId, in: context)
                if removed {
                    removedCount += 1
                }
            }

            return removedCount
        } catch {
            print("❌ Failed to fetch active pouches for removal: \(error.localizedDescription)")
            return 0
        }
    }

    // MARK: - Private

    private static func fetchPouch(withId pouchId: String, in context: NSManagedObjectContext) -> PouchLog? {
        if let uuid = UUID(uuidString: pouchId) {
            let fetch: NSFetchRequest<PouchLog> = PouchLog.fetchRequest()
            fetch.predicate = NSPredicate(format: "pouchId == %@", uuid as CVarArg)
            fetch.fetchLimit = 1
            return (try? context.fetch(fetch))?.first
        }

        // Fallback: attempt to resolve as Core Data URI
        if let uri = URL(string: pouchId),
           let objectId = context.persistentStoreCoordinator?.managedObjectID(forURIRepresentation: uri) {
            return try? context.existingObject(with: objectId) as? PouchLog
        }

        return nil
    }

    private static func updateWidgetSnapshot(in context: NSManagedObjectContext) async {
        let helper = WidgetPersistenceHelper()

        // Check if there are any active pouches after removal
        let request: NSFetchRequest<PouchLog> = PouchLog.fetchRequest()
        request.predicate = NSPredicate(format: "removalTime == nil")
        request.fetchLimit = 1

        let hasActive: Bool
        do {
            hasActive = !(try context.fetch(request)).isEmpty
        } catch {
            hasActive = false
        }

        // Always update the current level snapshot so the widget reflects removal/decay.
        let calculator = NicotineCalculator()
        let currentLevel = await calculator.calculateTotalNicotineLevel(context: context, at: .now)
        helper.updateSnapshot(level: currentLevel, isRunning: hasActive)

        if !hasActive {
            helper.markActivityEnded()
        }
    }
}
