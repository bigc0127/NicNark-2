// AbsorptionTimerWidgetLiveActivity.swift

import ActivityKit
import WidgetKit
import SwiftUI

@available(iOS 16.1, *)
struct AbsorptionTimerWidgetLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PouchActivityAttributes.self) { context in
            // Lock screen / StandBy
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "pills.fill").foregroundColor(.blue).font(.title2)
                    Text("Nicotine Absorption").font(.headline)
                    Spacer()
                    Text(context.attributes.pouchName)
                        .font(.headline)
                        .fontWeight(.semibold)
                        .foregroundColor(.blue)
                }

                HStack {
                    Spacer()
                    VStack(spacing: 4) {
                        Text(timerInterval: context.state.timerInterval, countsDown: true)
                            .font(.system(size: 28, weight: .bold, design: .monospaced))
                            .foregroundColor(.blue)
                            .multilineTextAlignment(.center)
                        let remaining = max(0, context.state.timerInterval.upperBound.timeIntervalSinceNow)
                        Text(remaining > 0 ? "remaining" : "absorption complete")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }

                // Calculate progress based on total nicotine absorption across all pouches
                let maxAbsorption = context.attributes.totalNicotine * 0.30 // 30% absorption rate
                let frac = min(1.0, context.state.currentNicotineLevel / maxAbsorption)
                ProgressView(value: frac, total: 1.0)
                    .progressViewStyle(LinearProgressViewStyle(tint: .blue))
                    .scaleEffect(y: 2)

                HStack {
                    Text("Nicotine absorbed:").foregroundColor(.secondary)
                    Spacer()
                    Text("\(context.state.currentNicotineLevel, specifier: "%.3f") mg")
                        .fontWeight(.semibold)
                        .foregroundColor(.blue)
                }
            }
            .padding(16)
            .containerBackground(.fill.tertiary, for: .widget)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack {
                        Image(systemName: "pills.fill").foregroundColor(.blue)
                        Text(context.attributes.pouchName).font(.caption).bold()
                    }
                }

                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(timerInterval: context.state.timerInterval, countsDown: true)
                            .font(.system(size: 16, weight: .bold, design: .monospaced))
                            .foregroundColor(.blue)
                        Text("\(context.state.currentNicotineLevel, specifier: "%.3f") mg")
                            .font(.caption2).foregroundColor(.green)
                    }
                }

                DynamicIslandExpandedRegion(.bottom) {
                    // Calculate progress based on total nicotine absorption across all pouches
                    let maxAbsorption = context.attributes.totalNicotine * 0.30 // 30% absorption rate
                    let frac = min(1.0, context.state.currentNicotineLevel / maxAbsorption)
                    VStack(spacing: 6) {
                        ProgressView(value: frac, total: 1.0)
                            .progressViewStyle(LinearProgressViewStyle(tint: .blue))
                        HStack {
                            Text("Absorbed:").font(.caption2).foregroundColor(.secondary)
                            Spacer()
                            Text("\(context.state.currentNicotineLevel, specifier: "%.3f") mg")
                                .font(.caption2).fontWeight(.semibold).foregroundColor(.blue)
                        }
                    }
                }
            } compactLeading: {
                HStack(spacing: 4) {
                    Image(systemName: "pills.fill").foregroundColor(.blue)
                    Text("\(Int(context.attributes.totalNicotine))")
                        .font(.caption2)
                        .fontWeight(.semibold)
                }
            } compactTrailing: {
                Text(timerInterval: context.state.timerInterval, countsDown: true)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(.blue)
            } minimal: {
                let remaining = max(0, context.state.timerInterval.upperBound.timeIntervalSinceNow)
                Image(systemName: remaining > 0 ? "pills.fill" : "checkmark.circle.fill")
                    .foregroundColor(remaining > 0 ? .blue : .green)
            }
            .keylineTint(.blue)
        }
    }
}
