//
//  ContentView.swift
//  Nicnark-2 Watch App
//
//  Created by Connor W. Needling on 2026/2/26.
//

import SwiftUI
import Combine
import WatchConnectivity
import Charts

// MARK: - Models

struct WatchCanSummary: Identifiable, Hashable, Sendable {
    let id: String
    let brand: String
    let flavor: String
    let strength: Double
    let pouchCount: Int
    let durationMinutes: Int

    var title: String {
        let base = brand.isEmpty ? "Unknown" : brand
        if flavor.isEmpty { return base }
        return "\(base) \(flavor)"
    }

    var subtitle: String {
        let strengthText = "\(safeInt(strength))mg"
        let countText = "\(pouchCount) left"
        return "\(strengthText) • \(countText)"
    }
}

struct WatchActivePouchSummary: Identifiable, Hashable, Sendable {
    let id: String
    let mg: Double
    let brand: String
    let flavor: String
    /// Absolute time the pouch is modeled to finish absorbing. Stored as a date (not a
    /// precomputed "seconds remaining") so the watch can render a live, self-updating
    /// countdown instead of a value frozen at the moment of the last sync.
    let removalDate: Date

    var title: String {
        if brand.isEmpty && flavor.isEmpty {
            return "\(safeInt(mg))mg pouch"
        }

        let base = brand.isEmpty ? "Pouch" : brand
        let suffix = flavor.isEmpty ? "" : " \(flavor)"
        return "\(base)\(suffix)"
    }

    var subtitle: String {
        "\(safeInt(mg))mg"
    }

    /// Crash-safe range for `Text(timerInterval:countsDown:)`. A reversed `ClosedRange`
    /// (lowerBound > upperBound) traps, so clamp the start to never exceed `removalDate`;
    /// once the timer has elapsed this collapses to a zero-length range and renders 00:00.
    var countdownRange: ClosedRange<Date> {
        let now = Date()
        return min(now, removalDate)...removalDate
    }
}

struct WatchNicotinePoint: Identifiable, Hashable, Sendable {
    let time: Date
    let level: Double

    var id: TimeInterval { time.timeIntervalSince1970 }
}

/// Converts a `Double` to `Int` without trapping. The stdlib `Int(_:)` initializer fatally
/// crashes on NaN, ±Infinity, or any value outside `Int`'s range — and these summaries are
/// built from raw WatchConnectivity payload doubles, so a single non-finite value (e.g. from
/// a corrupt sync) would otherwise crash the List on every render and every relaunch.
private func safeInt(_ value: Double) -> Int {
    guard value.isFinite else { return 0 }
    let rounded = value.rounded()
    if rounded >= Double(Int.max) { return Int.max }
    if rounded <= Double(Int.min) { return Int.min }
    return Int(rounded)
}

// MARK: - ViewModel

@MainActor
final class WatchDashboardViewModel: NSObject, ObservableObject {
    @Published var level: Double = 0
    @Published var activePouchCount: Int = 0
    @Published var totalPouches: Int = 0
    @Published var cans: [WatchCanSummary] = []

    @Published var activePouches: [WatchActivePouchSummary] = []
    @Published var graphPoints: [WatchNicotinePoint] = []

    @Published var isReachable: Bool = false
    @Published var isLoading: Bool = false

    @Published var statusMessage: String?
    @Published var errorMessage: String?

    private var session: WCSession?

    // Guards so onAppear (which fires on every re-appear) doesn't re-activate the session
    // or surface a spurious error before activation has settled.
    private var didStart = false
    private var hasActivated = false

    // Idempotency for watch-initiated logging: reuse the same request id when the
    // user re-taps the SAME can after a failed/uncertain send, so the iPhone can
    // de-duplicate a retry instead of double-logging. Cleared once any successful
    // reply confirms the watch is back in sync.
    private var pendingLogCanId: String?
    private var pendingLogRequestId: String?
    // Set only when a log send's errorHandler fires (lost/uncertain reply). A request id
    // is reused ONLY after such a failure, so a deliberate re-tap of the same can still
    // logs a second pouch instead of being silently de-duplicated as a retry.
    private var lastLogFailedCanId: String?
    // Timestamp of that last failed log send. Request-id reuse is additionally bounded to a
    // short window after the failure, so a deliberate same-can re-tap minutes later logs a
    // real second pouch instead of being deduped against a stale "retry".
    private var lastLogFailedAt: Date?

