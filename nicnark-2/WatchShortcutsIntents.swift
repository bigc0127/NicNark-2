import Foundation
import AppIntents
import CoreData

// MARK: - Entities

struct ActivePouchEntity: AppEntity, Identifiable, Hashable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Active Pouch"
    static var defaultQuery: ActivePouchQuery = ActivePouchQuery()

    let id: String
    let mg: Double
    let brand: String
    let flavor: String
    let remainingSeconds: Double

    var displayRepresentation: DisplayRepresentation {
        let brandPart = brand.isEmpty ? "" : " • \(brand)"
        let flavorPart = flavor.isEmpty ? "" : " \(flavor)"
        let remainingText = remainingSeconds > 0 ? " • \(formatRemaining(remainingSeconds)) left" : " • complete"

        return DisplayRepresentation(
            title: "\(Int(mg))mg\(brandPart)\(flavorPart)",
            subtitle: LocalizedStringResource(stringLiteral: remainingText)
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
        let ctx = PersistenceController.shared.container.viewContext

        let request: NSFetchRequest<PouchLog> = PouchLog.fetchRequest()
        request.predicate = NSPredicate(format: "removalTime == nil")
        request.sortDescriptors = [NSSortDescriptor(keyPath: \PouchLog.insertionTime, ascending: false)]

        let now = Date.now
        let active = try ctx.fetch(request)

        return active.compactMap { pouch in
            guard let insertion = pouch.insertionTime else { return nil }
            let id = pouch.pouchId?.uuidString ?? pouch.objectID.uriRepresentation().absoluteString
            let duration = pouch.timerDuration > 0 ? TimeInterval(pouch.timerDuration) * 60 : FULL_RELEASE_TIME
            let remaining = max(0, insertion.addingTimeInterval(duration).timeIntervalSince(now))

            return ActivePouchEntity(
                id: id,
                mg: pouch.nicotineAmount,
                brand: pouch.can?.brand ?? "",
                flavor: pouch.can?.flavor ?? "",
                remainingSeconds: remaining
            )
        }
    }
}

private func formatRemaining(_ seconds: Double) -> String {
    let s = max(0, Int(seconds.rounded()))
    let m = s / 60
    let r = s % 60
    return String(format: "%d:%02d", m, r)
}

// MARK: - Intents

struct GetCurrentNicotineLevelIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Nicotine Level"
    static var description = IntentDescription("Gets your current nicotine level.")

    func perform() async throws -> some IntentResult {
        let ctx = PersistenceController.shared.container.viewContext
        let level = await NicotineCalculator().calculateTotalNicotineLevel(context: ctx)
        return .result(dialog: "Current nicotine level: \(String(format: "%.3f", level)) mg")
    }
}

struct RemoveAllActivePouchesIntent: AppIntent {
    static var title: LocalizedStringResource = "Remove All Active Pouches"
    static var description = IntentDescription("Removes all active pouches.")

    func perform() async throws -> some IntentResult {
        let ctx = PersistenceController.shared.container.viewContext
        let removed = await PouchRemovalService.removeAllActivePouches(in: ctx)
        return .result(dialog: "Removed \(removed) active pouch\(removed == 1 ? "" : "es").")
    }
}

struct RemoveSpecificActivePouchIntent: AppIntent {
    static var title: LocalizedStringResource = "Remove a Specific Pouch"
    static var description = IntentDescription("Choose an active pouch to remove.")

    @Parameter(title: "Pouch")
    var pouch: ActivePouchEntity

    func perform() async throws -> some IntentResult {
        let ctx = PersistenceController.shared.container.viewContext
        let ok = await PouchRemovalService.removePouch(withId: pouch.id, in: ctx)
        if ok {
            return .result(dialog: "Removed \(Int(pouch.mg))mg pouch.")
        }
        return .result(dialog: "Could not remove pouch.")
    }
}
