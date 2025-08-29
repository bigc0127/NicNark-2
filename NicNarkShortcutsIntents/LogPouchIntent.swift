//
// LogPouchIntent.swift
// NicNarkShortcutsIntents
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

    // Remove OpensIntent since we're not opening URLs
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard mg > 0 && mg <= 100 else {
            throw $mg.needsValueError("Enter amount between 0.1 and 100")
        }

        // Directly perform the logging action instead of opening URL
        let success = await MainActor.run {
            let context = PersistenceController.shared.container.viewContext
            return LogService.logPouch(amount: mg, ctx: context)
        }

        if success {
            // Update widgets after successful logging
            WidgetCenter.shared.reloadAllTimelines()
            return .result(dialog: "Logged \(String(format: "%.1f", mg))mg pouch")
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
        // Directly perform the logging action
        let success = await MainActor.run {
            let context = PersistenceController.shared.container.viewContext
            return LogService.logPouch(amount: 3.0, ctx: context)
        }

        if success {
            // Update widgets after successful logging
            WidgetCenter.shared.reloadAllTimelines()
            return .result(dialog: "Logged 3mg pouch")
        } else {
            return .result(dialog: "Cannot log pouch: You already have an active pouch running. Remove it first.")
        }
    }
}

struct Log6mgPouchIntent: AppIntent {
    static var title: LocalizedStringResource = "Log 6mg Pouch"
    static var description = IntentDescription("Log a 6mg pouch")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        // Directly perform the logging action
        let success = await MainActor.run {
            let context = PersistenceController.shared.container.viewContext
            return LogService.logPouch(amount: 6.0, ctx: context)
        }

        if success {
            // Update widgets after successful logging
            WidgetCenter.shared.reloadAllTimelines()
            return .result(dialog: "Logged 6mg pouch")
        } else {
            return .result(dialog: "Cannot log pouch: You already have an active pouch running. Remove it first.")
        }
    }
}
