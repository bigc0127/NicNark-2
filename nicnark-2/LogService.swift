//
// LogService.swift
// nicnark-2
//
// Centralized service for logging nicotine pouch usage.
// Single entry point for UI, URL scheme, Shortcuts, Watch, and multi-pouch batch logging.
//

import Foundation
import CoreData
import WidgetKit

/// Snapshot of all currently active pouches used to drive the single Live Activity + widget.
struct ActivePouchAggregate {
    /// Representative pouch id (longest remaining timer). Keys the Live Activity.
    let representativePouchId: String
    let insertionTime: Date
    let durationSeconds: TimeInterval
    /// Sum of stated mg across all active pouches.
    let totalNicotine: Double
    let activeCount: Int

    var endTime: Date { insertionTime.addingTimeInterval(durationSeconds) }

    var displayName: String {
        if activeCount > 1 {
            return "\(Int(totalNicotine.rounded()))mg (\(activeCount) pouches)"
        }
        return "\(Int(totalNicotine.rounded()))mg pouch"
    }
}

/**
 * LogService: static helpers for pouch logging + multi-pouch Live Activity policy.
 *
 * Policy: multiple pouches may be active, but exactly ONE Live Activity shows
 * total nicotine + the longest remaining timer.
 */
@MainActor
enum LogService {

    private static let predefinedAmounts: Set<Double> = [3.0, 6.0]

    /// Serializes end→recreate Live Activity rebuilds so rapid log/remove cannot race.
    private static var liveActivityPresentChain: Task<Void, Never>?

    // MARK: - Duration helpers

    /// Priority: customDuration > can.duration (minutes) > global FULL_RELEASE_TIME.
    static func resolveDurationSeconds(can: Can? = nil, customDuration: TimeInterval? = nil) -> TimeInterval {
        if let customDuration { return customDuration }
        let canDuration = can?.duration ?? 0
        if canDuration > 0 {
            return TimeInterval(canDuration * 60)
        }
        return FULL_RELEASE_TIME
    }

    /// Store duration as rounded whole minutes (Core Data Int32).
    static func minutesFromSeconds(_ seconds: TimeInterval) -> Int32 {
        Int32((seconds / 60).rounded())
    }

    static func calculateWeightedDuration(pouches: [(nicotineAmount: Double, duration: TimeInterval)]) -> TimeInterval {
        guard !pouches.isEmpty else { return FULL_RELEASE_TIME }
        let totalNicotine = pouches.reduce(0) { $0 + $1.nicotineAmount }
        guard totalNicotine > 0 else { return FULL_RELEASE_TIME }
        return pouches.reduce(0.0) { sum, pouch in
            sum + (pouch.duration * (pouch.nicotineAmount / totalNicotine))
        }
    }

    // MARK: - Custom buttons

    /// Inserts a CustomButton if missing. Does **not** call `ctx.save()` — callers
    /// must save so multi-insert batches stay atomic with a single save/rollback.
    static func ensureCustomButton(for amount: Double, in ctx: NSManagedObjectContext) {
        guard !predefinedAmounts.contains(amount) else { return }

        let fetch: NSFetchRequest<CustomButton> = CustomButton.fetchRequest()
        fetch.predicate = NSPredicate(format: "nicotineAmount == %f", amount)
        fetch.fetchLimit = 1

        if let found = try? ctx.fetch(fetch), found.first != nil { return }

        let btn = CustomButton(context: ctx)
        btn.nicotineAmount = amount
    }

    // MARK: - Aggregation (single Live Activity policy)

    /// Fetch active pouches and build the aggregate used by LA + widget.
    static func fetchActiveAggregate(in ctx: NSManagedObjectContext, at now: Date = Date()) -> ActivePouchAggregate? {
        let request: NSFetchRequest<PouchLog> = PouchLog.fetchRequest()
        request.predicate = NSPredicate(format: "removalTime == nil")
        request.sortDescriptors = [NSSortDescriptor(keyPath: \PouchLog.insertionTime, ascending: true)]
        let active = (try? ctx.fetch(request)) ?? []
        return aggregate(activePouches: active, at: now)
    }

