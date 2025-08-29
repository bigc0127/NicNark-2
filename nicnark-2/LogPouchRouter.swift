//
// LogPouchRouter.swift
// nicnark-2
//
// Parses nicnark2://log?mg=INT and invokes the same logging flow.
//

import Foundation
import CoreData

enum LogPouchRouter {
    static func handle(url: URL, ctx: NSManagedObjectContext) -> Bool {
        guard url.scheme?.lowercased() == "nicnark2" else { return false }
        guard url.host?.lowercased() == "log" else { return false }
        
        guard
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let mgStr = comps.queryItems?.first(where: { $0.name.lowercased() == "mg" })?.value,
            let mg = Double(mgStr), mg > 0
        else { return false }
        
        Task { @MainActor in
            let success = LogService.logPouch(amount: mg, ctx: ctx)
            if success {
                print("✅ URL scheme successfully logged \(mg)mg pouch")
            } else {
                print("⚠️ URL scheme blocked: Active pouch already exists")
            }
        }
        
        return true
    }
}
