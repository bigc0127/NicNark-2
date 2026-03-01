#if os(iOS)
import Foundation
import WatchConnectivity
import CoreData

final class WatchConnectivityBridge: NSObject {
    static let shared = WatchConnectivityBridge()

    private override init() {
        super.init()
    }

    @MainActor
    func start() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }
}

extension WatchConnectivityBridge: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error {
            print("⌚️ WCSession activation error: \(error.localizedDescription)")
        } else {
            print("⌚️ WCSession activated: \(activationState.rawValue)")
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        // WC dictionaries contain only plist-safe types; wrapping for safe actor-boundary crossing.
        struct Transfer: @unchecked Sendable {
            let message: [String: Any]
            let handler: ([String: Any]) -> Void
        }
        let t = Transfer(message: message, handler: replyHandler)
        Task { @MainActor in
            let response = await handleRequest(t.message)
            t.handler(response)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        // For queued actions when the iPhone isn't reachable. (No reply possible.)
        struct Transfer: @unchecked Sendable { let userInfo: [String: Any] }
        let t = Transfer(userInfo: userInfo)
        Task { @MainActor in
            _ = await handleRequest(t.userInfo, expectsReply: false)
        }
    }

    // MARK: - Request handling

    @MainActor
    private func handleRequest(_ message: [String: Any], expectsReply: Bool = true) async -> [String: Any] {
        guard let action = message["action"] as? String else {
            return ["ok": false, "error": "Missing action"]
        }

        let ctx = PersistenceController.shared.container.viewContext

        switch action {
        case "getCurrentNicotineLevel":
            let calculator = NicotineCalculator()
            let level = await calculator.calculateTotalNicotineLevel(context: ctx)
            return ["ok": true, "level": level]

        case "getDashboard":
            var response: [String: Any] = ["ok": true]
            response.merge(await makeDashboardPayload(in: ctx), uniquingKeysWith: { _, new in new })
            return response

        case "getWatchHome":
            var response: [String: Any] = ["ok": true]
            response.merge(await makeWatchHomePayload(in: ctx), uniquingKeysWith: { _, new in new })
            return response

        case "listActivePouches":
            return listActivePouches(in: ctx)

        case "listActiveCans":
            return listActiveCans(in: ctx)

        case "logPouchFromCanId":
            guard let canId = message["canId"] as? String else {
                return ["ok": false, "error": "Missing canId"]
            }

            guard let can = fetchCan(withId: canId, in: ctx) else {
                return ["ok": false, "error": "Can not found"]
            }

            let mg = (message["mg"] as? Double) ?? can.strength
            let ok = CanManager.shared.logPouchFromCan(can: can, amount: mg, context: ctx)

            var response: [String: Any] = ["ok": ok]
            if ok {
                response.merge(await makeWatchHomePayload(in: ctx), uniquingKeysWith: { _, new in new })
            }
            return response

        case "removeAllActivePouches":
            let removed = await PouchRemovalService.removeAllActivePouches(in: ctx)

            var response: [String: Any] = ["ok": true, "removedCount": removed]
            response.merge(await makeWatchHomePayload(in: ctx), uniquingKeysWith: { _, new in new })
            return response

        case "removePouchById":
            guard let pouchId = message["pouchId"] as? String else {
                return ["ok": false, "error": "Missing pouchId"]
            }

            let ok = await PouchRemovalService.removePouch(withId: pouchId, in: ctx)

            var response: [String: Any] = ["ok": ok]
            if ok {
                response.merge(await makeWatchHomePayload(in: ctx), uniquingKeysWith: { _, new in new })
            }
            return response

        default:
            // If this is from transferUserInfo we can't reply anyway, but still return something for logging.
            if expectsReply {
                return ["ok": false, "error": "Unknown action", "action": action]
            } else {
                print("⌚️ Received unknown queued action: \(action)")
                return ["ok": false, "error": "Unknown action", "action": action]
            }
        }
    }

    // MARK: - Payload builders

    @MainActor
    private func makeDashboardPayload(in ctx: NSManagedObjectContext) async -> [String: Any] {
        let calculator = NicotineCalculator()
        let level = await calculator.calculateTotalNicotineLevel(context: ctx)

        let activePouchCount: Int
        do {
            let request: NSFetchRequest<PouchLog> = PouchLog.fetchRequest()
            request.predicate = NSPredicate(format: "removalTime == nil")
            activePouchCount = try ctx.count(for: request)
        } catch {
            activePouchCount = 0
        }

        let cans = fetchActiveCans(in: ctx)
        let totalPouches = cans.reduce(0) { $0 + Int($1.pouchCount) }

        let cansPayload: [[String: Any]] = cans.map { can in
            let id = can.id?.uuidString ?? can.objectID.uriRepresentation().absoluteString
            return [
                "id": id,
                "brand": can.brand ?? "",
                "flavor": can.flavor ?? "",
                "strength": can.strength,
                "pouchCount": Int(can.pouchCount),
                "duration": Int(can.duration)
            ]
        }

        return [
            "level": level,
            "activePouchCount": activePouchCount,
            "totalPouches": totalPouches,
            "cans": cansPayload
        ]
    }

    @MainActor
    private func makeWatchHomePayload(in ctx: NSManagedObjectContext) async -> [String: Any] {
        var payload = await makeDashboardPayload(in: ctx)

        // Active pouch list
        payload["activePouches"] = activePouchPayload(in: ctx)

        // Graph data (smaller window than iOS Levels screen, optimized for watch)
        payload["graphPoints"] = await makeWatchGraphPoints(in: ctx)

        return payload
    }

    @MainActor
    private func makeWatchGraphPoints(in ctx: NSManagedObjectContext) async -> [[String: Any]] {
        let calculator = NicotineCalculator()
        let now = Date.now

        // Show last 6 hours + next 2 hours in 10-minute increments.
        let start = now.addingTimeInterval(-6 * 3600)
        let end = now.addingTimeInterval(2 * 3600)
        let step: TimeInterval = 10 * 60

        var points: [[String: Any]] = []
        var t = start

        while t <= end {
            let level = await calculator.calculateTotalNicotineLevel(context: ctx, at: t)
            points.append([
                "time": t.timeIntervalSince1970,
                "level": max(0, level)
            ])
            t = t.addingTimeInterval(step)
        }

        return points
    }

    // MARK: - Query helpers

    @MainActor
    private func listActivePouches(in ctx: NSManagedObjectContext) -> [String: Any] {
        return ["ok": true, "pouches": activePouchPayload(in: ctx)]
    }

    @MainActor
    private func activePouchPayload(in ctx: NSManagedObjectContext) -> [[String: Any]] {
        let request: NSFetchRequest<PouchLog> = PouchLog.fetchRequest()
        request.predicate = NSPredicate(format: "removalTime == nil")
        request.sortDescriptors = [NSSortDescriptor(keyPath: \PouchLog.insertionTime, ascending: false)]

        let now = Date.now
        let active = (try? ctx.fetch(request)) ?? []

        return active.compactMap { pouch in
            guard let insertion = pouch.insertionTime else { return nil }
            let id = pouch.pouchId?.uuidString ?? pouch.objectID.uriRepresentation().absoluteString
            let duration = pouch.timerDuration > 0 ? TimeInterval(pouch.timerDuration) * 60 : FULL_RELEASE_TIME
            let elapsed = max(0, now.timeIntervalSince(insertion))
            let remaining = max(0, duration - elapsed)

            return [
                "id": id,
                "mg": pouch.nicotineAmount,
                "brand": pouch.can?.brand ?? "",
                "flavor": pouch.can?.flavor ?? "",
                "insertionTime": insertion.timeIntervalSince1970,
                "duration": duration,
                "remaining": remaining
            ]
        }
    }

    @MainActor
    private func listActiveCans(in ctx: NSManagedObjectContext) -> [String: Any] {
        let cans = fetchActiveCans(in: ctx)
        let payload: [[String: Any]] = cans.map { can in
            let id = can.id?.uuidString ?? can.objectID.uriRepresentation().absoluteString
            return [
                "id": id,
                "brand": can.brand ?? "",
                "flavor": can.flavor ?? "",
                "strength": can.strength,
                "pouchCount": Int(can.pouchCount),
                "duration": Int(can.duration)
            ]
        }
        return ["ok": true, "cans": payload]
    }

    @MainActor
    private func fetchActiveCans(in ctx: NSManagedObjectContext) -> [Can] {
        let request: NSFetchRequest<Can> = Can.fetchRequest()
        request.predicate = NSPredicate(format: "pouchCount > 0")
        request.sortDescriptors = [NSSortDescriptor(keyPath: \Can.dateAdded, ascending: false)]

        return (try? ctx.fetch(request)) ?? []
    }

    @MainActor
    private func fetchCan(withId canId: String, in ctx: NSManagedObjectContext) -> Can? {
        if let uuid = UUID(uuidString: canId) {
            let request: NSFetchRequest<Can> = Can.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", uuid as CVarArg)
            request.fetchLimit = 1
            return (try? ctx.fetch(request))?.first
        }

        if let uri = URL(string: canId),
           let objectId = ctx.persistentStoreCoordinator?.managedObjectID(forURIRepresentation: uri) {
            return try? ctx.existingObject(with: objectId) as? Can
        }

        return nil
    }
}
#endif
