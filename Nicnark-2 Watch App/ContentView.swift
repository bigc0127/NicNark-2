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
        let strengthText = "\(Int(strength))mg"
        let countText = "\(pouchCount) left"
        return "\(strengthText) • \(countText)"
    }
}

struct WatchActivePouchSummary: Identifiable, Hashable, Sendable {
    let id: String
    let mg: Double
    let brand: String
    let flavor: String
    let remainingSeconds: TimeInterval

    var title: String {
        if brand.isEmpty && flavor.isEmpty {
            return "\(Int(mg))mg pouch"
        }

        let base = brand.isEmpty ? "Pouch" : brand
        let suffix = flavor.isEmpty ? "" : " \(flavor)"
        return "\(base)\(suffix)"
    }

    var subtitle: String {
        "\(Int(mg))mg • \(formatMinutesSeconds(remainingSeconds)) left"
    }
}

struct WatchNicotinePoint: Identifiable, Hashable, Sendable {
    let time: Date
    let level: Double

    var id: TimeInterval { time.timeIntervalSince1970 }
}

private func formatMinutesSeconds(_ timeInterval: TimeInterval) -> String {
    let seconds = Int(max(timeInterval, 0))
    return String(format: "%02d:%02d", seconds / 60, seconds % 60)
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

    func start() {
        guard WCSession.isSupported() else { return }

        let session = WCSession.default
        session.delegate = self
        session.activate()
        self.session = session

        updateReachability(from: session)
    }

    func refresh() {
        errorMessage = nil
        statusMessage = nil

        guard let session else {
            errorMessage = "WatchConnectivity not available"
            return
        }

        guard session.isReachable else {
            updateReachability(from: session)
            errorMessage = "Open the iPhone app to refresh"
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
        sendAction(
            ["action": "logPouchFromCanId", "canId": can.id],
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
                let remaining = dict["remaining"] as? Double ?? 0
                return WatchActivePouchSummary(
                    id: id,
                    mg: mg,
                    brand: brand,
                    flavor: flavor,
                    remainingSeconds: remaining
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

extension WatchDashboardViewModel: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let reachable = session.isReachable
        let errMsg = error?.localizedDescription
        Task { @MainActor in
            isReachable = reachable
            if let errMsg {
                errorMessage = errMsg
            }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in
            isReachable = reachable
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
                if !vm.activePouches.isEmpty {
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
                            Text(pouch.subtitle)
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
