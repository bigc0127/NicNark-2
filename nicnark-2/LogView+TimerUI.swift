import SwiftUI
import CoreData
import WidgetKit
import ActivityKit
import Combine

extension LogView {

    var collapsedTimerSummary: some View {
        let longestPouch = activePouches.max(by: { pouch1, pouch2 in
            calculateRemaining(for: pouch1) < calculateRemaining(for: pouch2)
        })
        let totalNicotine = activePouches.reduce(0.0) { $0 + $1.nicotineAmount }
        let totalAbsorbed = activePouches.reduce(0.0) { total, pouch in
            let insertion = pouch.insertionTime ?? Date()
            let elapsed = tick.timeIntervalSince(insertion)
            let duration = pouch.timerDuration > 0 ? TimeInterval(pouch.timerDuration) * 60 : FULL_RELEASE_TIME
            let absorbed = AbsorptionConstants.shared.calculateCurrentNicotineLevel(
                nicotineContent: pouch.nicotineAmount,
                elapsedTime: elapsed,
                fullReleaseTime: duration,
                absorptionFraction: pouch.absorptionFraction
            )
            return total + absorbed
        }
        if let pouch = longestPouch {
            let remaining = calculateRemaining(for: pouch)
            let actualDuration = TimeInterval(pouch.timerDuration * 60)
            let elapsed = max(0, tick.timeIntervalSince(pouch.insertionTime ?? Date()))
            let progress = min(max(elapsed / actualDuration, 0), 1)
            let isCompleted = remaining == 0
            let pouchWord = activePouches.count == 1 ? "Pouch" : "Pouches"
            let summaryLine = String(format: "%.1fmg total • %.3fmg absorbed", totalNicotine, totalAbsorbed)
            return AnyView(
                HStack(spacing: 12) {
                    VStack(spacing: 8) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(activePouches.count) Active \(pouchWord)")
                                    .font(.caption).fontWeight(.semibold)
                                Text(summaryLine)
                                    .font(.caption2).foregroundColor(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(isCompleted ? "Complete!" : formatMinutesSeconds(remaining))
                                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                                    .foregroundColor(isCompleted ? .green : .blue)
                                Text("Longest Timer").font(.caption2).foregroundColor(.secondary)
                            }
                        }
                        ProgressView(value: progress).scaleEffect(y: 1.2)
                    }
                }
                .padding(12)
                .glassEffect(.regular, in: .rect(cornerRadius: 10))
            )
        } else {
            return AnyView(EmptyView())
        }
    }

    func calculateRemaining(for pouch: PouchLog) -> TimeInterval {
        let insertionTime = pouch.insertionTime ?? tick
        let elapsed = max(0, tick.timeIntervalSince(insertionTime))
        let actualDuration = TimeInterval(pouch.timerDuration * 60)
        return max(min(actualDuration - elapsed, actualDuration), 0)
    }

    var removeAllActivePouchesButton: some View {
        Button(action: removeAllActivePouches) {
            HStack {
                Image(systemName: "xmark.circle.fill")
                Text("Remove All Active Pouches").fontWeight(.semibold)
            }
            .font(.headline).frame(maxWidth: .infinity).padding()
        }
        .buttonStyle(.glass)
        .tint(.red)
    }

    var startTimerButton: some View {
        Button(action: startTimerWithLoadedPouches) {
            VStack(spacing: 8) {
                HStack {
                    Image(systemName: "play.fill")
                    Text("Start Timer").fontWeight(.semibold)
                }.font(.title2)
                Text(startTimerPouchLine).font(.caption)
                Text(startTimerAbsorptionLine).font(.caption2)
                if let estimatedLevel = estimatedNicotineLevel {
                    HStack {
                        Text("Est. Level").font(.caption2)
                        Spacer()
                        Text(String(format: "%.3f mg", estimatedLevel)).font(.caption2).fontWeight(.medium)
                    }
                }
                if sleepProtectionEnabled && totalLoadedPouches > 0 {
                    sleepProtectionStatusView
                }
            }
            .frame(maxWidth: .infinity).padding()
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.roundedRectangle(radius: 20))
        .tint(.blue)
        .disabled(!canStartTimer)
    }

    private var startTimerPouchLine: String {
        let word = totalLoadedPouches == 1 ? "pouch" : "pouches"
        return String(format: "%d %@ • %.1fmg", totalLoadedPouches, word, totalNicotine)
    }

    private var startTimerAbsorptionLine: String {
        String(format: "Estimated absorption: %.2f mg", estimatedTotalAbsorption)
    }

    var sleepProtectionStatusView: some View {
        let bedtimeText: String = {
            if let bedtime = sleepProtectionBedtime { return bedtime.formatted(date: .omitted, time: .shortened) }
            return "Bedtime"
        }()
        if isEvaluatingSleepProtection {
            return AnyView(
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.7).tint(.white.opacity(0.9))
                    Text("Checking bedtime…").font(.caption2).foregroundColor(.white.opacity(0.85))
                    Spacer()
                    Text(bedtimeText).font(.caption2).foregroundColor(.white.opacity(0.7))
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(Color.white.opacity(0.12)).cornerRadius(10)
            )
        }
        guard let predicted = sleepProtectionPredictedLevelAtBedtime, let bedtime = sleepProtectionBedtime else {
            return AnyView(EmptyView())
        }
        let isSafe = predicted <= sleepProtectionTargetMg
        let comparison = String(format: "%.3f %@ %.1f mg", predicted, isSafe ? "≤" : ">", sleepProtectionTargetMg)
        return AnyView(
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: isSafe ? "moon.stars.fill" : "moon.zzz.fill").font(.caption)
                    Text("Sleep Protection").font(.caption).fontWeight(.semibold)
                    Spacer()
                    Text(bedtime.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundColor(.white.opacity(0.75))
                }
                HStack {
                    Text(isSafe ? "OK for bedtime" : "May interfere").font(.caption2).foregroundColor(.white.opacity(0.9))
                    Spacer()
                    Text(comparison)
                        .font(.caption2).fontWeight(.medium).foregroundColor(.white.opacity(0.9))
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(isSafe ? Color.green : Color.red)
            .cornerRadius(10)
        )
    }

    var customRowView: some View {
        HStack {
            TextField("Enter mg", text: $input).keyboardType(.decimalPad).textFieldStyle(.roundedBorder).frame(width: 90)
            Button("Save") {
                guard let mg = Double(input), mg > 0 else { return }
                LogService.ensureCustomButton(for: mg, in: ctx)
                try? ctx.save()
                input = ""
                showInput = false
                WidgetReloadCoordinator.reload()
            }.buttonStyle(.borderedProminent)
            Button("Cancel") { input = ""; showInput = false }.buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    func compactCountdownPane(for pouch: PouchLog) -> some View {
        let insertionTime = pouch.insertionTime ?? tick
        let elapsed = max(0, tick.timeIntervalSince(insertionTime))
        let actualDuration = TimeInterval(pouch.timerDuration * 60)
        let remaining = max(min(actualDuration - elapsed, actualDuration), 0)
        let progress = min(max(elapsed / actualDuration, 0), 1)
        let isCompleted = remaining == 0
        let currentAbsorption = AbsorptionConstants.shared.calculateCurrentNicotineLevel(
            nicotineContent: pouch.nicotineAmount, elapsedTime: elapsed, fullReleaseTime: actualDuration, absorptionFraction: pouch.absorptionFraction)
        let maxPossibleAbsorption = AbsorptionConstants.shared.calculateAbsorbedNicotine(
            nicotineContent: pouch.nicotineAmount, useTime: actualDuration, fullReleaseTime: actualDuration, absorptionFraction: pouch.absorptionFraction)
        let absorptionProgress = maxPossibleAbsorption > 0 ? currentAbsorption / maxPossibleAbsorption : 0
        let strengthLine = String(format: "%.1fmg", pouch.nicotineAmount)
        let maxLine = String(format: "Max %d%% · %.2fmg", Int((pouch.absorptionFraction * 100).rounded()), pouch.nicotineAmount * pouch.absorptionFraction)
        let absorbedLine = String(format: "%.3fmg (%d%%)", currentAbsorption, Int(absorptionProgress * 100))
        HStack(spacing: 12) {
            VStack(spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        if let brand = pouch.can?.brand {
                            Text(brand).font(.caption).fontWeight(.semibold)
                        }
                        Text(strengthLine).font(.caption2).foregroundColor(.secondary)
                        Text(maxLine).font(.caption2).fontWeight(.semibold).foregroundColor(.blue)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(isCompleted ? "Complete!" : formatMinutesSeconds(remaining))
                            .font(.system(size: 16, weight: .bold, design: .monospaced))
                            .foregroundColor(isCompleted ? .green : .blue)
                        Text(absorbedLine).font(.caption2).foregroundColor(.secondary)
                    }
                }
                ProgressView(value: progress).scaleEffect(y: 1.2)
            }
            Button(action: { removePouch(pouch) }) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 24)).foregroundColor(.red)
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(shouldDisableRemoveButton)
            .opacity(shouldDisableRemoveButton ? 0.5 : 1.0)
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 10))
    }
}
