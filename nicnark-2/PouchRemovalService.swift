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

        let removalTime = Date.now
        pouch.removalTime = removalTime

        do {
            try context.save()
        } catch {
            print("❌ Failed to save pouch removal: \(error.localizedDescription)")
            print("❌ Full error: \(error)")
            // Revert the unsaved change so the pouch stays consistently active, and
            // report failure to callers instead of running the irreversible side effects.
            pouch.removalTime = nil
            return false
        }

        // End the Live Activity only after a confirmed save: the store now shows the
        // pouch inactive, so a background sync cannot re-create the activity.
        await LiveActivityManager.endLiveActivity(for: pouchId)

        // Cancel completion notification
        NotificationManager.cancelAlert(id: pouchId)

        // Update widgets snapshot + reload timelines
        await updateWidgetSnapshot(in: context)
        WidgetReloadCoordinator.reload()
        // CloudKit export is scheduled automatically by NSPersistentCloudKitContainer on save.

        // Push the updated state to a paired Apple Watch so it reflects the removal even
        // while this app is backgrounded. No-op if no watch is paired.
        #if os(iOS)
        await WatchConnectivityBridge.shared.pushHomeToWatch()
        #endif

        return true
    }

    /// Removes all active pouches (`removalTime == nil`). Returns count removed.
    static func removeAllActivePouches(in context: NSManagedObjectContext) async -> Int {
        let request: NSFetchRequest<PouchLog> = PouchLog.fetchRequest()
        request.predicate = NSPredicate(format: "removalTime == nil")

        let active: [PouchLog]
        do {
            active = try context.fetch(request)
        } catch {
            print("❌ Failed to fetch active pouches for removal: \(error.localizedDescription)")
            return 0
        }
        guard !active.isEmpty else { return 0 }

        // Batch removal: mark every active pouch removed and save the context ONCE, then run
        // the shared side effects (Live Activity end, notification cancel, widget snapshot +
        // reload) a single time — instead of looping removePouch(withId:), which did a save,
        // a snapshot recompute, a CloudKit nudge AND a widget reload per pouch.
        let removalTime = Date.now
        var removedIds: [String] = []
        var markedPouches: [PouchLog] = []
        for pouch in active where pouch.removalTime == nil {
            let pouchId = pouch.pouchId?.uuidString ?? pouch.objectID.uriRepresentation().absoluteString
            guard !pouchesBeingRemoved.contains(pouchId) else { continue }
            pouchesBeingRemoved.insert(pouchId)
            pouch.removalTime = removalTime
            removedIds.append(pouchId)
            markedPouches.append(pouch)
        }
        defer { removedIds.forEach { pouchesBeingRemoved.remove($0) } }

        guard !removedIds.isEmpty else { return 0 }

        do {
            try context.save()
        } catch {
            print("❌ Failed to save batched pouch removal: \(error.localizedDescription)")
            // Revert the in-memory removals so the store stays consistent, and report
            // 0 removed instead of running the irreversible per-pouch side effects.
            markedPouches.forEach { $0.removalTime = nil }
            return 0
        }

        // End any Live Activities and cancel completion notifications for the removed pouches.
        for pouchId in removedIds {
            await LiveActivityManager.endLiveActivity(for: pouchId)
            NotificationManager.cancelAlert(id: pouchId)
        }

        // Single widget snapshot refresh + one coalesced reload for the whole batch.
        await updateWidgetSnapshot(in: context)
        WidgetReloadCoordinator.reload()

        // Push the updated state to a paired Apple Watch so it reflects the removals even
        // while this app is backgrounded. No-op if no watch is paired.
        #if os(iOS)
        await WatchConnectivityBridge.shared.pushHomeToWatch()
        #endif

        return removedIds.count
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
