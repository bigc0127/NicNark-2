//
// NicNarkAppShortcuts.swift
// NicNarkShortcutsIntents
//
// Created by Connor W. Needling on 2025-08-15.
// Defines shortcuts that appear in the Shortcuts app
//

import AppIntents

struct NicNarkAppShortcuts: AppShortcutsProvider {
    @AppShortcutsBuilder
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LogPouchIntent(),
            phrases: [
                "Log a pouch in \(.applicationName)",
                "Log nicotine pouch in \(.applicationName)",
                "Add pouch to \(.applicationName)",
                "Record pouch in \(.applicationName)"
            ],
            shortTitle: "Log Pouch",
            systemImageName: "pills.fill"
        )

        AppShortcut(
            intent: Log3mgPouchIntent(),
            phrases: [
                "Log 3mg pouch in \(.applicationName)",
                "Log 3 milligram pouch in \(.applicationName)",
                "Add 3mg pouch in \(.applicationName)"
            ],
            shortTitle: "Log 3mg",
            systemImageName: "pills.fill"
        )

        AppShortcut(
            intent: Log6mgPouchIntent(),
            phrases: [
                "Log 6mg pouch in \(.applicationName)",
                "Log 6 milligram pouch in \(.applicationName)",
                "Add 6mg pouch in \(.applicationName)"
            ],
            shortTitle: "Log 6mg",
            systemImageName: "pills.fill"
        )
    }
}
