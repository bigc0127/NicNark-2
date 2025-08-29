// LiveActivityManager.swift

@preconcurrency import BackgroundTasks
import ActivityKit
import Foundation
import SwiftUI
import os.log
import UIKit

@available(iOS 16.1, *)
@MainActor
class LiveActivityManager: ObservableObject {
    @Published var hasActiveNotification: Bool = false
    private let logger = Logger(subsystem: "com.nicnark.nicnark-2", category: "LiveActivity")
    
    // Minimal snapshot type for background computations
    struct TrackedActivity: Hashable {
        let id: String
        let pouchId: String
        let startTime: Date
        let endTime: Date
        let totalNicotine: Double
    }
    
    init() {
        Task { await checkForActiveActivities() }
        // When leaving foreground, ensure background maintenance is scheduled
        NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleBackgroundMaintainers()
            }
        }
        
        // When returning to foreground, refresh activity count
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { await self?.checkForActiveActivities() }
        }
    }
    
    private func checkForActiveActivities() async {
        let count = Activity<PouchActivityAttributes>.activities.count
        hasActiveNotification = count > 0
        logger.info("Active activities: \(count)")
    }
    
    // MARK: - Start
    
    static func startLiveActivity(for pouchId: String, nicotineAmount: Double) async -> Bool {
        let log = Logger(subsystem: "com.nicnark.nicnark-2", category: "LiveActivity")
        let auth = ActivityAuthorizationInfo()
        guard auth.areActivitiesEnabled else {
            log.error("Live Activities disabled")
            return false
        }
        
        // Ensure only one activity at a time
        await endAllLiveActivities()
        let start = Date()
        let end = start.addingTimeInterval(FULL_RELEASE_TIME)
        let attributes = PouchActivityAttributes(
            pouchName: "\(Int(nicotineAmount))mg Pouch",
            totalNicotine: nicotineAmount,
            startTime: start,
            expectedDuration: FULL_RELEASE_TIME,
            pouchId: pouchId
        )
        
        let initialState = PouchActivityAttributes.ContentState(
            timerInterval: start...end,
            currentNicotineLevel: 0.0,
            status: "Starting absorption...",
            absorptionRate: 0.0,
            lastUpdated: Date()
        )
        
        let content = ActivityContent(
            state: initialState,
            staleDate: Calendar.current.date(byAdding: .minute, value: 35, to: start)
        )
        
        do {
            _ = try Activity.request(attributes: attributes, content: content)
            log.info("Live Activity started for pouch: \(pouchId, privacy: .public)")
            // Foreground ticker for smooth UI while app is active
            Task { await startForegroundMinuteTicker(pouchId: pouchId, nicotineAmount: nicotineAmount) }
            // Schedule an early background refresh in case the app soon goes inactive
            Task { await BackgroundMaintainer.shared.scheduleSoon() }
            return true
        } catch {
            log.error("Start Live Activity failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
    
    // MARK: - Foreground ticker
    
    private static func startForegroundMinuteTicker(pouchId: String, nicotineAmount: Double) async {
        let log = Logger(subsystem: "com.nicnark.nicnark-2", category: "LiveActivity")
        
        while true {
            guard let activity = Activity<PouchActivityAttributes>.activities.first(where: { $0.attributes.pouchId == pouchId }) else {
                log.info("Ticker stopped: no activity")
                break
            }
            
            // Stop foreground ticker when app goes to background
            if UIApplication.shared.applicationState != .active {
                log.info("App backgrounded - stopping foreground ticker, relying on background tasks")
                break
            }
            
            let elapsed = Date().timeIntervalSince(activity.attributes.startTime)
            let remaining = max(0, FULL_RELEASE_TIME - elapsed)
            if remaining <= 0 {
                await endLiveActivity(for: pouchId)
                break
            }
            
            let currentLevel = AbsorptionConstants.shared
                .calculateCurrentNicotineLevel(nicotineContent: nicotineAmount, elapsedTime: elapsed)
            let progress = min(max(elapsed / FULL_RELEASE_TIME, 0), 1)
            let timer = activity.attributes.startTime...activity.attributes.endTime
            
            await updateLiveActivity(
                for: pouchId,
                timerInterval: timer,
                absorptionProgress: progress,
                currentNicotineLevel: currentLevel
            )
            
            // Update every 30 seconds in foreground for more current nicotine levels
            try? await Task.sleep(nanoseconds: 30 * NSEC_PER_SEC)
        }
    }
    
    // MARK: - Update
    
    static func updateLiveActivity(
        for pouchId: String,
        timerInterval: ClosedRange<Date>,
        absorptionProgress: Double,
        currentNicotineLevel: Double
    ) async {
        let log = Logger(subsystem: "com.nicnark.nicnark-2", category: "LiveActivity")
        guard let activity = Activity<PouchActivityAttributes>.activities.first(where: { $0.attributes.pouchId == pouchId }) else {
            log.warning("No activity for pouch: \(pouchId, privacy: .public)")
            return
        }
        
        let now = Date()
        let status = timerInterval.upperBound.timeIntervalSince(now) > 0 ? "Absorbing..." : "Complete"
        
        let newState = PouchActivityAttributes.ContentState(
            timerInterval: timerInterval,
            currentNicotineLevel: currentNicotineLevel,
            status: status,
            absorptionRate: min(max(absorptionProgress, 0), 1),
            lastUpdated: now
        )
        
        let content = ActivityContent(
            state: newState,
            staleDate: Calendar.current.date(byAdding: .minute, value: 2, to: now)
        )
        
        await activity.update(content)
        log.debug("Local update applied for pouch: \(pouchId, privacy: .public)")
    }
    
    static func updateLiveActivity(
        for pouchId: String,
        timeRemaining: TimeInterval,
        absorptionProgress: Double,
        currentNicotineLevel: Double
    ) async {
        guard let activity = Activity<PouchActivityAttributes>.activities.first(where: { $0.attributes.pouchId == pouchId }) else { return }
        let timer = activity.attributes.startTime...activity.attributes.endTime
        await updateLiveActivity(
            for: pouchId,
            timerInterval: timer,
            absorptionProgress: absorptionProgress,
            currentNicotineLevel: currentNicotineLevel
        )
    }
    
    // MARK: - End
    
    static func endLiveActivity(for pouchId: String) async {
        let log = Logger(subsystem: "com.nicnark.nicnark-2", category: "LiveActivity")
        guard let activity = Activity<PouchActivityAttributes>.activities.first(where: { $0.attributes.pouchId == pouchId }) else {
            log.warning("No activity to end for pouch: \(pouchId, privacy: .public)")
            return
        }
        
        let finalLevel = AbsorptionConstants.shared
            .calculateAbsorbedNicotine(
                nicotineContent: activity.attributes.totalNicotine,
                useTime: FULL_RELEASE_TIME
            )
        
        let timer = activity.attributes.startTime...activity.attributes.endTime
        let finalState = PouchActivityAttributes.ContentState(
            timerInterval: timer,
            currentNicotineLevel: finalLevel,
            status: "Complete",
            absorptionRate: 1.0,
            lastUpdated: Date()
        )
        
        let finalContent = ActivityContent(state: finalState, staleDate: Date())
        let dismissAt = Calendar.current.date(byAdding: .minute, value: 2, to: Date()) ?? Date()
        await activity.end(finalContent, dismissalPolicy: .after(dismissAt))
        log.info("Live Activity ended")
    }
    
    static func endAllLiveActivities() async {
        for activity in Activity<PouchActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
    
    // MARK: - Background maintenance
    
    private func scheduleBackgroundMaintainers() {
        Task { await BackgroundMaintainer.shared.scheduleRegular() }
    }
}

// MARK: - BackgroundMaintainer: BGTaskScheduler-based local updates

@available(iOS 16.1, *)
actor BackgroundMaintainer {
    static let shared = BackgroundMaintainer()
    private let refreshId = "com.nicnark.nicnark-2.bg.refresh"
    private let processId = "com.nicnark.nicnark-2.bg.process"
    private var registered = false
    private let log = Logger(subsystem: "com.nicnark.nicnark-2", category: "BGTasks")
    
    func registerIfNeeded() async {
        guard !registered else { return }
        registered = true
        
        await MainActor.run {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshId, using: nil) { task in
                Task { @Sendable in
                    await BackgroundMaintainer.shared.handleRefresh(task as! BGAppRefreshTask)
                }
            }
            
            BGTaskScheduler.shared.register(forTaskWithIdentifier: processId, using: nil) { task in
                Task { @Sendable in
                    await BackgroundMaintainer.shared.handleProcess(task as! BGProcessingTask)
                }
            }
        }
        
        log.info("BGTasks registered")
    }
    
    func scheduleRegular() async {
        await registerIfNeeded()
        
        await MainActor.run {
            // More frequent refresh for Live Activity updates - every 5 minutes
            let refresh = BGAppRefreshTaskRequest(identifier: refreshId)
            refresh.earliestBeginDate = Date(timeIntervalSinceNow: 5 * 60) // 5 minutes
            do {
                try BGTaskScheduler.shared.submit(refresh)
                log.info("Scheduled regular refresh in 5 minutes")
            } catch {
                log.error("Submit refresh failed: \(error.localizedDescription, privacy: .public)")
            }
            
            // Processing task for more intensive updates - every 10 minutes
            let process = BGProcessingTaskRequest(identifier: processId)
            process.requiresNetworkConnectivity = false
            process.requiresExternalPower = false
            process.earliestBeginDate = Date(timeIntervalSinceNow: 10 * 60) // 10 minutes
            do {
                try BGTaskScheduler.shared.submit(process)
                log.info("Scheduled processing task in 10 minutes")
            } catch {
                log.error("Submit processing failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
    
    func scheduleSoon() async {
        await registerIfNeeded()
        
        await MainActor.run {
            let refresh = BGAppRefreshTaskRequest(identifier: refreshId)
            refresh.earliestBeginDate = Date(timeIntervalSinceNow: 60) // 1 minute after start - more aggressive
            do {
                try BGTaskScheduler.shared.submit(refresh)
                log.info("Scheduled immediate refresh in 1 minute")
            } catch {
                log.error("Submit 'soon' refresh failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
    
    // New function for very frequent updates when Live Activities are active
    func scheduleFrequent() async {
        await registerIfNeeded()
        
        await MainActor.run {
            let refresh = BGAppRefreshTaskRequest(identifier: refreshId)
            refresh.earliestBeginDate = Date(timeIntervalSinceNow: 2 * 60) // Every 2 minutes for active Live Activities
            do {
                try BGTaskScheduler.shared.submit(refresh)
                log.info("Scheduled frequent refresh in 2 minutes for Live Activity")
            } catch {
                log.error("Submit frequent refresh failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
    
    private func handleRefresh(_ task: BGAppRefreshTask) async {
        log.info("BG refresh invoked")
        
        await withTaskCancellationHandler {
            await applyBatchedActivityUpdates()
            
            // Schedule next run based on whether Live Activities are active
            let hasActivities = !Activity<PouchActivityAttributes>.activities.isEmpty
            if hasActivities {
                await scheduleFrequent() // More frequent updates for Live Activities
                log.info("Live Activities active - scheduled frequent refresh")
            } else {
                await scheduleRegular() // Normal cadence when no Live Activities
                log.info("No Live Activities - scheduled regular refresh")
            }
            
            task.setTaskCompleted(success: true)
        } onCancel: {
            task.setTaskCompleted(success: false)
        }
    }
    
    private func handleProcess(_ task: BGProcessingTask) async {
        log.info("BG processing invoked")
        await scheduleRegular()
        
        await withTaskCancellationHandler {
            await applyBatchedActivityUpdates()
            task.setTaskCompleted(success: true)
        } onCancel: {
            task.setTaskCompleted(success: false)
        }
    }
    
    private func snapshotTracked() -> [LiveActivityManager.TrackedActivity] {
        let acts = Activity<PouchActivityAttributes>.activities
        return acts.map { a in
            LiveActivityManager.TrackedActivity(
                id: a.id,
                pouchId: a.attributes.pouchId,
                startTime: a.attributes.startTime,
                endTime: a.attributes.endTime,
                totalNicotine: a.attributes.totalNicotine
            )
        }
    }
    
    private func computeState(for t: LiveActivityManager.TrackedActivity, now: Date = Date()) -> (ClosedRange<Date>, Double, Double) {
        let elapsed = max(0, now.timeIntervalSince(t.startTime))
        let total = max(1, t.endTime.timeIntervalSince(t.startTime)) // guard division
        let clampedElapsed = min(elapsed, total)
        let progress = clampedElapsed / total
        let currentLevel = AbsorptionConstants.shared
            .calculateCurrentNicotineLevel(nicotineContent: t.totalNicotine, elapsedTime: clampedElapsed)
        let timer = t.startTime...t.endTime
        return (timer, progress, currentLevel)
    }
    
    private func shouldEnd(_ t: LiveActivityManager.TrackedActivity, now: Date = Date()) -> Bool {
        now >= t.endTime
    }
    
    private func applyBatchedActivityUpdates() async {
        let now = Date()
        let items = snapshotTracked()
        guard !items.isEmpty else { return }
        for t in items {
            if shouldEnd(t, now: now) {
                await LiveActivityManager.endLiveActivity(for: t.pouchId)
            } else {
                let (timer, progress, current) = computeState(for: t, now: now)
                await LiveActivityManager.updateLiveActivity(
                    for: t.pouchId,
                    timerInterval: timer,
                    absorptionProgress: progress,
                    currentNicotineLevel: current
                )
            }
        }
        log.info("Applied batched updates to \(items.count, privacy: .public) activities")
    }
}
