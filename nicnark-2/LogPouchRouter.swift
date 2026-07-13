//
// LogPouchRouter.swift
// nicnark-2
//
// Parses nicnark2://log?mg=INT and invokes the same logging flow.
//

import Foundation
import CoreData

enum LogPouchRouter {
    /// Parses `nicnark2://log?mg=…` and logs immediately on the main actor.
    /// Returns whether the log succeeded (not merely whether the URL parsed).
    @MainActor
    @discardableResult
    static func handle(url: URL, ctx: NSManagedObjectContext) -> Bool {
        guard url.scheme?.lowercased() == "nicnark2" else { return false }
        guard url.host?.lowercased() == "log" else { return false }

        guard
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let mgStr = comps.queryItems?.first(where: { $0.name.lowercased() == "mg" })?.value,
            let mg = Double(mgStr), mg > 0, mg <= 100
        else { return false }

        return LogService.logPouch(amount: mg, ctx: ctx)
    }
}
