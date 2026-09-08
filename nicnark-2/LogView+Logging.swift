import SwiftUI
import CoreData
import WidgetKit
import ActivityKit
import Combine

extension LogView {
    func incrementPouch(for canId: UUID) {
        loadedPouches[canId] = (loadedPouches[canId] ?? 0) + 1
    }

    func decrementPouch(for canId: UUID) {
        guard let current = loadedPouches[canId], current > 0 else { return }
        if current == 1 { loadedPouches.removeValue(forKey: canId) }
        else { loadedPouches[canId] = current - 1 }
    }

    func startTimerWithLoadedPouches() {
        guard canStartTimer else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        var loads: [(can: Can, count: Int)] = []
        for can in activeCans {
            guard let canId = can.id, let count = loadedPouches[canId], count > 0 else { continue }
            loads.append((can, count))
        }
        let successCount = LogService.logPouchesFromCans(loads: loads, ctx: ctx)
        if successCount > 0 {
            loadedPouches.removeAll()
            tick = Date()
            startLiveTimerIfNeeded()
            startOptimizedTimer()
            canManager.fetchActiveCans(context: ctx)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } else {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    func handleScannedBarcode(_ barcode: String) {
        if let activeCan = canManager.findActiveCanByBarcode(barcode, context: ctx) {
            duplicateCanForAlert = activeCan
            showingDuplicateCanAlert = true
        } else {
            scannedBarcode = barcode
            showingAddCan = true
        }
    }

    func logPouch(_ mg: Double) {
        LogService.logPouch(amount: mg, ctx: ctx)
        startLiveTimerIfNeeded()
    }

    func logPouchFromCan(_ can: Can) {
        guard can.pouchCount > 0 else { return }
        let roundedStrength = round(can.strength)
        let success = canManager.logPouchFromCan(can: can, amount: roundedStrength, context: ctx)
        if success {
            startLiveTimerIfNeeded()
            canManager.fetchActiveCans(context: ctx)
        }
    }

    func removeAllActivePouches() {
        let generator = UINotificationFeedbackGenerator()
        Task { @MainActor in
            let removed = await PouchRemovalService.removeAllActivePouches(in: ctx)
            if removed > 0 { generator.notificationOccurred(.success) }
            canManager.fetchActiveCans(context: ctx)
            if !self.activePouches.isEmpty {
                self.tick = Date()
                self.startLiveTimerIfNeeded()
                self.startOptimizedTimer()
            } else {
                self.stopOptimizedTimer()
                self.liveTimer?.invalidate()
                self.liveTimer = nil
            }
        }
    }

    func removePouch(_ pouch: PouchLog) {
        Task { @MainActor in
            await PouchRemovalService.removePouch(pouch, in: ctx)
            canManager.fetchActiveCans(context: ctx)
            if !self.activePouches.isEmpty {
                self.tick = Date()
                self.startLiveTimerIfNeeded()
                self.startOptimizedTimer()
            } else {
                self.stopOptimizedTimer()
                self.liveTimer?.invalidate()
                self.liveTimer = nil
            }
        }
    }

    func deleteCustomButton(_ button: CustomButton) {
        ctx.delete(button)
        do { try ctx.save() } catch { print("Failed to delete custom button: \(error)") }
    }

    func startLiveTimerIfNeeded() {
        liveTimer?.invalidate()
        liveTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in await self.updateLiveActivityTick() }
        }
        if let t = liveTimer { RunLoop.main.add(t, forMode: .common) }
    }

    func endLiveActivityIfNeeded(for pouch: PouchLog) {
        liveTimer?.invalidate()
        liveTimer = nil
        let pouchId = pouch.pouchId?.uuidString ?? pouch.objectID.uriRepresentation().absoluteString
        Task {
            await LiveActivityManager.endLiveActivity(for: pouchId)
            WidgetReloadCoordinator.reload()
        }
    }

    func updateLiveActivityTick() async {
        guard let pouch = activePouches.max(by: { a, b in
            let ea = (a.insertionTime ?? .distantPast).addingTimeInterval(TimeInterval(a.timerDuration * 60))
            let eb = (b.insertionTime ?? .distantPast).addingTimeInterval(TimeInterval(b.timerDuration * 60))
            return ea < eb
        }), let insertionTime = pouch.insertionTime else { return }
        let actualDuration = TimeInterval(pouch.timerDuration * 60)
        let elapsed = Date().timeIntervalSince(insertionTime)
        let remaining = max(actualDuration - elapsed, 0)
        let progress = min(max(elapsed / actualDuration, 0), 1)
        let currentLevel = await NicotineCalculator().calculateTotalNicotineLevel(context: ctx)
        let pouchId = pouch.pouchId?.uuidString ?? pouch.objectID.uriRepresentation().absoluteString
        let endTime = insertionTime.addingTimeInterval(actualDuration)
        await LiveActivityManager.updateLiveActivity(
            for: pouchId,
            timerInterval: insertionTime...endTime,
            absorptionProgress: progress,
            currentNicotineLevel: currentLevel
        )
        if remaining == 0 {
            endLiveActivityIfNeeded(for: pouch)
            if autoRemovePouches {
                Task { @MainActor in
                    let delayNanoseconds = UInt64(autoRemoveDelayMinutes * 60 * Double(NSEC_PER_SEC))
                    try? await Task.sleep(nanoseconds: max(delayNanoseconds, NSEC_PER_SEC))
                    removePouch(pouch)
                }
            }
        } else {
            WidgetReloadCoordinator.reload()
        }
    }

    func updateLiveActivityTickIfNeeded() async {
        let now = Date()
        if now.timeIntervalSince(lastLiveActivityUpdate) >= 15 || checkIfPouchCompleted() {
            await updateLiveActivityTick()
            lastLiveActivityUpdate = now
        }
    }

    func startOptimizedTimer() {
        stopOptimizedTimer()
        optimizedTimer = Timer.scheduledTimer(withTimeInterval: TIMER_INTERVAL, repeats: true) { _ in
            Task { @MainActor in
                self.tick = Date()
                await self.updateLiveActivityTickIfNeeded()
                self.smartWidgetReload()
                self.autoRemoveCompletedPouchIfNeeded()
            }
        }
        if let timer = optimizedTimer { RunLoop.main.add(timer, forMode: .common) }
    }

    func stopOptimizedTimer() {
        optimizedTimer?.invalidate()
        optimizedTimer = nil
    }
}