    // WCSessionDelegate is an Objective-C protocol whose callbacks fire on a background
    // queue. Keep that conformance OFF this @MainActor type (see WatchSessionDelegate) to
    // avoid the watchOS 26 actor-isolation trap, and retain the delegate here so it lives
    // as long as the view model.
    private let sessionDelegate = WatchSessionDelegate()

    override init() {
        super.init()
        sessionDelegate.viewModel = self
    }

    func start() {
        // onAppear fires on every re-appear; only activate once. (Set the flag AFTER the
        // isSupported check so an unsupported device isn't permanently latched.)
        guard !didStart else { return }
        guard WCSession.isSupported() else { return }
        didStart = true

        let session = WCSession.default
        session.delegate = sessionDelegate
        session.activate()
        self.session = session

        updateReachability(from: session)

        // Seed immediately from the last snapshot the iPhone pushed via application context,
        // so a cold launch shows real data right away — even before activation completes or
        // while the iPhone is unreachable (backgrounded).
        let cached = session.receivedApplicationContext
        if !cached.isEmpty {
            applyHomeReply(cached)
        }
    }

    func refresh() {
        // Skip if a fetch is already in flight: onAppear, activation, and reachability
        // callbacks can all call refresh() near-simultaneously.
        guard !isLoading else { return }

        errorMessage = nil
        statusMessage = nil

        guard let session else {
            errorMessage = "WatchConnectivity not available"
            return
        }

        guard session.isReachable else {
            updateReachability(from: session)
            // Can't reach the iPhone live, so fall back to the last snapshot it pushed via
            // application context — a backgrounded phone still shows recent data instead of
            // an error.
            let cached = session.receivedApplicationContext
            if !cached.isEmpty {
                applyHomeReply(cached)
                statusMessage = "Showing last synced data"
            } else if hasActivated {
                // Only surface the hint once activation has settled, so the cold-launch race
                // (refresh() running before activationDidComplete) doesn't flash an error
                // before any data has had a chance to arrive.
                errorMessage = "Open the iPhone app to refresh"
            }
            return
        }

        isLoading = true

        session.sendMessage(
            ["action": "getWatchHome"],
            replyHandler: { [weak self] reply in
                Task { @MainActor in
                    self?.applyHomeReply(reply)
                    self?.isLoading = false
                }
            },
            errorHandler: { [weak self] error in
                Task { @MainActor in
                    self?.errorMessage = error.localizedDescription
                    self?.isLoading = false
                }
            }
        )
    }

    func logFromCan(_ can: WatchCanSummary) {
        // Reuse the request id ONLY when re-tapping the SAME can whose last send actually
        // FAILED (so the iPhone dedups a genuine retry). A deliberate re-tap after a normal
        // send still mints a fresh id, so two intentional taps log two pouches.
        let requestId: String
        // Reuse only within a short retry window after an actual failure — well inside the
        // iPhone's 300s dedup window — so a deliberate re-tap of the same can a minute or
        // more later still mints a fresh id and logs a real second pouch.
        let recentFailure = lastLogFailedAt.map { Date().timeIntervalSince($0) < 60 } ?? false
        if pendingLogCanId == can.id, let existing = pendingLogRequestId, lastLogFailedCanId == can.id, recentFailure {
            requestId = existing
        } else {
            requestId = UUID().uuidString
        }
        pendingLogCanId = can.id
        pendingLogRequestId = requestId
        lastLogFailedCanId = nil  // this attempt is fresh until/unless its send fails
        lastLogFailedAt = nil

        sendAction(
            ["action": "logPouchFromCanId", "canId": can.id, "requestId": requestId],
            fallbackQueueMessage: "Queued log from \(can.title)"
        )
    }

    func removePouch(id: String) {
        sendAction(
            ["action": "removePouchById", "pouchId": id],
            fallbackQueueMessage: "Queued pouch removal on iPhone"
        )
    }