    static func aggregate(activePouches: [PouchLog], at now: Date = Date()) -> ActivePouchAggregate? {
        guard !activePouches.isEmpty else { return nil }

        var totalNicotine = 0.0
        var bestRemaining: TimeInterval = -1
        var bestPouch: PouchLog?

        for pouch in activePouches {
            totalNicotine += pouch.nicotineAmount
            guard let insertion = pouch.insertionTime, pouch.pouchId != nil else { continue }
            let duration = pouch.effectiveDurationSeconds
            let remaining = max(0, duration - now.timeIntervalSince(insertion))
            if remaining > bestRemaining {
                bestRemaining = remaining
                bestPouch = pouch
            }
        }

        // Prefer longest remaining; fall back to any pouch with a UUID + insertion time.
        guard let representative = bestPouch
                ?? activePouches.first(where: { $0.pouchId != nil && $0.insertionTime != nil }),
              let insertion = representative.insertionTime,
              let pouchUUID = representative.pouchId
        else { return nil }

        return ActivePouchAggregate(
            representativePouchId: pouchUUID.uuidString,
            insertionTime: insertion,
            durationSeconds: representative.effectiveDurationSeconds,
            totalNicotine: totalNicotine,
            activeCount: activePouches.count
        )
    }

    /// Queue a serialized end→recreate of the single Live Activity for the current aggregate.
    /// Safe to call from many sites; concurrent calls run strictly one after another.
    /// Clears the chain head when done so completed Tasks are not retained forever.
    static func schedulePresentAggregatedLiveActivity(in ctx: NSManagedObjectContext) {
        let previous = liveActivityPresentChain
        let task = Task { @MainActor in
            _ = await previous?.value
            await presentAggregatedLiveActivity(in: ctx)
        }
        liveActivityPresentChain = task
        Task { @MainActor in
            await task.value
            if liveActivityPresentChain == task {
                liveActivityPresentChain = nil
            }
        }
    }

    /// Same as `schedulePresentAggregatedLiveActivity` but awaits completion (removal/sync paths).
    static func presentAggregatedLiveActivitySerialized(in ctx: NSManagedObjectContext) async {
        let previous = liveActivityPresentChain
        let task = Task { @MainActor in
            _ = await previous?.value
            await presentAggregatedLiveActivity(in: ctx)
        }
        liveActivityPresentChain = task
        await task.value
        if liveActivityPresentChain == task {
            liveActivityPresentChain = nil
        }
    }

    /// End any existing Live Activities and present ONE activity for the current aggregate.
    /// Prefer `schedulePresentAggregatedLiveActivity` / `…Serialized` so rebuilds cannot race.
    static func presentAggregatedLiveActivity(in ctx: NSManagedObjectContext) async {
        guard let agg = fetchActiveAggregate(in: ctx) else { return }

        let calculator = NicotineCalculator()
        let recent = (try? calculator.fetchRecentPouches(context: ctx)) ?? []
        let level = calculator.levelFromPouches(recent, at: Date())
        let now = Date()
        let elapsed = max(0, now.timeIntervalSince(agg.insertionTime))
        let progress = min(max(elapsed / max(1, agg.durationSeconds), 0), 1)

        // Attributes (total nicotine, start) are immutable — rebuild so multi-pouch totals stay correct.
        await LiveActivityManager.endAllLiveActivities()

        _ = await LiveActivityManager.startLiveActivity(
            for: agg.representativePouchId,
            nicotineAmount: agg.totalNicotine,
            insertionTime: agg.insertionTime,
            duration: agg.durationSeconds,
            isFromSync: false,
            initialNicotineLevel: level,
            absorptionProgress: progress,
            seedWidget: false
        )

        // Authoritative widget snapshot after LA exists (avoids level=0 seed race).
        updateWidgetSnapshotForActivePouches(in: ctx)
    }

    /// Widget snapshot from the multi-pouch aggregate + full bloodstream level.
    /// Always writes the decay-aware level — including when no pouches are active.
    static func updateWidgetSnapshotForActivePouches(in ctx: NSManagedObjectContext) {
        let helper = WidgetPersistenceHelper()
        let calculator = NicotineCalculator()
        let pouches = (try? calculator.fetchRecentPouches(context: ctx)) ?? []
        let level = calculator.levelFromPouches(pouches, at: Date())

        guard let agg = fetchActiveAggregate(in: ctx) else {
            helper.updateSnapshot(level: level, isRunning: false)
            helper.markActivityEnded()
            return
        }

        helper.setFromLiveActivity(
            level: level,
            peak: agg.totalNicotine * ABSORPTION_FRACTION,
            pouchName: agg.displayName,
            endTime: agg.endTime
        )
    }

    // MARK: - Single pouch log

