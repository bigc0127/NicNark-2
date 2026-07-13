//
//  InsightsView.swift
//  nicnark-2
//
//  The BIG "Insights" dashboard hub — a single scrollable screen that surfaces every
//  aggregated statistic the app can derive from the user's PouchLog history. It is meant to
//  be presented as a sheet inside a NavigationStack (the caller adds the toolbar button and
//  `.sheet` in ContentView).
//
//  DESIGN / CONCURRENCY NOTES
//  --------------------------
//  • This view is READ-ONLY. It never mutates Core Data. It fetches recent `PouchLog` rows
//    via @FetchRequest, hands the (already-fetched, main-actor) array to the shared
//    `InsightsData.build(...)` foundation factory, and renders the resulting value type.
//  • `InsightsData` (from InsightsSupport.swift) reduces every managed object to plain value
//    types the instant it's built, so nothing non-Sendable escapes this view.
//  • The project builds under Swift 6 with SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor, so this
//    View struct is implicitly @MainActor — every helper here is called from the main actor.
//  • Settings (daily goal, price per tin, pouches per tin) live in UserDefaults ONLY, mirrored
//    here in @State so the Steppers/TextField feel live, then written back through
//    `InsightsSettings`.
//
//  The five feature sections, in order:
//    (1) KPI cards grid          — today / 7d / 30d pouches + estimated absorbed mg
//    (2) Trend charts            — 14-day daily-count BarMark + weekday-average BarMark
//    (3) Daily Goal              — Stepper bound to the goal + today's progress Gauge
//    (4) Streaks & Milestones    — goal streak, longest nic-free gap, totals, badge grid
//    (5) Cost                    — price/pouches-per-tin inputs + spend today/week/month + projected
//  ...plus two ShareLinks (summary text and CSV export).
//

import SwiftUI
import Charts
import Combine
import CoreData

// MARK: - InsightsView

struct InsightsView: View {

    // MARK: Environment / data

    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    /// Recent pouch history. We fetch a generous window (last ~60 days) so the foundation can
    /// compute prior-period trends (which reach back 60 days) without a second query. All-time
    /// totals in the foundation are derived from THIS array, so we intentionally do not clamp
    /// too aggressively — 60 days is plenty for every section on this screen.
    ///
    /// NOTE: The build predicate below is evaluated at init time (call time — never in a static
    /// initializer), so it uses a live `Date()` correctly.
    @FetchRequest private var recentLogs: FetchedResults<PouchLog>

    // MARK: Live-editable settings (mirrored from UserDefaults)

    @State private var dailyGoal: Int
    @State private var pricePerTin: Double
    @State private var pouchesPerTin: Int
    @State private var priceText: String

    /// A refresh nonce so `Date()`-dependent aggregates recompute if the sheet is left open a
    /// long time (e.g. across a midnight boundary) and the user pulls to refresh.
    @State private var refreshNonce = 0

    /// Currency symbol from the current locale (falls back to "$").
    private let currencySymbol: String = Locale.current.currencySymbol ?? "$"

    // MARK: Public initializer

    /// Callable simply as `InsightsView()`.
    init() {
        // Fetch ALL logged pouches — NOT a recent window. The all-time stats (Total Pouches,
        // Days Tracked, milestone badges, best goal streak) must see every pouch; a 60-day
        // window made them wildly undercount (e.g. 358 instead of 2000+). The rolling-window
        // cards (today / 7d / 30d, the 14-day chart, the 30-day longest gap) each filter by
        // date INSIDE InsightsData.build(), so feeding the full history keeps them correct
        // while fixing the totals. `insertionTime != nil` drops incomplete rows (reducedToPoints
        // guards this too). A few thousand value-typed rows is cheap to aggregate.
        self._recentLogs = FetchRequest<PouchLog>(
            entity: PouchLog.entity(),
            sortDescriptors: [NSSortDescriptor(keyPath: \PouchLog.insertionTime, ascending: true)],
            predicate: NSPredicate(format: "insertionTime != nil")
        )

        // Seed the live-editable state from persisted settings.
        _dailyGoal      = State(initialValue: InsightsSettings.dailyPouchGoal)
        _pricePerTin    = State(initialValue: InsightsSettings.pricePerTin)
        _pouchesPerTin  = State(initialValue: InsightsSettings.pouchesPerTin)

        let seededPrice = InsightsSettings.pricePerTin
        _priceText = State(initialValue: seededPrice > 0 ? String(format: "%.2f", seededPrice) : "")
    }

