//
//  Nicnark_2_watch.swift
//  Nicnark-2-watch
//
//  Created by Connor W. Needling on 2026.02.23.
//

import AppIntents
import WatchConnectivity

private enum WatchBridgeError: Error {
    case watchNotSupported
    case phoneNotReachable
    case invalidReply
}

private func formatRemaining(_ seconds: Double) -> String {
    let s = max(0, Int(seconds.rounded()))
    let m = s / 60
    let r = s % 60
    return String(format: "%d:%02d", m, r)
}

private struct ActivePouchPayload: Hashable {
    let id: String
    let mg: Double
    let brand: String
    let flavor: String
    let remaining: Double
}

private final class WatchBridgeClient: NSObject, WCSessionDelegate {
    static let shared = WatchBridgeClient()

    private override init() {
        super.init()
        activateIfNeeded()
    }

    private func activateIfNeeded() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        if session.delegate == nil {
            session.delegate = self
        }
        if session.activationState != .activated {
            session.activate()
        }
    }

    func sendMessage(_ message: [String: Any]) async throws -> [String: Any] {
        guard WCSession.isSupported() else { throw WatchBridgeError.watchNotSupported }
        activateIfNeeded()

        let session = WCSession.default
        guard session.isReachable else { throw WatchBridgeError.phoneNotReachable }

        return try await withCheckedThrowingContinuation { cont in
            session.sendMessage(message) { reply in
                cont.resume(returning: reply)
            } errorHandler: { error in
                cont.resume(throwing: error)
            }
        }
    }

    func fetchActivePouches() async throws -> [ActivePouchPayload] {
        let reply = try await sendMessage([
            "action": "listActivePouches"
        ])

        guard (reply["ok"] as? Bool) == true,
              let raw = reply["pouches"] as? [[String: Any]] else {
            throw WatchBridgeError.invalidReply
        }

        return raw.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            let mg = item["mg"] as? Double ?? 0
            let brand = item["brand"] as? String ?? ""
            let flavor = item["flavor"] as? String ?? ""
            let remaining = item["remaining"] as? Double ?? 0
            return ActivePouchPayload(id: id, mg: mg, brand: brand, flavor: flavor, remaining: remaining)
        }
    }

    // MARK: WCSessionDelegate
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}
}

struct GetCurrentNicotineLevelIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Nicotine Level"
    static var description = IntentDescription("Gets your current nicotine level from the iPhone app.")

    func perform() async throws -> some IntentResult {
        let reply = try await WatchBridgeClient.shared.sendMessage([
            "action": "getCurrentNicotineLevel"
        ])

        guard (reply["ok"] as? Bool) == true,
              let level = reply["level"] as? Double else {
            throw WatchBridgeError.invalidReply
        }

        return .result(dialog: "Current nicotine level: \(String(format: "%.3f", level)) mg")
    }
}

struct ActivePouchEntity: AppEntity, Identifiable, Hashable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Active Pouch"

    static var defaultQuery: ActivePouchQuery = ActivePouchQuery()

    let id: String
    let mg: Double
    let brand: String
    let flavor: String
    let remaining: Double

    var displayRepresentation: DisplayRepresentation {
        let brandPart = brand.isEmpty ? "" : " • \(brand)"
        let flavorPart = flavor.isEmpty ? "" : " \(flavor)"
        let remainingText = remaining > 0 ? " • \(formatRemaining(remaining)) left" : " • complete"
        return DisplayRepresentation(
            title: "\(Int(mg))mg\(brandPart)\(flavorPart)",
            subtitle: "\(remainingText)"
        )
    }
}

struct ActivePouchQuery: EntityQuery {
    func suggestedEntities() async throws -> [ActivePouchEntity] {
        try await allActive()
    }

    func entities(for identifiers: [ActivePouchEntity.ID]) async throws -> [ActivePouchEntity] {
        let all = try await allActive()
        let wanted = Set(identifiers)
        return all.filter { wanted.contains($0.id) }
    }

    private func allActive() async throws -> [ActivePouchEntity] {
        let payload = try await WatchBridgeClient.shared.fetchActivePouches()
        return payload.map {
            ActivePouchEntity(
                id: $0.id,
                mg: $0.mg,
                brand: $0.brand,
                flavor: $0.flavor,
                remaining: $0.remaining
            )
        }
    }
}

struct RemoveAllActivePouchesIntent: AppIntent {
    static var title: LocalizedStringResource = "Remove Active Pouches"
    static var description = IntentDescription("Removes all active pouches in the iPhone app.")

    func perform() async throws -> some IntentResult {
        let reply = try await WatchBridgeClient.shared.sendMessage([
            "action": "removeAllActivePouches"
        ])

        guard (reply["ok"] as? Bool) == true else {
            throw WatchBridgeError.invalidReply
        }

        let removedCount = reply["removedCount"] as? Int ?? 0
        return .result(dialog: "Removed \(removedCount) active pouch\(removedCount == 1 ? "" : "es").")
    }
}

struct RemoveSpecificActivePouchIntent: AppIntent {
    static var title: LocalizedStringResource = "Remove a Specific Pouch"
    static var description = IntentDescription("Choose an active pouch to remove.")

    @Parameter(title: "Pouch")
    var pouch: ActivePouchEntity

    func perform() async throws -> some IntentResult {
        let reply = try await WatchBridgeClient.shared.sendMessage([
            "action": "removePouchById",
            "pouchId": pouch.id
        ])

        guard (reply["ok"] as? Bool) == true else {
            throw WatchBridgeError.invalidReply
        }

        return .result(dialog: "Removed \(Int(pouch.mg))mg pouch.")
    }
}
