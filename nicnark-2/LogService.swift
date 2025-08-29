//
// LogService.swift
// nicnark-2
//
// Centralized pouch logging used by UI, URL scheme, and Shortcuts.
//

import Foundation
import CoreData

@MainActor
enum LogService {
    
    // Define the predefined button amounts that shouldn't create custom buttons
    private static let predefinedAmounts: Set<Double> = [3.0, 6.0]
    
    static func ensureCustomButton(for amount: Double, in ctx: NSManagedObjectContext) {
        // Skip creating custom buttons for predefined amounts
        guard !predefinedAmounts.contains(amount) else { return }
        
        let fetch: NSFetchRequest<CustomButton> = CustomButton.fetchRequest()
        fetch.predicate = NSPredicate(format: "nicotineAmount == %f", amount)
        fetch.fetchLimit = 1
        
        if let found = try? ctx.fetch(fetch), found.first != nil { return }
        
        let btn = CustomButton(context: ctx)
        btn.nicotineAmount = amount
        try? ctx.save()
    }
    
    @discardableResult
    static func logPouch(amount mg: Double, ctx: NSManagedObjectContext) -> Bool {
        // Check if there's already an active pouch (no removal time)
        let activePouchFetch: NSFetchRequest<PouchLog> = PouchLog.fetchRequest()
        activePouchFetch.predicate = NSPredicate(format: "removalTime == nil")
        activePouchFetch.fetchLimit = 1
        
        if let existingActivePouches = try? ctx.fetch(activePouchFetch), !existingActivePouches.isEmpty {
            print("⚠️ Cannot log new pouch: Active pouch already exists")
            return false
        }
        
        ensureCustomButton(for: mg, in: ctx)
        
        let pouch = PouchLog(context: ctx)
        pouch.insertionTime = .now
        pouch.nicotineAmount = mg
        try? ctx.save()
        
        if #available(iOS 16.1, *) {
            let pouchId = pouch.objectID.uriRepresentation().absoluteString
            Task {
                _ = await LiveActivityManager.startLiveActivity(for: pouchId, nicotineAmount: mg)
            }
        }
        
        let pouchId = pouch.objectID.uriRepresentation().absoluteString
        let fireDate = Date().addingTimeInterval(FULL_RELEASE_TIME)
        NotificationManager.scheduleCompletionAlert(
            id: pouchId,
            title: "Absorption complete",
            body: "Your \(Int(mg))mg pouch has finished absorbing.",
            fireDate: fireDate
        )
        
        NotificationCenter.default.post(name: NSNotification.Name("PouchLogged"),
                                      object: nil,
                                      userInfo: ["mg": mg])
        
        // Update widget persistence helper for immediate widget updates
        updateWidgetPersistenceHelperAfterLogging(pouch: pouch, ctx: ctx)
        
        // Nudge a near-term background refresh to keep the Live Activity fresh soon after start
        if #available(iOS 16.1, *) {
            Task { await BackgroundMaintainer.shared.scheduleSoon() }
        }
        
        return true
    }
    
    // MARK: - Widget Persistence Helper
    
    private static func updateWidgetPersistenceHelperAfterLogging(pouch: PouchLog, ctx: NSManagedObjectContext) {
        let helper = WidgetPersistenceHelper()
        
        // Calculate initial nicotine level (just logged, so elapsed time is minimal)
        let currentLevel = AbsorptionConstants.shared.calculateCurrentNicotineLevel(
            nicotineContent: pouch.nicotineAmount,
            elapsedTime: 0 // Just logged
        )
        
        let pouchName = "\(Int(pouch.nicotineAmount))mg pouch"
        let endTime = pouch.insertionTime?.addingTimeInterval(FULL_RELEASE_TIME)
        
        // Update the persistence helper with new pouch data
        helper.setFromLiveActivity(
            level: currentLevel,
            peak: pouch.nicotineAmount * ABSORPTION_FRACTION, // Maximum possible absorption
            pouchName: pouchName,
            endTime: endTime
        )
    }
}
