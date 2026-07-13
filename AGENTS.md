# AGENTS.md — how to work with Connor on nicnark-2

Owner: Connor. Personal nicotine-usage tracker (OCD-grade data + privacy focus).
Not a mass-market product, but CloudKit/device correctness still matters for *his* multi-device life.

## Global rules (communication, git, hard-learned working rules)

**Authoritative copy lives in `~/.grok/AGENTS.md`** (and summary in `~/.grok/memory/MEMORY.md`).
Those apply here: commit-as-you-go, verification bar, consumer greps, Swift 6 zero-warning,
concurrency guards, sheets/camera pitfalls, CloudKit Production vs Development, scope discipline, etc.

Do not re-litigate or fork those rules in this file — update the global file instead.

## Product reality (why the code looks like this)

- **Heavy multi-pouch user / flavor chaser**: regularly mixes brands, strengths, flavors.
  Multi-active-pouches + multi-can load path is core UX, not an edge case.
- **Data collection + privacy**: local-first, App Group, CloudKit for his devices.
  No telemetry games. Don't add analytics SDKs unprompted.
- Live Activities / widgets need a **physical device** to validate for real.

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
6. **CloudKit environment is Production** even for Xcode/debug installs
   (`com.apple.developer.icloud-container-environment` in entitlements) so NotchNest
   (Developer ID / Production) can read the same pouch rows.

## Verification (project-specific)

- Prefer `xcodebuild test … -destination 'platform=iOS Simulator,name=iPhone 17'`
  (or whatever sim exists; `iPhone 16` may be missing on newer Xcode).
- Do not claim tests passed without running them.
- After camera/concurrency changes: scan build log for isolation warnings.
- Simulator ≠ Live Activity / real widget validation.