    func removeAllActivePouches() {
        sendAction(
            ["action": "removeAllActivePouches"],
            fallbackQueueMessage: "Queued removal on iPhone"
        )
    }

    // MARK: - Private

    private func sendAction(_ message: [String: Any], fallbackQueueMessage: String) {
        errorMessage = nil
        statusMessage = nil

        guard let session else {
            errorMessage = "WatchConnectivity not available"
            return
        }

        // Prefer immediate send+reply when possible.
        if session.isReachable {
            isLoading = true
            session.sendMessage(
                message,
                replyHandler: { [weak self] reply in
                    Task { @MainActor in
                        self?.applyActionReply(reply)
                        self?.isLoading = false
                    }
                },
                errorHandler: { [weak self] error in
                    Task { @MainActor in
                        self?.errorMessage = error.localizedDescription
                        self?.isLoading = false
                        // Record a failed log send so a deliberate re-tap of the SAME can
                        // reuses its request id (retry dedup); a fresh tap still mints a new id.
                        if message["action"] as? String == "logPouchFromCanId",
                           let canId = message["canId"] as? String {
                            self?.lastLogFailedCanId = canId
                            self?.lastLogFailedAt = Date()
                        }
                    }
                }
            )
            return
        }

        // Fallback: queue on iPhone.
        session.transferUserInfo(message)
        updateReachability(from: session)
        statusMessage = fallbackQueueMessage
    }

    private func applyActionReply(_ reply: [String: Any]) {
        if let ok = reply["ok"] as? Bool, ok == false {
            errorMessage = reply["error"] as? String ?? "Action failed"
            return
        }

        // Most actions return an updated watch-home payload.
        applyHomeReply(reply)
    }

    private func applyHomeReply(_ reply: [String: Any]) {
        if let ok = reply["ok"] as? Bool, ok == false {
            errorMessage = reply["error"] as? String ?? "Request failed"
            return
        }

        // A successful payload means the watch is in sync; any in-flight log
        // request is resolved, so future taps start a new request id.
        pendingLogCanId = nil
        pendingLogRequestId = nil

        if let level = reply["level"] as? Double {
            self.level = level
        }
        if let active = reply["activePouchCount"] as? Int {
            self.activePouchCount = active
        }
        if let total = reply["totalPouches"] as? Int {
            self.totalPouches = total
        }

        if let canDicts = reply["cans"] as? [[String: Any]] {
            self.cans = canDicts.compactMap { dict in
                guard let id = dict["id"] as? String else { return nil }
                let brand = dict["brand"] as? String ?? ""
                let flavor = dict["flavor"] as? String ?? ""
                let strength = dict["strength"] as? Double ?? 0
                let pouchCount = dict["pouchCount"] as? Int ?? 0
                let duration = dict["duration"] as? Int ?? 0
                return WatchCanSummary(
                    id: id,
                    brand: brand,
                    flavor: flavor,
                    strength: strength,
                    pouchCount: pouchCount,
                    durationMinutes: duration
                )
            }
        }

        if let pouchDicts = reply["activePouches"] as? [[String: Any]] {
            self.activePouches = pouchDicts.compactMap { dict in
                guard let id = dict["id"] as? String else { return nil }
                let mg = dict["mg"] as? Double ?? 0
                let brand = dict["brand"] as? String ?? ""
                let flavor = dict["flavor"] as? String ?? ""
                // Prefer absolute insertionTime + duration so the watch can run a live
                // countdown; fall back to the precomputed `remaining` (relative to now) for
                // older payloads that don't carry the absolute fields.
                let removalDate: Date
                if let insertion = dict["insertionTime"] as? Double,
                   let duration = dict["duration"] as? Double {
                    removalDate = Date(timeIntervalSince1970: insertion + duration)
                } else {
                    let remaining = dict["remaining"] as? Double ?? 0
                    removalDate = Date().addingTimeInterval(max(0, remaining))
                }
                return WatchActivePouchSummary(
                    id: id,
                    mg: mg,
                    brand: brand,
                    flavor: flavor,
                    removalDate: removalDate
                )
            }
        }

        if let graphDicts = reply["graphPoints"] as? [[String: Any]] {
            self.graphPoints = graphDicts.compactMap { dict in
                guard let time = dict["time"] as? Double else { return nil }
                let level = dict["level"] as? Double ?? 0
                return WatchNicotinePoint(time: Date(timeIntervalSince1970: time), level: level)
            }
        }

        if let session {
            updateReachability(from: session)
        }
    }

