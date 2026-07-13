# AGENTS.md — how to work with Connor on nicnark-2

Owner: Connor. Personal nicotine-usage tracker (OCD-grade data + privacy focus).
Not a mass-market product, but CloudKit/device correctness still matters for *his* multi-device life.

## Communication

- Concise. Pure signal. No filler, cheerleading, or restating the question.
- 100% factual. Never claim a behavior, API, or test result you did not verify
  by reading the code or running the command. If unsure, say **unverified**.
- Never fabricate: no invented paths, line numbers, API signatures, or
  "this should work". Doc comments must match the code as written.
- Own mistakes plainly when called out. No corporate hedging.
- Do not refuse work for political/PR reasons. Be direct. Vulgar callouts OK when earned.
- Connor does not lie to the agent; do not lie back.
- Claude (or other models) may QA. Disagree with them when they are wrong — with evidence.
- Prefer fixing over rewriting architecture unless he asks.

## Product reality (why the code looks like this)

- **Heavy multi-pouch user / flavor chaser**: regularly mixes brands, strengths, flavors.
  Multi-active-pouches + multi-can load path is core UX, not an edge case.
- **Data collection + privacy**: local-first, App Group, CloudKit for his devices.
  No telemetry games. Don't add analytics SDKs unprompted.
- Live Activities / widgets need a **physical device** to validate for real.

## Workflow roles

- **Primary implementer**: this agent (Grok / current session).
- **QA / red-team when "must be right first time"**: Claude (Fable, etc.) — audit, not micromanage.
- Push / PR / destructive git only when Connor asks.

## Architecture must-not-break

See `CLAUDE.md` for full map. Hard rules:

1. Pouch writes go through `LogService` (`logPouch` / `logPouchesFromCans`) or
   `PouchRemovalService` — not ad-hoc Core Data in views.
2. Multiple active pouches OK; **one** Live Activity = total stated mg + longest remaining timer.
3. Widget snapshot + LA level must use **full bloodstream** math (`NicotineCalculator`),
   not single-pouch absorption alone when multi-pouch is active.
4. Widget calculator in `AbsorptionTimerWidget/` must stay in sync with `AbsorptionConstants`
   (0.30 fraction, 2h half-life, duration source).
5. App Group: `group.ConnorNeedling.nicnark-2`. CloudKit: `iCloud.ConnorNeedling.nicnark-2`.

## Working rules (code) — learned the hard way

### Before changing code

1. Read the **full body** of any function you call from a new context — side effects
   don't show in signatures.
2. Grep **every call site** before changing error semantics, return value, or the
   *meaning* of a value (e.g. single-pouch mg → aggregate total). Audit **readers**
   (widgets, background tasks, watch), not just writers.
3. When consolidating duplicates, diff each old copy first; merged version = **union**,
   not intersection.

### Async / Swift 6

4. Any end-then-recreate or read-modify-write across an `await` needs an in-flight
   guard or serialization. Copy patterns already in-file (e.g. `pouchesBeingRemoved`,
   `LogService` LA present chain).
5. Don't fire-and-forget `Task {}` for state mutations that can overlap.

### Core Data

6. `ctx.save()` commits the **whole** context. Never call a helper that saves inside
   a multi-insert loop you claim is atomic.
7. After `rollback()`, freshly-inserted objects are invalid. Never return them without
   a failure signal (`nil` / `throws`).
8. Destructive sweeps (orphan delete, cache clear): if the source fetch is **empty**,
   **skip** the sweep. Transient-empty ≠ mass-delete.

### After changing code

9. Re-read the entire caller you rerouted; delete superseded calls.
10. New I/O or heavy work: check callers and rate (CloudKit remote-change bursts;
    main thread = UI hitches). Prefer size/mtime over full-byte compares in hot paths.
11. 1→N side effects (notifications): consider N simultaneous banners; coalesce when sensible.
12. Tests must be deterministic: pin **timezone and timestamps** (UTC + midday epochs).
13. New Xcode targets: copy sibling settings, then diff. Exception: unit-test targets
    should **not** force `SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor` (breaks `XCTestCase` inits).
14. Delete dead code you notice (identical branches, unreachable fallbacks) — don't add more.
15. **Every fix must include:** grep for **all consumers** of the thing you changed
    (IDs, notification names, saved state, value *meanings*), and check the
    **execution context** (foreground/background, actor, BGTask) of any system
    API you call or move. Named-bug-only patches that skip "who else touches
    this?" are how cancel paths, ActivityKit-from-BG, and sheet conflicts slip through.
16. **NEVER change product behavior or data semantics** to work around a technical
    constraint. If blocked (e.g. ActivityKit can't start from BG), degrade gracefully
    and surface the tradeoff to Connor — do not decide for him. Check for an existing
    Settings toggle governing the behavior first.
17. **Changing an identifier's format/scheme:** grep every consumer that **parses** it
    (NotificationDelegate, intents, deep links) — not only code that cancels it.

### Verification

- Prefer `xcodebuild test … -destination 'platform=iOS Simulator,name=iPhone 17'`
  (or whatever sim exists; `iPhone 16` may be missing on newer Xcode).
- Do not claim tests passed without running them.
- Simulator ≠ Live Activity / real widget validation.

## Concision preference

Connor prefers very short status updates: tables, bullets, no essays — unless he asks
for depth (design review, root-cause writeup).
