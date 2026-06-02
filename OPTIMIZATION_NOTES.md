# Optimization Pass — Notes

Branch: `perf/optimization-pass`. Every change is **data-safe** (no Core Data schema,
App Group store path, CloudKit container ID, or persisted UserDefaults key was changed),
so existing v2.5 installs keep working. Each theme below was built clean
(`xcodebuild -scheme nicnark-2 -destination 'generic/platform=iOS Simulator' build`,
zero errors/warnings) before the next.

> Build/run destination note: `iPhone 16e` is now on iOS 26.4.1 while `OS:latest` is 26.5,
> so `-destination 'platform=iOS Simulator,name=iPhone 16e'` fails with "device not found".
> Use `-destination 'generic/platform=iOS Simulator'` for compile checks, or pick an
> iOS-26.5 device (iPhone 17 / 17 Pro / Air) to actually run.

## What was done

| Theme | Summary |
|-------|---------|
| **A — Bugs + dead code** | Removed the duplicate `onOpenURL` (deep links no longer double-log); replaced the main-thread `DispatchSemaphore` in `LogView.updateWidgetPersistenceHelper` with `async`; made "Delete All Data" CloudKit-aware (per-object delete on a background context, now includes `Can`/`CanTemplate` — `NSBatchDeleteRequest` left deleted data to resurrect on sync); routed the `NotificationDelegate` badge update through `LiveActivityManager.shared` instead of a throwaway instance; removed the dead `forceSchemaCreationWithTestData`, the always-false "Test Sync Complete" alert, the unused `activityQueue` + `updateLiveActivity(timeRemaining:)` overload, the StoreKit 500 ms sleep; fixed `Int16(threshold)` truncation in `CanCardView`. |
| **B — CloudKit sync amplification** | One remote-change observer (`CloudKitSyncManager`) instead of three conflicting ones; deleted the per-log dual `triggerCloudKitSync` + `triggerManualSync` storm (the container auto-exports on save); deleted `PersistenceController.triggerCloudKitSync` and its empty-save + full `fetchHistory(.distantPast)`; fixed the retain-cycle 60 s polling timer (now a foreground `didBecomeActive` refresh); fixed the `CloudKitSyncState` observer leak; gated the UUID backfill behind `didBackfillPouchUUIDs` so it stops fetching the whole table every launch. |
| **C — Duplicate calculator** | Deleted the byte-identical, **unused** `nicnark-2/WidgetSupport/WidgetNicotineCalculator.swift` (the symbol was only ever used by the widget). One calculator remains; the hand-sync hazard is gone. |
| **D — Fetch hoisting** | Added `NicotineCalculator.levelFromPouches([PouchLog], at:)` + `fetchRecentPouches`; `projectNicotineLevels`, the three `NicotineLevelView` point loops, the Watch graph builder, and the widget chart now **fetch once and sample in memory** (was ~121 / ~97 / ~49 / ~13 identical Core Data fetches per refresh). Numerically identical (same 10 h window re-applied per sample). |
| **E — Reload / Live Activity churn** | Deleted the detached `startForegroundMinuteTicker` (a 3rd foreground loop that updated + reloaded every 30 s); added `WidgetReloadCoordinator` (2 s debounce) and routed all 21 app-side `reloadAllTimelines()` through it; raised the widget timeline refresh from 60 s → 300 s (active) / 900 s (idle) to fit iOS's reload budget. |
| **F — Batched removal** | `removeAllActivePouches` now marks every pouch removed and saves **once**, then runs one Live-Activity-end / notification-cancel / snapshot / reload pass — was N saves + N snapshot recomputes + N reloads + N CloudKit nudges. |
| **G — Notifications** | Debounced `rescheduleNotifications` (0.5 s) so slider/stepper drags reschedule once, not dozens of times; hoisted `pendingNotificationRequests()` out of the per-can inventory loop; made `configure()` idempotent; **fixed the daily-summary bug** (it pinned `dateComponents.day`, so with `repeats:true` it fired once a *month* — now daily); gave usage-insights a stable id so re-checks replace instead of stacking. |
| **H — Per-frame view cost** | Chart point identity now derives from `time` (was a fresh `UUID()` per construction, which defeated SwiftUI Charts' diffing/animation) for `NicotinePoint` and the widget `NicotineChartPoint`; guarded the Live Activity progress divide-by-zero (`maxAbsorption == 0`); hoisted two per-render `DateFormatter()`s in `UsageGraphView` to `static`. |
| **I — Duration precision** | `LogService` now rounds minutes instead of truncating (the multi-pouch weighted-average path lost up to ~59 s). See "Deferred" for the exact-seconds version. |

## Deliberately deferred (need Xcode + a physical device, or are too risky to do blind)

These were left out **on purpose** — each either can't be validated in a headless compile,
risks shipped-user data, or is a large structural rewrite the audit itself flagged as
"do incrementally with tests."

### 1. Exact sub-minute duration — additive Core Data attribute
The safe *design* is an additive optional attribute; the safe *execution* needs Xcode's
model editor + a device migration test against real data, which can't be done here.

Steps (in Xcode):
1. Select `nicnark_2.xcdatamodeld` → **Editor ▸ Add Model Version…** (base it on the current
   version). This makes Xcode generate correct version metadata — do **not** hand-edit the bundle.
2. On the new version's `PouchLog`, add attribute `timerDurationSeconds`, type **Double**,
   **Optional = YES**. Set the new version as the current one (file inspector ▸ Model Version).
3. Leave automatic lightweight migration on (default). Additive optional attribute → inferred.
4. Code:
   - `LogService.logPouch`: also set `pouch.timerDurationSeconds = durationSeconds`.
   - Add `PouchLog.effectiveDurationSeconds` = `timerDurationSeconds`-if-set else
     `TimeInterval(timerDuration * 60)`, and route the ~20 `timerDuration * 60` readers through it.
5. **Before shipping:** install the *current* App Store build, create data, then upgrade to the
   new build on a device and confirm the store migrates and CloudKit still syncs. Deploy the
   schema change to the CloudKit **production** environment (CloudKit Dashboard) with the release.

### 2. `LogView` (1644 lines) / `SettingsView` (1061) decomposition + `LogViewModel`
High value but high risk without tests. `LogView` re-renders its whole body on the 1 s `tick`.
Recommended: extract `CanInventoryList` / `ActiveTimersOverlay` / `StartTimerButton` / `SyncOverlay`
and drive the per-second part with `TimelineView(.periodic)` so only the timer overlay invalidates,
then move logic into a `@MainActor LogViewModel` (mirror `UsageGraphViewModel`). Keep all writes
funneling through `LogService`/`CanManager`; preserve every `@AppStorage` key. Do it in small,
separately-tested steps.

### 3. `CanCardView` per-card 1 Hz `Timer` → shared `TimelineView`
Each visible card runs its own `Timer.scheduledTimer(1s)` to refresh its countdown label.
Replace with one `TimelineView(.periodic(by: 1))` wrapping just the timer labels (N timers → 0).

### 4. `NicotineLevelView` 1 s `refreshTrigger`
A 1 Hz `updateTimer` toggles `refreshTrigger`, rebuilding the whole Chart every second even though
the data regenerates every 15 s. Drop the per-second full rebuild; rely on the 15 s regeneration
(or a `TimelineView` endpoint dot).

### 5. Typed `Notification.Name` constants
`PouchLogged` / `PouchRemoved` / `PouchEdited` / `PouchDeleted` and the `NavigateTo*` names are
stringly-typed across posters/observers. Moving them to typed constants is safe **only if the
`rawValue` strings stay byte-identical** (they're an implicit cross-component contract).

### 6. Notification tap navigation
`NotificationDelegate` posts `NavigateToCanManagement` / `ShowQuickLog` / `NavigateToNicotineLevels`
/ `NavigateToUsageStats` / `NavigateToUsageGraph`, but `ContentView` has no `.onReceive` for them,
so tapping a notification doesn't navigate. Either wire `.onReceive` handlers (switch tabs) +
register `UNNotificationCategory`s, or delete the dead branches. This is a product decision, not an
optimization, so it was left alone.