    private func updateReachability(from session: WCSession) {
        isReachable = session.isReachable
    }
}

// MARK: - WCSession delegate handlers (run on the @MainActor view model)

extension WatchDashboardViewModel {
    func handleActivation(reachable: Bool, activated: Bool, errorMessage errMsg: String?, context: [String: Any]) {
        isReachable = reachable
        if activated { hasActivated = true }
        if let errMsg {
            errorMessage = errMsg
        }
        // Render whatever the iPhone last pushed, even if we can't reach it now.
        if !context.isEmpty {
            applyHomeReply(context)
        }
        // onAppear's refresh() bails before activation completes, so load now that the
        // session is ready. (refresh() clears any stale error itself.)
        if activated && reachable && !isLoading {
            refresh()
        }
    }

    func handleReceivedContext(_ context: [String: Any]) {
        // The iPhone proactively pushed a fresh watch-home snapshot (e.g. after a pouch was
        // logged or removed on the phone). Apply it so the watch updates passively without
        // the user needing to be reachable or to tap Refresh.
        applyHomeReply(context)
    }

    func handleReachabilityChange(reachable: Bool) {
        let wasReachable = isReachable
        isReachable = reachable
        // Becoming reachable (e.g. after a cold launch) should auto-fetch.
        if reachable && !wasReachable && !isLoading {
            refresh()
        }
    }
}

// MARK: - WCSession delegate (kept OFF the @MainActor view model)

/// Dedicated `WCSession` delegate. `WCSessionDelegate` is an Objective-C protocol whose
/// callbacks WatchConnectivity invokes on a background queue. Conforming the `@MainActor`
/// view model to it directly made the watchOS 26 Swift runtime trap with an actor-isolation
/// assertion (`EXC_BREAKPOINT`) the instant a payload was delivered — and marking the methods
/// `nonisolated` was NOT enough to prevent it. This plain, non-isolated `NSObject` legally
/// runs every callback on the WC queue and simply hops the work to the view model.
final class WatchSessionDelegate: NSObject, WCSessionDelegate {
    weak var viewModel: WatchDashboardViewModel?

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let reachable = session.isReachable
        let activated = (activationState == .activated)
        let errMsg = error?.localizedDescription
        // [String: Any] isn't Sendable; wrap it to cross into the MainActor hop safely
        // (WC application-context values are plist types, so this is sound).
        struct Box: @unchecked Sendable { let ctx: [String: Any] }
        let box = Box(ctx: session.receivedApplicationContext)
        let vm = viewModel
        Task { @MainActor in
            vm?.handleActivation(reachable: reachable, activated: activated, errorMessage: errMsg, context: box.ctx)
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        struct Box: @unchecked Sendable { let ctx: [String: Any] }
        let box = Box(ctx: applicationContext)
        let vm = viewModel
        Task { @MainActor in
            vm?.handleReceivedContext(box.ctx)
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        let vm = viewModel
        Task { @MainActor in
            vm?.handleReachabilityChange(reachable: reachable)
        }
    }
}

// MARK: - View

struct ContentView: View {
    @StateObject private var vm = WatchDashboardViewModel()
    @State private var showingFullscreenChart = false

