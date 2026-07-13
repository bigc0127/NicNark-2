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

        // Cancel completion notification (group-aware; past-fire safe).
        NotificationManager.cancelAlert(id: pouchId)

        // If other pouches are still active, rebuild ONE aggregated Live Activity
        // (total mg + longest remaining). Serialized so log/remove cannot race.
        await LogService.presentAggregatedLiveActivitySerialized(in: context)

        // Widget snapshot (decay-aware even when none remain).
        LogService.updateWidgetSnapshotForActivePouches(in: context)
        WidgetReloadCoordinator.reload()

        NotificationCenter.default.post(
            name: NSNotification.Name("PouchRemoved"),
            object: nil,
            userInfo: ["pouchId": pouchId]
        )

        #if os(iOS)
        await WatchConnectivityBridge.shared.pushHomeToWatch()
        #endif

        return true
    }

    /// Batch-remove specific pouches by id (one save, one LA end pass, one watch push).
    /// Used by group completion "Remove" so N members ≠ N full side-effect chains.
    @discardableResult
    static func removePouches(withIds ids: [String], in context: NSManagedObjectContext) async -> Int {
        let unique = Array(Set(ids.filter { !$0.isEmpty }))
        guard !unique.isEmpty else { return 0 }

        let removalTime = Date.now
        var removedIds: [String] = []
        var marked: [PouchLog] = []

        for pouchId in unique {
            guard !pouchesBeingRemoved.contains(pouchId) else { continue }
            guard let pouch = fetchPouch(withId: pouchId, in: context), pouch.removalTime == nil else {
                continue
            }
            pouchesBeingRemoved.insert(pouchId)
            pouch.removalTime = removalTime
            removedIds.append(pouchId)
            marked.append(pouch)
        }
        defer { removedIds.forEach { pouchesBeingRemoved.remove($0) } }
        guard !removedIds.isEmpty else { return 0 }

        do {
            try context.save()
        } catch {
            print("❌ Failed to save batch pouch removal: \(error.localizedDescription)")
            marked.forEach { $0.removalTime = nil }
            return 0
        }

        for pouchId in removedIds {
            await LiveActivityManager.endLiveActivity(for: pouchId)
            NotificationManager.cancelAlert(id: pouchId)
        }

        await LogService.presentAggregatedLiveActivitySerialized(in: context)
        LogService.updateWidgetSnapshotForActivePouches(in: context)
        WidgetReloadCoordinator.reload()

        NotificationCenter.default.post(
            name: NSNotification.Name("PouchRemoved"),
            object: nil,
            userInfo: ["count": removedIds.count, "ids": removedIds]
        )

        #if os(iOS)
        await WatchConnectivityBridge.shared.pushHomeToWatch()
        #endif

        return removedIds.count
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

        // All active pouches removed — no LA rebuild. Still write decay-aware level.
        LogService.updateWidgetSnapshotForActivePouches(in: context)
        WidgetReloadCoordinator.reload()

        NotificationCenter.default.post(
            name: NSNotification.Name("PouchRemoved"),
            object: nil,
            userInfo: ["count": removedIds.count]
        )

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
}
