//
//  NicWatchComplication.swift
//  Nicnark-2 Watch Widget
//
//  Watch-face complication showing the current nicotine level ("nic in body") and the
//  countdown on the active pouch. Reads a snapshot the watch app writes to the shared App
//  Group; the level decays across timeline entries so the face stays current between syncs.
//

import WidgetKit
import SwiftUI

// MARK: - Timeline Entry

struct NicComplicationEntry: TimelineEntry {
    let date: Date
    let level: Double
    let activePouchCount: Int
    let soonestRemoval: Date?

    static let placeholder = NicComplicationEntry(
        date: Date(),
        level: 1.2,
        activePouchCount: 1,
        soonestRemoval: Date().addingTimeInterval(20 * 60)
    )
}

// MARK: - Timeline Provider

struct NicComplicationProvider: TimelineProvider {
    func placeholder(in context: Context) -> NicComplicationEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (NicComplicationEntry) -> Void) {
        completion(entry(at: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NicComplicationEntry>) -> Void) {
        let snapshot = WatchComplicationSnapshot.load()
        let now = Date()

        var entries: [NicComplicationEntry] = []
        // First entry: right now, at the current level.
        entries.append(NicComplicationEntry(
            date: now,
            level: max(0, snapshot?.currentLevel ?? 0),
            activePouchCount: snapshot?.activePouchCount ?? 0,
            soonestRemoval: snapshot?.soonestRemoval
        ))

        // Future entries from the sampled decay curve, so the displayed level keeps falling
        // on the watch face without the app being relaunched for every tick.
        if let snapshot {
            let futurePoints = snapshot.points
                .filter { $0.t > now }
                .sorted { $0.t < $1.t }
            for p in futurePoints {
                entries.append(NicComplicationEntry(
                    date: p.t,
                    level: max(0, p.level),
                    activePouchCount: snapshot.activePouchCount,
                    soonestRemoval: snapshot.soonestRemoval
                ))
            }
        }

        // Ask WidgetKit to come back for fresh data shortly after the last sample (or in 30
        // min if we only have a single point), so the app gets a chance to push an update.
        let refreshDate = entries.last.map { $0.date.addingTimeInterval(10 * 60) }
            ?? now.addingTimeInterval(30 * 60)
        completion(Timeline(entries: entries, policy: .after(refreshDate)))
    }

    private func entry(at date: Date) -> NicComplicationEntry {
        let snapshot = WatchComplicationSnapshot.load()
        return NicComplicationEntry(
            date: date,
            level: max(0, snapshot?.currentLevel ?? 0),
            activePouchCount: snapshot?.activePouchCount ?? 0,
            soonestRemoval: snapshot?.soonestRemoval
        )
    }
}

// MARK: - Formatting helpers

private func levelString(_ level: Double) -> String {
    guard level.isFinite else { return "0" }
    return String(format: "%.2f", max(0, level))
}

/// Compact one-decimal level for the tiny flat corner slot (e.g. "7.0").
private func cornerLevelString(_ level: Double) -> String {
    guard level.isFinite else { return "0" }
    return String(format: "%.1f", max(0, level))
}

/// Gauge fills against a fixed, readable scale; the numeric label always shows the true value.
private let gaugeMax: Double = 6.0

// MARK: - Entry View

struct NicComplicationEntryView: View {
    var entry: NicComplicationProvider.Entry
    @Environment(\.widgetFamily) private var family

    private var hasActivePouch: Bool {
        entry.activePouchCount > 0 && (entry.soonestRemoval.map { $0 > entry.date } ?? false)
    }

    var body: some View {
        switch family {
        case .accessoryInline:
            inlineView
        case .accessoryCircular:
            circularView
        case .accessoryCorner:
            cornerView
        case .accessoryRectangular:
            rectangularView
        default:
            circularView
        }
    }

    // Single line at the top of the face: pill icon + current level.
    private var inlineView: some View {
        Label {
            Text("\(levelString(entry.level)) mg")
        } icon: {
            Image(systemName: "pills.fill")
        }
    }

    // Round slot: a gauge of the current level with the number in the middle.
    private var circularView: some View {
        Gauge(value: min(max(0, entry.level), gaugeMax), in: 0...gaugeMax) {
            EmptyView()
        } currentValueLabel: {
            Text(levelString(entry.level))
                .minimumScaleFactor(0.5)
        }
        .gaugeStyle(.accessoryCircular)
    }

    // Corner of round faces. watchOS gives an accessoryCorner exactly two slots: the curved
    // bezel text (`widgetLabel`) and the flat corner glyph. Only ONE thing can curve. When a
    // pouch is active we put the live COUNTDOWN on the curved bezel (like the AQI/temperature
    // complications) and the current level in the flat corner; with no active pouch there's no
    // timer, so the bezel falls back to "<n> mg in body" and the corner shows a pill glyph.
    private var cornerView: some View {
        Group {
            if hasActivePouch {
                Text(cornerLevelString(entry.level))
                    .font(.system(.title3, design: .rounded))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
            } else {
                Image(systemName: "pills.fill")
                    .font(.title3)
            }
        }
        .widgetLabel {
            if hasActivePouch, let removal = entry.soonestRemoval {
                // pauseTime: removal freezes the countdown at 00:00 when the pouch timer
                // ends, instead of the default behaviour of ticking past zero and counting up.
                Text(timerInterval: entry.date...removal, pauseTime: removal, countsDown: true)
            } else {
                Text("\(levelString(entry.level)) mg in body")
            }
        }
    }

    // Large slot: both the level and the live pouch countdown.
    private var rectangularView: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: "pills.fill")
                Text("Nicotine")
                    .font(.headline)
            }
            Text("\(levelString(entry.level)) mg in body")
                .font(.body)
            if hasActivePouch, let removal = entry.soonestRemoval {
                HStack(spacing: 4) {
                    Image(systemName: "timer")
                    // Self-updating countdown; pauseTime freezes it at 00:00 at the end
                    // rather than counting up past zero.
                    Text(timerInterval: entry.date...removal, pauseTime: removal, countsDown: true)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Text("No active pouch")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
