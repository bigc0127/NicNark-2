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
        Task { @MainActor in
            let action = message["action"] as? String
            let ctx = PersistenceController.shared.container.viewContext

            switch action {
            case "getCurrentNicotineLevel":
                let calculator = NicotineCalculator()
                let level = await calculator.calculateTotalNicotineLevel(context: ctx)
                replyHandler(["ok": true, "level": level])

            case "listActivePouches":
                let request: NSFetchRequest<PouchLog> = PouchLog.fetchRequest()
                request.predicate = NSPredicate(format: "removalTime == nil")
                request.sortDescriptors = [NSSortDescriptor(keyPath: \PouchLog.insertionTime, ascending: false)]

                do {
                    let now = Date.now
                    let active = try ctx.fetch(request)
                    let payload: [[String: Any]] = active.compactMap { pouch in
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

                    replyHandler(["ok": true, "pouches": payload])
                } catch {
                    replyHandler(["ok": false, "error": error.localizedDescription])
                }

            case "removeAllActivePouches":
                let removed = await PouchRemovalService.removeAllActivePouches(in: ctx)
                replyHandler(["ok": true, "removedCount": removed])

            case "removePouchById":
                if let pouchId = message["pouchId"] as? String {
                    let ok = await PouchRemovalService.removePouch(withId: pouchId, in: ctx)
                    replyHandler(["ok": ok])
                } else {
                    replyHandler(["ok": false, "error": "Missing pouchId"]) 
                }

            default:
                replyHandler(["ok": false, "error": "Unknown action", "action": action ?? "nil"]) 
            }
        }
    }
}
#endif
