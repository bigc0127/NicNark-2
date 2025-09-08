//
// LogPouchIntent.swift
// NicNark App
//
// Moved from the former NicNarkShortcutsIntents extension into the main app target.
//

import AppIntents
import Foundation
import WidgetKit

struct LogPouchIntent: AppIntent {
    static var title: LocalizedStringResource = "Log Nicotine Pouch"
    static var description = IntentDescription("Log a nicotine pouch")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Amount (mg)")
    var mg: Double

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard mg > 0 && mg <= 100 else {
            throw $mg.needsValueError("Enter amount between 0.1 and 100")
        }

        let (success, pouchId) = await MainActor.run {
            let context = PersistenceController.shared.container.viewContext
            
            // Check for active pouches first
            let fetchRequest = PouchLog.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "removalTime == nil")
            fetchRequest.fetchLimit = 1
            
            if let existingPouches = try? context.fetch(fetchRequest), !existingPouches.isEmpty {
                return (false, nil as UUID?)
            }
            
            // Create the pouch
            let pouch = PouchLog(context: context)
            pouch.pouchId = UUID()
            pouch.insertionTime = .now
            pouch.nicotineAmount = mg
            
            do {
                try context.save()
                
                // Post notification that will trigger can selection in the app
                NotificationCenter.default.post(
                    name: NSNotification.Name("PouchLogged"),
                    object: nil,
                    userInfo: [
                        "mg": mg,
                        "isFromShortcut": true,
                        "pouchId": pouch.pouchId?.uuidString ?? ""
                    ]
                )
                
                return (true, pouch.pouchId)
            } catch {
                return (false, nil as UUID?)
            }
        }

        if success {
            WidgetCenter.shared.reloadAllTimelines()
            return .result(dialog: "Logged \(String(format: "%.1f", mg))mg pouch. Open app to select can.")
        } else {
            return .result(dialog: "Cannot log pouch: You already have an active pouch running. Remove it first.")
        }
    }
}

struct Log3mgPouchIntent: AppIntent {
    static var title: LocalizedStringResource = "Log 3mg Pouch"
    static var description = IntentDescription("Log a 3mg pouch")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let intent = LogPouchIntent()
        intent.mg = 3.0
        return try await intent.perform()
    }
}

struct Log6mgPouchIntent: AppIntent {
    static var title: LocalizedStringResource = "Log 6mg Pouch"
    static var description = IntentDescription("Log a 6mg pouch")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let intent = LogPouchIntent()
        intent.mg = 6.0
        return try await intent.perform()
    }
}

