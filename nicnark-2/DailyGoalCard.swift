//
//  DailyGoalCard.swift
//  nicnark-2
//
//  A compact, self-contained card for the TOP of the Log screen that shows how many
//  pouches the user has logged TODAY against their configured daily goal.
//
//  BEHAVIOR
//  --------
//  • The daily goal lives in UserDefaults via `InsightsSettings.dailyPouchGoal`.
//    A value of `0` means "unset" — the user hasn't configured a goal yet in the
//    Insights screen. In that case this view renders an `EmptyView()` so the Log
//    screen stays visually unchanged until a goal exists.
//  • When a goal IS set we show a small card with a Gauge (today's count vs. goal),
//    a "N / goal pouches today" label, and a tint that shifts green → orange → red
//    as the user approaches and then exceeds the goal.
//
//  DATA
//  ----
//  This view owns its own lightweight `@FetchRequest` for TODAY's `PouchLog` rows
//  (insertionTime >= start of today). It only reads `insertionTime` via the fetch
//  predicate and counts the rows — it never mutates Core Data. SwiftUI keeps the
//  count live as pouches are logged/removed.
//
//  CONCURRENCY
//  -----------
//  Under Swift 6 with SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor, SwiftUI View
//  structs are implicitly @MainActor, so all of this runs on the main actor. We
//  never pass managed objects across an isolation boundary — we reduce the fetched
//  results down to a plain `Int` count immediately.
//
//  INTEGRATION
//  -----------
//  The main agent inserts `DailyGoalCard()` at the top of LogView's VStack. It needs
//  a managed object context in the environment (LogView already provides one). The
//  public no-argument initializer `DailyGoalCard()` is provided for that call site.
//

import SwiftUI
import CoreData

/// A compact "today vs. daily goal" card. Renders nothing until the user sets a
/// daily pouch goal in Insights (`InsightsSettings.dailyPouchGoal > 0`).
struct DailyGoalCard: View {

    // MARK: FetchRequest — today's pouches only
    //
    // We fetch every PouchLog whose insertionTime is on or after the start of the
    // current day. We only need the COUNT, so we sort by insertionTime (any stable
    // order is fine) and reduce to `.count` in the body. Fetching is scoped tightly
    // by the predicate so the working set stays tiny.
    @FetchRequest private var todaysPouches: FetchedResults<PouchLog>

    // MARK: Init
    //
    // Public no-argument initializer for the LogView call site: `DailyGoalCard()`.
    // We build the "start of today" boundary here (at init/refresh time, NOT in a
    // static stored initializer, so no build-time timestamp is baked in).
    init() {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())

        _todaysPouches = FetchRequest<PouchLog>(
            entity: PouchLog.entity(),
            sortDescriptors: [
                NSSortDescriptor(keyPath: \PouchLog.insertionTime, ascending: true)
            ],
            predicate: NSPredicate(format: "insertionTime >= %@", startOfToday as NSDate)
        )
    }

    // MARK: Derived values

    /// Today's logged pouch count (plain Int — no managed objects escape here).
    private var todayCount: Int { todaysPouches.count }

    /// The user's configured daily goal. `0` == unset.
    private var goal: Int { InsightsSettings.dailyPouchGoal }

    /// Progress fraction in the closed range 0...1 for the Gauge/ProgressView.
    /// Guards against divide-by-zero and clamps so an over-goal day still renders
    /// a full (not overflowing) gauge.
    private var progress: Double {
        guard goal > 0 else { return 0 }
        let raw = Double(todayCount) / Double(goal)
        guard raw.isFinite else { return 0 }
        return min(max(raw, 0), 1)
    }

    /// Tint by how close to (or over) the goal the user is:
    ///   • red    — at or over the goal (>= 100%)
    ///   • orange — getting close (>= 80%)
    ///   • green  — comfortably under
    private var tint: Color {
        guard goal > 0 else { return .green }
        if todayCount >= goal { return .red }
        if Double(todayCount) >= Double(goal) * 0.8 { return .orange }
        return .green
    }

    /// "3 / 10 pouches today"
    private var label: String {
        "\(todayCount) / \(goal) pouches today"
    }

    /// Short status word shown under the label for a little extra context.
    private var statusText: String {
        guard goal > 0 else { return "" }
        if todayCount > goal {
            let over = todayCount - goal
            return "\(over) over your goal"
        } else if todayCount == goal {
            return "At your goal"
        } else {
            let left = goal - todayCount
            return "\(left) to go"
        }
    }

    // MARK: Body

    var body: some View {
        // Hidden entirely until a goal is configured in Insights.
        if goal <= 0 {
            EmptyView()
        } else {
            card
        }
    }

    /// The visible card. Uses the app's standard card treatment:
    /// Color(.secondarySystemBackground) fill with 16pt rounded corners.
    private var card: some View {
        HStack(spacing: 14) {
            // Circular gauge of today's progress toward the goal.
            //
            // Gauge is available from iOS 16 (well under our 18.4 floor). We use the
            // accessoryCircularCapacity style for a compact, ring-like indicator that
            // fits nicely in a small header card.
            Gauge(value: progress) {
                // Empty inner label — the numeric detail lives to the right.
                EmptyView()
            } currentValueLabel: {
                Text("\(todayCount)")
                    .font(.callout)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(tint)
            .frame(width: 54, height: 54)

            // Text block: primary label + status line.
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "target")
                        .font(.subheadline)
                        .foregroundColor(tint)
                    Text("Daily Goal")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Text(label)
                    .font(.headline)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                if !statusText.isEmpty {
                    Text(statusText)
                        .font(.caption2)
                        .foregroundColor(tint)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(16)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Daily goal: \(todayCount) of \(goal) pouches today. \(statusText)")
    }
}

// MARK: - Preview
//
// The preview relies on the environment's managed object context. When a goal is
// unset the card is intentionally invisible (EmptyView), so this preview mostly
// exercises the layout/compilation path.
#Preview {
    ScrollView {
        VStack(spacing: 16) {
            DailyGoalCard()
                .environment(\.managedObjectContext,
                              PersistenceController.shared.container.viewContext)
        }
        .padding()
    }
}