    @discardableResult
    static func logPouch(
        amount mg: Double,
        ctx: NSManagedObjectContext,
        can: Can? = nil,
        customDuration: TimeInterval? = nil
    ) -> Bool {
        guard mg > 0 else { return false }

        ensureCustomButton(for: mg, in: ctx)

        let pouchIdUUID = UUID()
        let pouch = PouchLog(context: ctx)
        pouch.pouchId = pouchIdUUID
        pouch.insertionTime = .now
        pouch.nicotineAmount = mg

        let durationSeconds = resolveDurationSeconds(can: can, customDuration: customDuration)
        pouch.timerDuration = minutesFromSeconds(durationSeconds)

        if let can {
            can.addToPouchLogs(pouch)
            can.usePouch()
        }

        do {
            try ctx.save()
        } catch {
            print("❌ Failed to save PouchLog: \(error)")
            ctx.rollback()
            return false
        }

        let pouchId = pouchIdUUID.uuidString

        NotificationManager.scheduleCompletionAlert(
            id: pouchId,
            title: "Absorption complete",
            body: "Your \(Int(mg))mg pouch has finished absorbing.",
            fireDate: Date().addingTimeInterval(durationSeconds)
        )

        NotificationCenter.default.post(
            name: NSNotification.Name("PouchLogged"),
            object: nil,
            userInfo: ["mg": mg]
        )

        schedulePresentAggregatedLiveActivity(in: ctx)
        updateWidgetSnapshotForActivePouches(in: ctx)
        WidgetReloadCoordinator.reload()

        #if os(iOS)
        Task { @MainActor in await WatchConnectivityBridge.shared.pushHomeToWatch() }
        #endif

        Task {
            if can != nil {
                NotificationManager.checkCanInventory(context: ctx)
            }
            NotificationManager.scheduleUsageReminder(context: ctx)
        }

        Task { await BackgroundMaintainer.shared.scheduleSoon() }

        return true
    }

    // MARK: - Multi-pouch batch log

    /// Logs multiple pouches from cans in one save, one aggregated Live Activity, full side effects.
    /// - Parameter loads: can → count of pouches to log from that can
    /// - Returns: number of pouches successfully logged (0 on failure)
    @discardableResult
    static func logPouchesFromCans(
        loads: [(can: Can, count: Int)],
        ctx: NSManagedObjectContext
    ) -> Int {
        var created: [(pouchId: String, mg: Double, duration: TimeInterval, insertion: Date)] = []
        var index = 0
        var amountsForButtons = Set<Double>()

        for entry in loads {
            let can = entry.can
            let count = entry.count
            guard count > 0 else { continue }

            for _ in 0..<count {
                let pouch = PouchLog(context: ctx)
                pouch.pouchId = UUID()
                // Stagger timestamps slightly so Usage graph doesn't stack identical times.
                pouch.insertionTime = Date.now.addingTimeInterval(TimeInterval(index) * 0.1)
                pouch.nicotineAmount = can.strength

                let durationSeconds = resolveDurationSeconds(can: can)
                pouch.timerDuration = minutesFromSeconds(durationSeconds)

                can.addToPouchLogs(pouch)
                can.usePouch()

                if let id = pouch.pouchId?.uuidString, let insertion = pouch.insertionTime {
                    created.append((id, can.strength, durationSeconds, insertion))
                }
                amountsForButtons.insert(can.strength)
                index += 1
            }
        }

        guard !created.isEmpty else { return 0 }

        for amount in amountsForButtons {
            ensureCustomButton(for: amount, in: ctx)
        }

        do {
            try ctx.save()
        } catch {
            print("❌ Failed to save multi-pouch batch: \(error)")
            ctx.rollback()
            return 0
        }

        // Proximity-clustered completion alerts (one banner per cluster; every pouchId maps
        // to the request so cancelAlert still works and body reschedules on partial remove).
        let alertItems = created.map { item in
            (id: item.pouchId, mg: item.mg, fireDate: item.insertion.addingTimeInterval(item.duration))
        }
        NotificationManager.scheduleGroupedCompletionAlerts(alertItems)

        let totalMg = created.reduce(0.0) { $0 + $1.mg }
        NotificationCenter.default.post(
            name: NSNotification.Name("PouchLogged"),
            object: nil,
            userInfo: ["mg": totalMg, "count": created.count]
        )

        schedulePresentAggregatedLiveActivity(in: ctx)
        updateWidgetSnapshotForActivePouches(in: ctx)
        WidgetReloadCoordinator.reload()

        #if os(iOS)
        Task { @MainActor in await WatchConnectivityBridge.shared.pushHomeToWatch() }
        #endif

        Task {
            NotificationManager.checkCanInventory(context: ctx)
            NotificationManager.scheduleUsageReminder(context: ctx)
        }

        Task { await BackgroundMaintainer.shared.scheduleSoon() }

        return created.count
    }
}
