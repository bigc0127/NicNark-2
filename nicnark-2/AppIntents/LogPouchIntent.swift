//
// LogPouchIntent.swift
// NicNark App
//
// iOS App Intents for Siri and Shortcuts Integration
//
// This file defines App Intents that allow users to log nicotine pouches through:
// • Siri voice commands ("Hey Siri, log a 6mg pouch")
// • iOS Shortcuts app automation
// • Spotlight search suggestions
// • Control Center widgets
// • Apple Watch integration
//
// App Intents are iOS 16+ technology that replaced the older Shortcuts framework.
// They provide better performance, more natural language processing, and tighter
// system integration than the legacy SiriKit approach.
//
// Architecture note: Previously this was in a separate Shortcuts extension target,
// but App Intents work better when embedded directly in the main app target.
//

import AppIntents     // iOS 16+ framework for Siri and Shortcuts integration
import Foundation     // Basic Swift functionality
import WidgetKit      // For updating home screen widgets after logging

/**
 * LogPouchIntent: The main App Intent for logging nicotine pouches with custom amounts.
 * 
 * This intent allows users to:
 * - Ask Siri: "Log a nicotine pouch" (Siri will ask for the amount)
 * - Create Shortcuts: "When I arrive at work, log a 4mg pouch"
 * - Use Spotlight: Type "log pouch" in search
 * 
 * The intent creates a PouchLog entry but doesn't associate it with a can inventory.
 * When the user opens the app, they'll see a sheet to optionally select which can
 * the pouch came from.
 */
struct LogPouchIntent: AppIntent {
    /// How this intent appears in Siri suggestions and Shortcuts app
    static var title: LocalizedStringResource = "Log Nicotine Pouch"
    /// Description shown when users browse available intents
    static var description = IntentDescription("Log a nicotine pouch")
    /// Always open the main app after running (to show can selection sheet)
    static var openAppWhenRun: Bool = true

    /// The nicotine amount parameter that Siri will ask for or Shortcuts can provide
    @Parameter(title: "Amount (mg)")
    var mg: Double

    /**
     * Executes the pouch logging intent.
     * 
     * This method:
     * 1. Validates the nicotine amount is reasonable
     * 2. Checks if there's already an active pouch (prevents double-logging)
     * 3. Creates a new PouchLog in Core Data
     * 4. Posts a notification to trigger can selection in the main app
     * 5. Updates home screen widgets
     * 6. Returns a confirmation message to Siri/Shortcuts
     * 
     * Returns: IntentResult with dialog text that Siri speaks to the user
     */
    func perform() async throws -> some IntentResult & ProvidesDialog {
        // Input validation: ensure amount is within reasonable bounds
        guard mg > 0 && mg <= 100 else {
            throw $mg.needsValueError("Enter amount between 0.1 and 100")
        }

        let (success, _) = await MainActor.run {
            let context = PersistenceController.shared.container.viewContext
            
            // Step 1: Prevent double-logging by checking for active pouches
            let fetchRequest = PouchLog.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "removalTime == nil")  // Active = no removal time
            fetchRequest.fetchLimit = 1  // Only need to know if any exist
            
            if let existingPouches = try? context.fetch(fetchRequest), !existingPouches.isEmpty {
                return (false, nil as UUID?)  // Fail: already have active pouch
            }
            
            // Step 2: Create new pouch log entry
            let pouch = PouchLog(context: context)
            pouch.pouchId = UUID()          // Unique ID for CloudKit sync
            pouch.insertionTime = .now      // Current timestamp
            pouch.nicotineAmount = mg       // Amount from Siri/Shortcuts
            
            do {
                try context.save()  // Persist to database
                
                // Step 3: Notify main app about the new pouch (for can selection)
                // This notification is received by LogView to show the can selection sheet
                NotificationCenter.default.post(
                    name: NSNotification.Name("PouchLogged"),
                    object: nil,
                    userInfo: [
                        "mg": mg,                                    // Nicotine amount
                        "isFromShortcut": true,                    // Flag indicating this came from Shortcuts
                        "pouchId": pouch.pouchId?.uuidString ?? "" // For can association
                    ]
                )
                
                return (true, pouch.pouchId)  // Success
            } catch {
                return (false, nil as UUID?)  // Database error
            }
        }

        if success {
            // Step 4: Update home screen widgets with new pouch data
            WidgetCenter.shared.reloadAllTimelines()
            
            // Step 5: Return success message that Siri will speak
            return .result(dialog: "Logged \(String(format: "%.1f", mg))mg pouch. Open app to select can.")
        } else {
            // Return error message explaining why logging failed
            return .result(dialog: "Cannot log pouch: You already have an active pouch running. Remove it first.")
        }
    }
}

/**
 * Log3mgPouchIntent: Convenience intent for logging 3mg pouches without asking for amount.
 * 
 * This creates a more streamlined Siri experience:
 * - User: "Log a 3mg pouch" (no follow-up question)
 * - Siri: "Logged 3mg pouch. Open app to select can."
 * 
 * This is faster than the generic LogPouchIntent which always asks for the amount.
 */
struct Log3mgPouchIntent: AppIntent {
    static var title: LocalizedStringResource = "Log 3mg Pouch"
    static var description = IntentDescription("Log a 3mg pouch")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        // Delegate to the main intent with predefined amount
        let intent = LogPouchIntent()
        intent.mg = 3.0  // Fixed at 3mg
        return try await intent.perform()
    }
}

/**
 * Log6mgPouchIntent: Convenience intent for logging 6mg pouches without asking for amount.
 * 
 * This provides the same streamlined experience as Log3mgPouchIntent but for 6mg pouches,
 * which are the most common strength. Users can say "Log a 6mg pouch" and get immediate
 * confirmation without Siri asking for the amount.
 */
struct Log6mgPouchIntent: AppIntent {
    static var title: LocalizedStringResource = "Log 6mg Pouch"
    static var description = IntentDescription("Log a 6mg pouch")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        // Delegate to the main intent with predefined amount
        let intent = LogPouchIntent()
        intent.mg = 6.0  // Fixed at 6mg
        return try await intent.perform()
    }
}

