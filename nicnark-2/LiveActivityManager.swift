// LiveActivityManager.swift

@preconcurrency import BackgroundTasks
import ActivityKit
import Foundation
import SwiftUI
import os.log
import UIKit
import WidgetKit

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
            staleDate: Calendar.current.date(byAdding: .minute, value: 40, to: start) // Longer stale date to prevent throttling
        )
        
        do {
            _ = try Activity.request(attributes: attributes, content: content)
            log.info("Live Activity started for pouch: \(pouchId, privacy: .public)")
            
            // Seed widget snapshot immediately
            let helper = WidgetPersistenceHelper()
            helper.setFromLiveActivity(
                level: 0,
                peak: nicotineAmount * ABSORPTION_FRACTION,
                pouchName: attributes.pouchName,
                endTime: end
            )
            WidgetCenter.shared.reloadAllTimelines()
            
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
            
            // Update every 60 seconds in foreground - iOS throttles more frequent updates
            try? await Task.sleep(nanoseconds: 60 * NSEC_PER_SEC)
        }
    }
    
    // MARK: - Update Live Activity Start Time
    
    static func updateLiveActivityStartTime(for pouchId: String, newStartTime: Date, nicotineAmount: Double) async {
        let log = Logger(subsystem: "com.nicnark.nicnark-2", category: "LiveActivity")
        guard Activity<PouchActivityAttributes>.activities.first(where: { $0.attributes.pouchId == pouchId }) != nil else {
            log.warning("No activity to update start time for pouch: \(pouchId, privacy: .public)")
            return
        }
        
        // Calculate new end time based on the new start time
        let newEndTime = newStartTime.addingTimeInterval(FULL_RELEASE_TIME)
        let now = Date()
        
        // Calculate elapsed time and progress based on the new start time
        let elapsed = max(0, now.timeIntervalSince(newStartTime))
        let progress = min(max(elapsed / FULL_RELEASE_TIME, 0), 1)
        
        // Calculate current nicotine level based on new elapsed time
        let currentLevel = AbsorptionConstants.shared
            .calculateCurrentNicotineLevel(nicotineContent: nicotineAmount, elapsedTime: elapsed)
        
        // Create new timer interval with updated times
        let newTimerInterval = newStartTime...newEndTime
        
        // Update the Live Activity with the new timer interval and calculated values
        await updateLiveActivity(
            for: pouchId,
            timerInterval: newTimerInterval,
            absorptionProgress: progress,
            currentNicotineLevel: currentLevel
        )
        
        log.info("Live Activity start time updated for pouch: \(pouchId, privacy: .public) - new start: \(newStartTime, privacy: .public)")
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
            staleDate: Calendar.current.date(byAdding: .minute, value: 5, to: now) // Longer stale date for better reliability
        )
        
        await activity.update(content)
        
        // Update widget snapshot and reload timelines (throttled by system)
        let helper = WidgetPersistenceHelper()
        helper.setFromLiveActivity(
            level: currentNicotineLevel,
            peak: activity.attributes.totalNicotine * ABSORPTION_FRACTION,
            pouchName: activity.attributes.pouchName,
            endTime: activity.attributes.endTime
        )
        WidgetCenter.shared.reloadAllTimelines()
        
        log.info("✅ Live Activity updated: pouch=\(pouchId, privacy: .public) level=\(String(format: "%.3f", currentNicotineLevel))mg progress=\(Int(absorptionProgress * 100))% status=\(status, privacy: .public)")
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
        
        // Mark widget state as ended and reload
        let helper = WidgetPersistenceHelper()
        helper.markActivityEnded()
        WidgetCenter.shared.reloadAllTimelines()
        
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
            // Cancel existing tasks to prevent conflicts
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: refreshId)
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: processId)
            
            // More frequent refresh for Live Activity updates - every 3 minutes
            let refresh = BGAppRefreshTaskRequest(identifier: refreshId)
            refresh.earliestBeginDate = Date(timeIntervalSinceNow: 3 * 60) // 3 minutes - more frequent for better reliability
            do {
                try BGTaskScheduler.shared.submit(refresh)
                log.info("Scheduled regular refresh in 3 minutes")
            } catch {
                log.error("Submit refresh failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
    
    func scheduleSoon() async {
        await registerIfNeeded()
        
        await MainActor.run {
            // Cancel existing tasks to prevent conflicts
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: refreshId)
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: processId)
            
            let refresh = BGAppRefreshTaskRequest(identifier: refreshId)
            refresh.earliestBeginDate = Date(timeIntervalSinceNow: 30) // 30 seconds - faster initial response
            do {
                try BGTaskScheduler.shared.submit(refresh)
                log.info("Scheduled immediate refresh in 30 seconds")
            } catch {
                log.error("Submit 'soon' refresh failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
    
    // New function for very frequent updates when Live Activities are active
    func scheduleFrequent() async {
        await registerIfNeeded()
        
        await MainActor.run {
            // Cancel existing tasks to prevent conflicts
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: refreshId)
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: processId)
            
            let refresh = BGAppRefreshTaskRequest(identifier: refreshId)
            refresh.earliestBeginDate = Date(timeIntervalSinceNow: 90) // 1.5 minutes for active Live Activities - more frequent
            do {
                try BGTaskScheduler.shared.submit(refresh)
                log.info("Scheduled frequent refresh in 1.5 minutes for Live Activity")
            } catch {
                log.error("Submit frequent refresh failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
    
    private func handleRefresh(_ task: BGAppRefreshTask) async {
        log.info("🔔 BG refresh invoked at \(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium), privacy: .public)")
        
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
        log.info("⚙️ BG processing invoked at \(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium), privacy: .public)")
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
        
        // For each Live Activity, try to get the actual pouch data from Core Data
        // to ensure we're using the most up-to-date start time if it was edited
        await MainActor.run {
            for t in items {
                Task {
                    let actualPouchData = await getActualPouchData(for: t.pouchId)
                    let effectiveStartTime = actualPouchData?.startTime ?? t.startTime
                    let effectiveNicotineAmount = actualPouchData?.nicotineAmount ?? t.totalNicotine
                    
                    let elapsed = max(0, now.timeIntervalSince(effectiveStartTime))
                    let endTime = effectiveStartTime.addingTimeInterval(FULL_RELEASE_TIME)
                    
                    if now >= endTime {
                        await LiveActivityManager.endLiveActivity(for: t.pouchId)
                    } else {
                        let progress = min(max(elapsed / FULL_RELEASE_TIME, 0), 1)
                        let currentLevel = AbsorptionConstants.shared
                            .calculateCurrentNicotineLevel(nicotineContent: effectiveNicotineAmount, elapsedTime: elapsed)
                        let timer = effectiveStartTime...endTime
                        
                        await LiveActivityManager.updateLiveActivity(
                            for: t.pouchId,
                            timerInterval: timer,
                            absorptionProgress: progress,
                            currentNicotineLevel: currentLevel
                        )
                    }
                }
            }
        }
        
        log.info("🔄 Applied batched updates to \(items.count, privacy: .public) activities at \(DateFormatter.localizedString(from: now, dateStyle: .none, timeStyle: .medium), privacy: .public)")
    }
    
    private func getActualPouchData(for pouchId: String) async -> (startTime: Date, nicotineAmount: Double)? {
        return await MainActor.run {
            // Guard against invalid URL format
            guard let url = URL(string: pouchId) else {
                log.warning("Invalid pouchId URL format: \(pouchId, privacy: .public)")
                return nil
            }
            
            // Use PersistenceController from main app instead of WidgetPersistenceHelper
            // This ensures we're using the same CloudKit-backed store
            let context = PersistenceController.shared.container.viewContext
            
            // Try to get the managed object ID safely
            guard let objectID = context.persistentStoreCoordinator?.managedObjectID(forURIRepresentation: url) else {
                log.warning("Could not resolve objectID for URL: \(url.absoluteString, privacy: .public)")
                return nil
            }
            
            // Check if the object exists before trying to fetch it
            // This prevents crashes when CloudKit schema changes
            do {
                let pouchLog = try context.existingObject(with: objectID) as? PouchLog
                guard let pouchLog = pouchLog,
                      let startTime = pouchLog.insertionTime else {
                    log.warning("PouchLog not found or missing insertionTime for objectID")
                    return nil
                }
                
                return (startTime: startTime, nicotineAmount: pouchLog.nicotineAmount)
                
            } catch {
                // Object doesn't exist or was deleted - this is expected when CloudKit syncs deletions
                log.warning("Failed to fetch PouchLog: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
    }
}