    // MARK: Derived aggregate
    //
    // Rebuilt on every render. Cheap even over full history (a few thousand rows) and keeps the UI perfectly in sync
    // with the @FetchRequest results and the live setting @States. `refreshNonce` is read here
    // purely so a manual refresh forces a fresh `Date()` evaluation.

    // The aggregate is STORED, not recomputed on every access. The previous computed-property
    // version rebuilt InsightsData over the FULL history on every single `data.` read — and it's
    // read dozens of times per render across all the sections — which pinned the CPU (lag +
    // device heat). Now it's built once and rebuilt only when an input actually changes.
    @State private var data: InsightsData = .empty
    @State private var hasLoaded = false
    /// Coalesce burst of pouch events (log+remove) into one rebuild.
    @State private var recomputeWorkItem: DispatchWorkItem?

    /// Rebuild the aggregate from the current fetch + settings. Never per body access.
    private func recompute() {
        data = InsightsData.build(
            from: Array(recentLogs),
            now: Date(),
            calendar: .current,
            goalLimit: dailyGoal,
            pricePerTin: pricePerTin,
            pouchesPerTin: pouchesPerTin,
            currencySymbol: currencySymbol
        )
        hasLoaded = true
    }

    private func scheduleRecompute() {
        recomputeWorkItem?.cancel()
        let work = DispatchWorkItem { recompute() }
        recomputeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    // MARK: Body

    var body: some View {
        ScrollView {
            if !hasLoaded {
                ProgressView()
                    .padding(.top, 60)
            } else if data.totalPouches == 0 {
                emptyState
                    .padding(.top, 60)
            } else {
                VStack(alignment: .leading, spacing: 24) {
                    kpiSection
                    chartsSection
                    dailyGoalSection
                    streaksSection
                    costSection
                    shareSection
                }
                .padding()
            }
        }
        .navigationTitle("Insights")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
        // Build once on appear; debounced on fetch/settings/pouch events (not O(N) per render).
        .task { recompute() }
        .onChange(of: recentLogs.count) { _, _ in scheduleRecompute() }
        .onChange(of: dailyGoal) { _, _ in scheduleRecompute() }
        .onChange(of: pricePerTin) { _, _ in scheduleRecompute() }
        .onChange(of: pouchesPerTin) { _, _ in scheduleRecompute() }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("PouchLogged"))) { _ in scheduleRecompute() }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("PouchRemoved"))) { _ in scheduleRecompute() }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("PouchEdited"))) { _ in scheduleRecompute() }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("PouchDeleted"))) { _ in scheduleRecompute() }
        // Cross-device CloudKit imports update the store without local pouch events.
        // Core Data posts this on a private queue; hop to main before any @State touch.
        .onReceive(
            NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange)
                .receive(on: DispatchQueue.main)
        ) { _ in
            scheduleRecompute()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { scheduleRecompute() }
        }
        .refreshable {
            refreshNonce &+= 1
            recompute()
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Pouches Yet", systemImage: "chart.bar.xaxis")
        } description: {
            Text("Start logging pouches to unlock your stats, trends, streaks, and cost tracking.")
        }
    }

    // MARK: - (1) KPI cards grid

    private var kpiSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Overview", systemImage: "square.grid.2x2")

            let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
            LazyVGrid(columns: columns, spacing: 12) {
                KPICard(
                    title: "Today",
                    value: "\(data.todayCount)",
                    subtitle: "~\(mg(data.todayAbsorbedMg)) mg absorbed",
                    systemImage: "calendar",
                    tint: .blue
                )
                KPICard(
                    title: "Last 7 Days",
                    value: "\(data.last7Count)",
                    subtitle: "\(trendLabel(data.trend7)) · ~\(mg(data.last7AbsorbedMg)) mg",
                    systemImage: "chart.bar",
                    tint: .green
                )
                KPICard(
                    title: "Last 30 Days",
                    value: "\(data.last30Count)",
                    subtitle: "\(trendLabel(data.trend30)) · ~\(mg(data.last30AbsorbedMg)) mg",
                    systemImage: "chart.bar.doc.horizontal",
                    tint: .orange
                )
                KPICard(
                    title: "Daily Avg (14d)",
                    value: String(format: "%.1f", data.dailyAverage14),
                    subtitle: "pouches / day",
                    systemImage: "gauge.with.dots.needle.bottom.50percent",
                    tint: .purple
                )
            }
        }
    }

    // MARK: - (2) Charts (14-day daily count + weekday average)

    private var chartsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader("Trends", systemImage: "chart.xyaxis.line")

            // --- 14-day daily-count bar chart ---
            VStack(alignment: .leading, spacing: 8) {
                Text("Last 14 Days")
                    .font(.subheadline).fontWeight(.semibold)
                Chart(data.perDayLast14) { day in
                    BarMark(
                        x: .value("Day", day.date, unit: .day),
                        y: .value("Pouches", day.count)
                    )
                    .foregroundStyle(Color.blue.gradient)
                    .cornerRadius(4)
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: 2)) { value in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.day().month(.abbreviated), centered: true)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading)
                }
                .frame(height: 200)
            }
            .padding()
            .background(Color(.secondarySystemBackground))
            .cornerRadius(16)

            // --- Weekday-average bar chart ---
            VStack(alignment: .leading, spacing: 8) {
                Text("Average by Weekday")
                    .font(.subheadline).fontWeight(.semibold)
                Chart(data.weekdayAverages) { wd in
                    BarMark(
                        x: .value("Weekday", weekdayShortName(wd.weekday)),
                        y: .value("Average", wd.average)
                    )
                    .foregroundStyle(
                        wd.weekday == data.peakWeekday
                            ? Color.orange.gradient
                            : Color.teal.gradient
                    )
                    .cornerRadius(4)
                }
                .chartXAxis {
                    AxisMarks(values: .automatic) { _ in
                        AxisValueLabel()
                    }
                }
                .frame(height: 180)

                Text("Busiest day: \(weekdayLongName(data.peakWeekday))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(Color(.secondarySystemBackground))
            .cornerRadius(16)
        }
    }

    // MARK: - (3) Daily Goal

    private var dailyGoalSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader("Daily Goal", systemImage: "target")

            VStack(alignment: .leading, spacing: 16) {
                // Stepper bound to the goal; 0 = unset.
                Stepper(value: $dailyGoal, in: 0...50) {
                    HStack {
                        Text("Goal")
                        Spacer()
                        Text(dailyGoal == 0 ? "Not set" : "\(dailyGoal) / day")
                            .foregroundColor(.secondary)
                    }
                }
                .onChange(of: dailyGoal) { _, newValue in
                    InsightsSettings.dailyPouchGoal = newValue
                }

                if dailyGoal > 0 {
                    // Today's progress gauge.
                    let progress = min(Double(data.todayCount) / Double(max(dailyGoal, 1)), 1.0)
                    let overGoal = data.todayCount > dailyGoal

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Today's Progress")
                                .font(.subheadline)
                            Spacer()
                            Text("\(data.todayCount) / \(dailyGoal)")
                                .font(.subheadline).fontWeight(.semibold)
                                .foregroundColor(overGoal ? .red : .primary)
                        }
                        Gauge(value: progress) {
                            EmptyView()
                        }
                        .tint(overGoal ? .red : .green)

                        Text(overGoal
                             ? "Over your daily goal by \(data.todayCount - dailyGoal)."
                             : "\(max(dailyGoal - data.todayCount, 0)) remaining to stay on goal.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else {
                    Text("Set a daily goal to track your progress and build a streak.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding()
            .background(Color(.secondarySystemBackground))
            .cornerRadius(16)
        }
    }

    // MARK: - (4) Streaks & Milestones

    private var streaksSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader("Streaks & Milestones", systemImage: "flame")

            // Quick stat rows.
            VStack(spacing: 0) {
                statRow(icon: "flame.fill", tint: .orange,
                        label: "Goal Streak",
                        value: dailyGoal > 0 ? "\(data.goalStreak) day\(data.goalStreak == 1 ? "" : "s")" : "Set a goal")
                Divider()
                statRow(icon: "trophy.fill", tint: .yellow,
                        label: "Best Goal Streak",
                        value: dailyGoal > 0 ? "\(data.goalBestStreak) day\(data.goalBestStreak == 1 ? "" : "s")" : "—")
                Divider()
                statRow(icon: "moon.zzz.fill", tint: .indigo,
                        label: "Longest Gap (30d)",
                        value: data.formattedLongestGap)
                Divider()
                statRow(icon: "clock.arrow.circlepath", tint: .teal,
                        label: "Average Gap",
                        value: data.formattedAverageGap)
                Divider()
                statRow(icon: "sum", tint: .purple,
                        label: "Total Pouches",
                        value: "\(data.totalPouches)")
                Divider()
                statRow(icon: "calendar", tint: .blue,
                        label: "Days Tracked",
                        value: "\(data.daysTracked)")
            }
            .padding()
            .background(Color(.secondarySystemBackground))
            .cornerRadius(16)

            // Milestone badges.
            VStack(alignment: .leading, spacing: 10) {
                Text("Badges")
                    .font(.subheadline).fontWeight(.semibold)

                let badgeColumns = [
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12)
                ]
                LazyVGrid(columns: badgeColumns, spacing: 12) {
                    ForEach(data.milestoneProgress) { milestone in
                        milestoneBadge(milestone)
                    }
                }
            }
            .padding()
            .background(Color(.secondarySystemBackground))
            .cornerRadius(16)
        }
    }

    private func milestoneBadge(_ milestone: Milestone) -> some View {
        VStack(spacing: 6) {
            Image(systemName: milestone.symbol)
                .font(.title)
                .foregroundColor(milestone.achieved ? .yellow : .secondary.opacity(0.4))
            Text(milestone.title)
                .font(.caption2)
                .foregroundColor(milestone.achieved ? .primary : .secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(milestone.achieved
                      ? Color.yellow.opacity(0.12)
                      : Color(.tertiarySystemBackground))
        )
        .opacity(milestone.achieved ? 1.0 : 0.6)
    }

    // MARK: - (5) Cost

    private var costSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader("Cost", systemImage: "dollarsign.circle")

            VStack(alignment: .leading, spacing: 16) {
                // Price per tin (TextField) — parsed and persisted on change.
                HStack {
                    Text("Price per Tin")
                    Spacer()
                    Text(currencySymbol)
                        .foregroundColor(.secondary)
                    TextField("0.00", text: $priceText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: priceText) { _, newValue in
                            // Robust parse: strip currency symbol / stray characters.
                            let cleaned = newValue
                                .replacingOccurrences(of: currencySymbol, with: "")
                                .trimmingCharacters(in: .whitespaces)
                            let parsed = Double(cleaned) ?? 0
                            let safe = parsed.isFinite && parsed >= 0 ? parsed : 0
                            pricePerTin = safe
                            InsightsSettings.pricePerTin = safe
                        }
                }

                // Pouches per tin (Stepper).
                Stepper(value: $pouchesPerTin, in: 1...100) {
                    HStack {
                        Text("Pouches per Tin")
                        Spacer()
                        Text("\(pouchesPerTin)")
                            .foregroundColor(.secondary)
                    }
                }
                .onChange(of: pouchesPerTin) { _, newValue in
                    InsightsSettings.pouchesPerTin = newValue
                }

                if pricePerTin > 0 {
                    Divider()

                    costRow("Per Pouch", data.formatted(data.perPouchCost))
                    costRow("Today", data.formatted(data.costToday))
                    costRow("Last 7 Days", data.formatted(data.cost7))
                    costRow("Last 30 Days", data.formatted(data.cost30))
                    costRow("Tins (30d)", String(format: "%.1f", data.tinsConsumed30))

                    Divider()

                    HStack {
                        Text("Projected Monthly")
                            .fontWeight(.semibold)
                        Spacer()
                        Text(data.formatted(data.projectedMonthlyCost))
                            .fontWeight(.semibold)
                            .foregroundColor(.red)
                    }
                } else {
                    Text("Enter a price per tin to estimate your spend.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding()
            .background(Color(.secondarySystemBackground))
            .cornerRadius(16)
        }
    }

    // MARK: - Share section (summary text + CSV export)

    private var shareSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Share & Export", systemImage: "square.and.arrow.up")

            VStack(spacing: 12) {
                // Share a plain-text summary.
                ShareLink(item: data.textSummary()) {
                    Label("Share Summary", systemImage: "text.quote")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)

                // Export the full-history CSV. `CSVDocument` wraps the string as a shareable
                // file with a friendly name so the share sheet offers "Save to Files", Mail, etc.
                ShareLink(
                    item: csvExportURL(),
                    preview: SharePreview("nicnark-export.csv")
                ) {
                    Label("Export CSV", systemImage: "tablecells")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
            }
            .padding()
            .background(Color(.secondarySystemBackground))
            .cornerRadius(16)
        }
    }

    /// Writes the CSV string to a temp file and returns its URL so ShareLink can share an actual
    /// `.csv` file (rather than raw text). Falls back to a temp URL that we always create.
    private func csvExportURL() -> URL {
        let csv = data.csvString()
        let tmpDir = FileManager.default.temporaryDirectory
        let url = tmpDir.appendingPathComponent("nicnark-export.csv")
        // Best-effort write; if it fails we still hand back the URL (share will simply show an
        // empty/last file). This keeps the button compile-safe and non-throwing at the call site.
        try? csv.data(using: .utf8)?.write(to: url, options: .atomic)
        return url
    }

    // MARK: - Small reusable subviews / helpers

    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundColor(.accentColor)
            Text(title)
                .font(.title3).fontWeight(.bold)
        }
    }

    private func statRow(icon: String, tint: Color, label: String, value: String) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(tint)
                .frame(width: 24)
            Text(label)
            Spacer()
            Text(value)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 10)
    }

    private func costRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
        }
        .font(.subheadline)
    }

    /// Format an absorbed-mg value to one decimal (NaN-safe).
    private func mg(_ value: Double) -> String {
        let v = value.isFinite ? value : 0
        return String(format: "%.1f", v)
    }

    private func trendLabel(_ trend: Trend) -> String {
        switch trend {
        case .up:   return "up"
        case .down: return "down"
        case .flat: return "steady"
        }
    }

    /// Short weekday label (1 = Sun ... 7 = Sat).
    private func weekdayShortName(_ weekday: Int) -> String {
        let symbols = Calendar.current.shortWeekdaySymbols   // index 0 = Sunday
        let idx = weekday - 1
        guard idx >= 0, idx < symbols.count else { return "?" }
        return symbols[idx]
    }

    /// Full weekday label (1 = Sun ... 7 = Sat).
    private func weekdayLongName(_ weekday: Int) -> String {
        let symbols = Calendar.current.weekdaySymbols        // index 0 = Sunday
        let idx = weekday - 1
        guard idx >= 0, idx < symbols.count else { return "—" }
        return symbols[idx]
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        InsightsView()
            .environment(\.managedObjectContext, PersistenceController.shared.container.viewContext)
    }
}
