# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

This is a pure Xcode project with no package manager or CLI build tooling.

```bash
open nicnark-2.xcodeproj   # Open in Xcode, then ⌘+R to build/run
```

**Live Activities and widgets require a physical device** — the simulator does not support them.

Tests are in the `nicnark-2Tests` target. Run with ⌘+U in Xcode or:
```bash
xcodebuild test -project nicnark-2.xcodeproj -scheme nicnark-2 -destination 'platform=iOS Simulator,name=iPhone 16'
```

## Targets

| Target | Description |
|--------|-------------|
| `nicnark-2` | Main iOS app (iOS 17.0+, Swift 5.9+) |
| `AbsorptionTimerWidget` | WidgetKit extension — home screen widgets and Lock Screen Live Activities |
| `Nicnark-2 Watch App` | watchOS companion (WatchConnectivity only; no independent data store) |

## Required Configuration (Team-Specific)

When setting up a new dev environment, update these identifiers to match your team:
- **App Group**: `group.ConnorNeedling.nicnark-2` (in `WidgetPersistenceHelper.swift` and `Persistence.swift`)
- **CloudKit container**: `iCloud.ConnorNeedling.nicnark-2` (in `Persistence.swift`)
- **Bundle IDs**: Main app `YourTeamID.nicnark-2`, Widget `YourTeamID.nicnark-2.AbsorptionTimerWidget`

## Architecture

### Data Flow

All pouch logging — regardless of origin (UI tap, Siri Shortcut, URL scheme `nicnark2://log?mg=6`, or Watch via `WatchConnectivityBridge`) — must go through `LogService.logPouch()`. This function orchestrates the full side-effect chain: Core Data save → CloudKit sync → Live Activity start → completion notification → widget timeline reload.

```
User action / Shortcut / URL / Watch
       ↓
   LogService.logPouch()         ← single entry point
       ↓              ↓              ↓              ↓
  CoreData      LiveActivity   Notification    WidgetKit
  + CloudKit      Manager        Manager      reloadAll
```

### Core Data Model (`nicnark_2.xcdatamodeld`)

| Entity | Purpose |
|--------|---------|
| `PouchLog` | One record per pouch usage. Key fields: `pouchId` (UUID for CloudKit identity), `insertionTime`, `removalTime` (nil = still active), `nicotineAmount`, `timerDuration` (stored in minutes) |
| `Can` | Physical can inventory. Has `pouchCount`, `brand`, `flavor`, `strength`, `barcode`, custom `duration` (minutes). One-to-many → `PouchLog` |
| `CanTemplate` | Reusable can data keyed by barcode for quick restocking |
| `CustomButton` | User-created quick-select dosage buttons (only created for non-standard amounts, not 3mg/6mg) |

Active pouches: `removalTime == nil`. The app allows multiple simultaneous active pouches.

### Widget Data Bridge

Widgets and the Live Activity extension cannot access Core Data directly. `WidgetPersistenceHelper` writes a lightweight snapshot to App Group `UserDefaults` (`group.ConnorNeedling.nicnark-2`) after each log/removal. The widget reads from there.

The widget extension computes nicotine levels with its own self-contained
`AbsorptionTimerWidget/WidgetNicotineCalculator.swift` (it can't reach the app's
`AbsorptionConstants`/`NicotineCalculator`, which live in the main-app target). Its math
mirrors `AbsorptionConstants` — keep the absorption fraction (0.30), 2-hour half-life, and
`selectedTimerDuration` handling consistent if you change the model. (There used to be a
byte-identical duplicate of this file in the main-app target; it was unused and has been
removed, so this is now the single widget calculator.)

### Nicotine Calculation Model

Two-phase model (see `NICOTINE_CALCULATION_FORMULA.md` for the full derivation):

- **Absorption phase** (pouch in mouth): linear, 30% of stated mg absorbed over `timerDuration`
- **Decay phase** (after removal): exponential with 2-hour half-life

`AbsorptionConstants` — core math primitives (singleton, `@Sendable`)
`NicotineCalculator` — fetches last-10-hours pouches from Core Data and sums contributions
`NicotineCalculator.projectNicotineLevels()` — samples every 5 min for 10 hours to find when levels cross user-configured thresholds (used for notification scheduling)

Timer duration is user-configurable (30/45/60 min) via `TimerSettings`, stored in `UserDefaults` under `selectedTimerDuration`. Individual cans can override the global duration; `LogService` uses `FULL_RELEASE_TIME` (a computed global) as the fallback.

### Key Singletons

| Class | Responsibility |
|-------|---------------|
| `PersistenceController.shared` | `NSPersistentCloudKitContainer` setup; App Group store path; CloudKit remote-change → Live Activity sync |
| `LiveActivityManager` | ActivityKit lifecycle — start/update/end; deduplication via `activeActivitiesByPouchId` dict |
| `BackgroundMaintainer` | BGTaskScheduler registration and scheduling for two task IDs: `bg.refresh` and `bg.process` |
| `WatchConnectivityBridge` | iPhone side of WCSession; dispatches Watch messages (`logPouch`, `removePouch`, `fetchStatus`) to `LogService` / `PouchRemovalService` |
| `CanManager` | Inventory CRUD; barcode scanning integration |
| `NotificationManager` | Completion alerts, usage reminders, low-inventory alerts (24-hour cooldown per can via `InventoryAlertTracker`) |

### Tab Structure (ContentView)

| Tab | View | Tag |
|-----|------|-----|
| Log | `LogView` | 0 |
| Levels | `NicotineLevelView` | 1 |
| Usage | `UsageGraphView` | 2 |

Settings is a sheet (`SettingsView`) accessible from the toolbar on the Log tab.

## iOS Version Guards

`LiveActivityManager`, `BackgroundMaintainer`, and the Live Activity widget are gated on `#available(iOS 16.1, *)`. Older iOS falls back to `DummySyncState` in `LogView` for sync status display. Always maintain these guards when touching Activity-related code.
