// PouchLiveActivity.swift

import ActivityKit
import WidgetKit
import SwiftUI

@available(iOS 16.1, *)
struct PouchLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PouchActivityAttributes.self) { context in
            PouchLiveActivityView(context: context)
                .padding()
                .containerBackground(.fill.tertiary, for: .widget)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        Image(systemName: "pills.fill").foregroundColor(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(context.attributes.pouchName).font(.caption).fontWeight(.semibold)
                            Text(context.state.status).font(.caption2).foregroundColor(.secondary)
                        }
                    }
                }

                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(timerInterval: context.state.timerInterval, countsDown: true)
                            .font(.caption).fontWeight(.semibold).monospacedDigit()
                        Text("\(context.state.currentNicotineLevel, specifier: "%.1f") mg")
                            .font(.caption2).foregroundColor(.green)
                    }
                }

                DynamicIslandExpandedRegion(.center) {
                    let start = context.state.timerInterval.lowerBound
                    let end = context.state.timerInterval.upperBound
                    let total = max(1, end.timeIntervalSince(start))
                    let elapsed = min(max(0, Date().timeIntervalSince(start)), total)
                    let frac = elapsed / total
                    VStack(spacing: 4) {
                        ProgressView(value: frac, total: 1.0)
                            .progressViewStyle(LinearProgressViewStyle(tint: .blue))
                            .scaleEffect(y: 0.8)
                        Text("Absorbing").font(.caption2).foregroundColor(.secondary)
                    }
                }

                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text("Nicotine Level:").font(.caption2).foregroundColor(.secondary)
                        Spacer()
                        Text("\(context.state.currentNicotineLevel, specifier: "%.2f") mg")
                            .font(.caption2).fontWeight(.medium).foregroundColor(.green)
                    }
                }
            } compactLeading: {
                Image(systemName: "pills.fill").foregroundColor(.blue)
            } compactTrailing: {
                Text(timerInterval: context.state.timerInterval, countsDown: true)
                    .font(.caption2).fontWeight(.medium).monospacedDigit()
            } minimal: {
                Image(systemName: "pills.fill").foregroundColor(.blue)
            }
            .keylineTint(.blue)
        }
    }
}

@available(iOS 16.1, *)
struct PouchLiveActivityView: View {
    let context: ActivityViewContext<PouchActivityAttributes>

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "pills.fill").foregroundColor(.blue).font(.title2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.pouchName).font(.headline).fontWeight(.bold)
                        Text(context.state.status).font(.caption).foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 8) {
                Text(timerInterval: context.state.timerInterval, countsDown: true)
                    .font(.title2).fontWeight(.bold).monospacedDigit()
                Text("\(context.state.currentNicotineLevel, specifier: "%.1f") mg absorbed")
                    .font(.caption).foregroundColor(.green)

                let start = context.state.timerInterval.lowerBound
                let end = context.state.timerInterval.upperBound
                let total = max(1, end.timeIntervalSince(start))
                let elapsed = min(max(0, Date().timeIntervalSince(start)), total)
                let frac = elapsed / total
                ProgressView(value: frac, total: 1.0)
                    .progressViewStyle(LinearProgressViewStyle(tint: .blue))
                    .frame(width: 100)
                    .scaleEffect(y: 1.2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
