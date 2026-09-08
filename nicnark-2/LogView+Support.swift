import SwiftUI
import CoreData
import WidgetKit
import ActivityKit
import Combine

extension LogView {
    func calculateBottomPadding() -> CGFloat {
        var padding: CGFloat = 16
        if !activePouches.isEmpty { padding += 70 }
        if canStartTimer { padding += 90 }
        return padding
    }

    func smartWidgetReload() {
        let now = Date()
        if now.timeIntervalSince(lastWidgetUpdate) >= 120 || checkIfPouchCompleted() {
            WidgetReloadCoordinator.reload()
            lastWidgetUpdate = now
        }
    }

    func checkIfPouchCompleted() -> Bool {
        guard let pouch = activePouches.first, let insertionTime = pouch.insertionTime else { return false }
        return Date().timeIntervalSince(insertionTime) >= TimeInterval(pouch.timerDuration * 60)
    }

    func autoRemoveCompletedPouchIfNeeded() {
        guard autoRemovePouches, let pouch = activePouches.first, let insertionTime = pouch.insertionTime else { return }
        let totalDuration = TimeInterval(pouch.timerDuration * 60) + autoRemoveDelayMinutes * 60
        if Date().timeIntervalSince(insertionTime) >= totalDuration {
            removePouch(pouch)
        }
    }

    func throttledWidgetReload(at now: Date) {
        if now.timeIntervalSince(lastWidgetUpdate) >= 30 {
            WidgetReloadCoordinator.reload()
            lastWidgetUpdate = now
        }
    }

    func formatHoursMinutesSeconds(_ timeInterval: TimeInterval) -> String {
        let seconds = Int(max(timeInterval, 0))
        return String(format: "%02d:%02d:%02d", seconds/3600, (seconds%3600)/60, seconds%60)
    }

    func formatMinutesSeconds(_ timeInterval: TimeInterval) -> String {
        let seconds = Int(max(timeInterval, 0))
        return String(format: "%02d:%02d", seconds/60, seconds%60)
    }

    func cleanUpStale() {
        guard autoRemovePouches else { return }
        let request = PouchLog.fetchRequest()
        request.predicate = NSPredicate(format: "removalTime == nil")
        if let logs = try? ctx.fetch(request) {
            for pouch in logs {
                guard let insertionTime = pouch.insertionTime else { continue }
                let totalDuration = TimeInterval(pouch.timerDuration * 60) + autoRemoveDelayMinutes * 60
                if Date().timeIntervalSince(insertionTime) > (totalDuration + 5) {
                    removePouch(pouch)
                }
            }
        }
    }

    func updateNicotineLevels() {
        Task {
            let calculator = NicotineCalculator()
            let now = Date.now
            let currentLevel = await calculator.calculateTotalNicotineLevel(context: ctx, at: now)
            let estimatedLevel: Double?
            if totalLoadedPouches > 0 {
                let planned = plannedPouchesFromLoaded()
                let plannedMaxDuration = planned.map(\.duration).max() ?? 0
                var horizon = now.addingTimeInterval(plannedMaxDuration)
                let activeEndTimes: [Date] = activePouches.compactMap { pouch in
                    guard let insertion = pouch.insertionTime else { return nil }
                    let duration = pouch.timerDuration > 0 ? TimeInterval(pouch.timerDuration) * 60 : FULL_RELEASE_TIME
                    return insertion.addingTimeInterval(duration)
                }
                if let maxActiveEnd = activeEndTimes.max(), maxActiveEnd > horizon { horizon = maxActiveEnd }
                let result = await SleepProtectionAnalyzer.predictTotalLevel(context: ctx, now: now, at: horizon, plannedPouches: planned)
                estimatedLevel = result.predictedLevel
            } else {
                estimatedLevel = nil
            }
            await MainActor.run {
                self.currentNicotineLevel = currentLevel
                self.estimatedNicotineLevel = estimatedLevel
            }
        }
    }

    func plannedPouchesFromLoaded() -> [PlannedPouch] {
        guard totalLoadedPouches > 0 else { return [] }
        var planned: [PlannedPouch] = []
        for can in activeCans {
            guard let canId = can.id, let count = loadedPouches[canId], count > 0 else { continue }
            let durationSeconds: TimeInterval = can.duration > 0 ? TimeInterval(can.duration * 60) : FULL_RELEASE_TIME
            for _ in 0..<count {
                planned.append(PlannedPouch(
                    nicotineAmount: can.strength,
                    duration: durationSeconds,
                    absorptionFraction: BrandAbsorptionProfile.fraction(forBrand: can.brand)
                ))
            }
        }
        return planned
    }

    func updateSleepProtectionEvaluation() {
        guard sleepProtectionEnabled, totalLoadedPouches > 0 else {
            sleepProtectionBedtime = nil
            sleepProtectionPredictedLevelAtBedtime = nil
            isEvaluatingSleepProtection = false
            return
        }
        isEvaluatingSleepProtection = true
        let planned = plannedPouchesFromLoaded()
        let now = Date.now
        Task {
            let result = await SleepProtectionAnalyzer.predictTotalLevelAtNextBedtime(
                context: ctx,
                now: now,
                bedtimeSecondsFromMidnight: sleepProtectionBedtimeSecondsFromMidnight,
                plannedPouches: planned
            )
            await MainActor.run {
                self.sleepProtectionBedtime = result.bedtime
                self.sleepProtectionPredictedLevelAtBedtime = result.predictedLevel
                self.isEvaluatingSleepProtection = false
            }
        }
    }

    var syncOverlay: some View {
        let syncState = CloudKitSyncState.shared
        return ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()
            VStack(spacing: 20) {
                if syncState.syncCompleted {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 60)).foregroundColor(.green)
                } else {
                    ProgressView().scaleEffect(1.5).progressViewStyle(CircularProgressViewStyle(tint: .blue))
                }
                Text(syncState.syncCompleted ? "Sync Complete" : syncState.syncMessage).font(.headline)
                if !syncState.syncCompleted {
                    ProgressView(value: syncState.syncProgress).frame(width: 200).progressViewStyle(.linear).tint(.blue)
                    Text("Please wait while we sync with your other devices")
                        .font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center).frame(maxWidth: 250)
                }
            }
            .padding(30)
            .glassEffect(.regular, in: .rect(cornerRadius: 20))
        }
    }

    var shouldDisableRemoveButton: Bool {
        CloudKitSyncState.shared.isCloudKitEnabled && !CloudKitSyncState.shared.syncCompleted
    }
}

#Preview {
    LogView()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
}