    var body: some View {
        List {
            Section {
                // Show the chart whenever there is meaningful residual nicotine — not only
                // while a pouch is active — so the decay tail after the last removal is still
                // visible (and tappable to the fullscreen chart). The iPhone always emits
                // graph points, so gate on level rather than non-emptiness.
                if vm.graphPoints.contains(where: { $0.level > 0.01 }) {
                    WatchNicotineChartCompact(points: vm.graphPoints)
                        .frame(height: 96)
                        .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            showingFullscreenChart = true
                        }
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Nicotine")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if vm.isLoading {
                            ProgressView()
                        }
                    }

                    Text(String(format: "%.3f mg", vm.level))
                        .font(.title2.bold())

                    Text("Active pouches: \(vm.activePouchCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("Inventory: \(vm.totalPouches) total")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)

                if let msg = vm.statusMessage {
                    Text(msg)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if let err = vm.errorMessage {
                    Text(err)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }

                Button("Refresh") { vm.refresh() }
            }

            if !vm.activePouches.isEmpty {
                Section("Active pouches") {
                    ForEach(vm.activePouches) { pouch in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pouch.title)
                                .lineLimit(1)
                            HStack(spacing: 4) {
                                Text(pouch.subtitle)
                                // Self-updating countdown — no manual Timer needed, and it
                                // stays accurate between syncs instead of freezing at the
                                // value captured when the snapshot was last received.
                                Text(timerInterval: pouch.countdownRange, countsDown: true)
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                vm.removePouch(id: pouch.id)
                            } label: {
                                Text("Remove")
                            }
                        }
                    }

                    Button(role: .destructive) {
                        vm.removeAllActivePouches()
                    } label: {
                        Text("Remove all pouches")
                    }
                }
            }

            Section("Log from inventory") {
                if vm.cans.isEmpty {
                    Text("No cans in inventory")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(vm.cans) { can in
                        Button {
                            vm.logFromCan(can)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(can.title)
                                Text(can.subtitle)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            vm.start()
            vm.refresh()
        }
        .sheet(isPresented: $showingFullscreenChart) {
            WatchNicotineChartFullscreen(points: vm.graphPoints)
        }
    }
}

// MARK: - Graph

struct WatchNicotineChartCompact: View {
    let points: [WatchNicotinePoint]

    var body: some View {
        let data = points.sorted(by: { $0.time < $1.time })
        Chart(data) { p in
            LineMark(
                x: .value("Time", p.time),
                y: .value("Level", p.level)
            )
            .foregroundStyle(.green)
            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 2)) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel(format: .dateTime.hour(), centered: true)
            }
        }
        .chartYAxis(.hidden)
        .chartPlotStyle { plotArea in
            plotArea
                .background(Color.gray.opacity(0.2))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

struct WatchNicotineChartFullscreen: View {
    let points: [WatchNicotinePoint]

    @Environment(\.dismiss) private var dismiss
    @State private var selected: WatchNicotinePoint?

    var body: some View {
        let data = points.sorted(by: { $0.time < $1.time })

        NavigationStack {
            VStack(alignment: .leading, spacing: 8) {
                if let selected {
                    Text("\(selected.time.formatted(date: .omitted, time: .shortened)) • \(selected.level, specifier: "%.3f") mg")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                } else if let last = data.last {
                    Text("Now • \(last.level, specifier: "%.3f") mg")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                }

                Chart {
                    ForEach(data) { p in
                        LineMark(
                            x: .value("Time", p.time),
                            y: .value("Level", p.level)
                        )
                        .foregroundStyle(.green)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    }

                    if let selected {
                        RuleMark(x: .value("Selected", selected.time))
                            .foregroundStyle(.secondary)
                        PointMark(
                            x: .value("Selected", selected.time),
                            y: .value("Selected", selected.level)
                        )
                        .symbolSize(40)
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .hour)) { value in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel(format: .dateTime.hour(), centered: true)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel()
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        Rectangle()
                            .fill(Color.clear)
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { value in
                                        guard let plotFrame = proxy.plotFrame else { return }
                                        let origin = geo[plotFrame].origin
                                        let xPos = value.location.x - origin.x
                                        guard let date: Date = proxy.value(atX: xPos) else { return }

                                        if let nearest = data.min(by: { abs($0.time.timeIntervalSince(date)) < abs($1.time.timeIntervalSince(date)) }) {
                                            selected = nearest
                                        }
                                    }
                                    .onEnded { _ in
                                        // Keep selection
                                    }
                            )
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 8)

                Spacer(minLength: 0)
            }
            .navigationTitle("Levels")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
