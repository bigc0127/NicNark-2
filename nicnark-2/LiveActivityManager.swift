// LiveActivityManager.swift
//
// Live Activities Management for iOS 16.1+
//
// Live Activities appear on the Lock Screen and Dynamic Island showing real-time pouch countdown.
// This manager handles the complete lifecycle:
// • Creating new Live Activities when pouches are logged
// • Updating activities with current nicotine levels and progress
// • Preventing duplicate activities (one active pouch at a time)
// • Synchronizing activities across devices via CloudKit
// • Background updates to keep activities fresh when app is backgrounded
// • Cleanup when pouches are removed or timers complete
//
// Key iOS integration points:
// • ActivityKit framework for Live Activity creation and updates
// • Background Tasks framework for keeping activities updated
// • Core Data for verifying pouch status and preventing stale activities
// • WidgetKit for coordinated widget updates
//

@preconcurrency import BackgroundTasks  // Background processing for activity updates
import ActivityKit      // iOS 16.1+ Live Activities framework
import Foundation
import SwiftUI
import CoreData        // Database access for pouch verification
import os.log          // System logging
import UIKit          // App lifecycle notifications
import WidgetKit      // Widget timeline management

/**
 * LiveActivityManager: Manages Live Activities for pouch countdown timers.
 * 
 * Live Activities are iOS 16.1+ features that show dynamic content on the Lock Screen
 * and Dynamic Island. For nicotine pouches, this displays:
 * - Real-time countdown timer
 * - Current absorption progress
 * - Nicotine level calculations
 * - "Remove Pouch" action button
 * 
 * The manager is thread-safe and prevents duplicate activities while handling
 * complex scenarios like device syncing, app backgrounding, and activity restoration.
 * 
 * @available(iOS 16.1, *) ensures this only compiles and runs on supported iOS versions
 * @MainActor ensures all UI updates happen on the main thread
 */
@available(iOS 16.1, *)
@MainActor
class LiveActivityManager: ObservableObject {
    /// Published property that UI can observe to show/hide activity-related elements
    @Published var hasActiveNotification: Bool = false
    /// Logger for debugging activity lifecycle issues
    private let logger = Logger(subsystem: "com.nicnark.nicnark-2", category: "LiveActivity")
    
    /// Maps pouch UUIDs to activity IDs to prevent duplicate activities for the same pouch
    /// Dictionary: pouchId (String) -> activityId (String)
    private static var activeActivitiesByPouchId: [String: String] = [:]
    
    /// Serial queue to prevent race conditions when multiple parts of the app try to manage activities
    /// Uses userInitiated QoS for responsive Live Activity updates
    private static let activityQueue = DispatchQueue(label: "com.nicnark.liveactivity.queue", qos: .userInitiated)
    
    /**
     * TrackedActivity: Lightweight representation of a Live Activity for background processing.
     * 
     * This struct contains just the essential data needed for background tasks to update
     * Live Activities without loading the full ActivityKit framework or UI components.
     * Used by background tasks to efficiently track and update multiple activities.
     */
    struct TrackedActivity: Hashable {
        let id: String              // ActivityKit activity identifier
        let pouchId: String         // Our app's pouch UUID
        let startTime: Date         // When the pouch was inserted
        let endTime: Date           // When absorption completes
        let totalNicotine: Double   // Original nicotine amount
    }
    
    /**
     * Initializes the LiveActivityManager and sets up app lifecycle monitoring.
     * 
     * This constructor:
     * 1. Checks for existing activities from previous app launches
     * 2. Sets up observers for app state changes to manage background updates
     * 3. Schedules background tasks to keep activities fresh
     */
    init() {
        // Check if we have any existing Live Activities from previous app sessions
        Task { await checkForActiveActivities() }
        
        // When app goes to background, schedule background tasks to keep activities updated
        NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,  // App losing focus
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleBackgroundMaintainers()  // Set up background refresh
            }
        }
        
        // When app returns to foreground, refresh our activity count
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,  // App gaining focus
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { await self?.checkForActiveActivities() }  // Sync with iOS activity state
        }
    }
    
    /**
     * Counts current Live Activities and updates the UI state accordingly.
     * 
     * This method queries iOS for the current number of active Live Activities
     * and updates the @Published hasActiveNotification property so UI components
     * can show/hide activity-related elements (like toolbar badges).
     */
    private func checkForActiveActivities() async {
        let count = Activity<PouchActivityAttributes>.activities.count
        hasActiveNotification = count > 0  // Update UI state
        logger.info("Active activities: \(count)")
    }
    
    // MARK: - Core Data Integration
    // These methods ensure Live Activities stay synchronized with the app's database
    
    /**
     * Verifies that a pouch is still active in the database before creating/updating its Live Activity.
     * 
     * This prevents stale Live Activities from being created for pouches that were already removed
     * on other devices or through other app entry points. Essential for CloudKit sync scenarios.
     * 
     * - Parameter pouchId: UUID string of the pouch to check
     * - Returns: true if pouch exists and removalTime is nil, false otherwise
     */
    static func isPouchActive(_ pouchId: String) async -> Bool {
        await MainActor.run {
            let context = PersistenceController.shared.container.viewContext
            
            if let uuid = UUID(uuidString: pouchId) {
                let fetch: NSFetchRequest<PouchLog> = PouchLog.fetchRequest()
                fetch.predicate = NSPredicate(format: "pouchId == %@", uuid as CVarArg)
                fetch.fetchLimit = 1
                
                do {
                    if let pouchLog = try context.fetch(fetch).first {
                        return pouchLog.removalTime == nil
                    }
                } catch {
                    Logger(subsystem: "com.nicnark.nicnark-2", category: "LiveActivity")
                        .error("Failed to check pouch status: \(error.localizedDescription, privacy: .public)")
                }
            }
            return false
        }
    }
    
    /// Check if an activity already exists for a pouch
    static func activityExists(for pouchId: String) -> Bool {
        // Check both our tracking dictionary and actual activities
        if activeActivitiesByPouchId[pouchId] != nil {
            return true
        }
        
        // Also check actual activities in case tracking is out of sync
        return Activity<PouchActivityAttributes>.activities
            .contains { $0.attributes.pouchId == pouchId }
    }
    
    // MARK: - Start
    
    /**
     * Starts a Live Activity for the given pouch.
     *
     * Parameters:
     * - pouchId: Stable UUID of the pouch (used across devices)
     * - nicotineAmount: Nicotine content of the pouch in mg
     * - insertionTime: The ACTUAL time the pouch was inserted (from Core Data).
     *                  If nil, falls back to `Date()`.
     * - duration: Absorption duration to display (in seconds). If nil, uses FULL_RELEASE_TIME.
     * - isFromSync: If true, this activity was started due to CloudKit sync (don't end others).
     *
     * Important: Using the actual insertionTime keeps the Live Activity's countdown
     * perfectly aligned with the in‑app timer, widgets, and notifications.
     */
    static func startLiveActivity(for pouchId: String, nicotineAmount: Double, insertionTime: Date? = nil, duration: TimeInterval? = nil, isFromSync: Bool = false) async -> Bool {
        let log = Logger(subsystem: "com.nicnark.nicnark-2", category: "LiveActivity")
        let auth = ActivityAuthorizationInfo()
        guard auth.areActivitiesEnabled else {
            log.error("Live Activities disabled")
            return false
        }
        
        // CRITICAL: First check if the pouch is still active in Core Data
        // This prevents creating activities for already-removed pouches
        guard await isPouchActive(pouchId) else {
            log.info("Pouch no longer active, skipping Live Activity: \(pouchId, privacy: .public)")
            return false
        }
        
        // Check if activity already exists to prevent duplicates
        if activityExists(for: pouchId) {
            log.info("Live Activity already exists for pouch: \(pouchId, privacy: .public)")
            
            // Sync our tracking dictionary with actual activities if needed
            if activeActivitiesByPouchId[pouchId] == nil,
               let existing = Activity<PouchActivityAttributes>.activities
                   .first(where: { $0.attributes.pouchId == pouchId }) {
                activeActivitiesByPouchId[pouchId] = existing.id
            }
            return true
        }
        
        // Only end all activities if this is NOT from a sync (local creation)
        if !isFromSync {
            // For local creation, end all other activities (one pouch at a time)
            await endAllLiveActivities()
        }
        
        // Use the ACTUAL insertion time from Core Data whenever possible.
        // This avoids mismatches where the activity restarts at a default duration.
        let start = insertionTime ?? Date()
        let actualDuration = duration ?? FULL_RELEASE_TIME
        let end = start.addingTimeInterval(actualDuration)
        let attributes = PouchActivityAttributes(
            pouchName: "\(Int(nicotineAmount))mg Pouch",
            totalNicotine: nicotineAmount,
            startTime: start,
            expectedDuration: actualDuration,
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
            let newActivity = try Activity.request(attributes: attributes, content: content)
            // Track this new activity to prevent duplicates
            activeActivitiesByPouchId[pouchId] = newActivity.id
            log.info("🎆 Live Activity CREATED - ID: \(newActivity.id), PouchID: \(pouchId, privacy: .public), FromSync: \(isFromSync)")
            
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
        Task { await startForegroundMinuteTicker(pouchId: pouchId, nicotineAmount: nicotineAmount, startTime: start, duration: actualDuration) }
            // Schedule an early background refresh in case the app soon goes inactive
            Task { await BackgroundMaintainer.shared.scheduleSoon() }
            
            // Force an immediate update to ensure the Live Activity is showing
            Task {
                try? await Task.sleep(nanoseconds: 1 * NSEC_PER_SEC) // Wait 1 second for activity to register
                await updateLiveActivity(
                    for: pouchId,
                    timerInterval: start...end,
                    absorptionProgress: 0.0,
                    currentNicotineLevel: 0.0
                )
            }
            return true
        } catch {
            log.error("Start Live Activity failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
    
    // MARK: - Foreground ticker
    
    /**
     * Foreground ticker that updates the Live Activity while the app is active.
     *
     * Uses the explicit `startTime` passed from the creator rather than the
     * activity's attributes to guard against any drift or attribute desyncs.
     */
    private static func startForegroundMinuteTicker(pouchId: String, nicotineAmount: Double, startTime: Date, duration: TimeInterval) async {
        let log = Logger(subsystem: "com.nicnark.nicnark-2", category: "LiveActivity")
        var updateCount = 0
        
        while true {
            // Only need to verify existence; no need to bind a local variable
            guard Activity<PouchActivityAttributes>.activities.first(where: { $0.attributes.pouchId == pouchId }) != nil else {
                log.info("Ticker stopped: no activity")
                break
            }
            
            // Stop foreground ticker when app goes to background
            if UIApplication.shared.applicationState != .active {
                log.info("App backgrounded - stopping foreground ticker, relying on background tasks")
                // Schedule immediate background update when going to background
                await BackgroundMaintainer.shared.scheduleSoon()
                break
            }
            
            // Use the actual start time passed in, not the activity's attribute
            let elapsed = Date().timeIntervalSince(startTime)
            let remaining = max(0, duration - elapsed)
            if remaining <= 0 {
                await endLiveActivity(for: pouchId)
                break
            }
            
            let currentLevel = AbsorptionConstants.shared
                .calculateCurrentNicotineLevel(nicotineContent: nicotineAmount, elapsedTime: elapsed)
            let progress = min(max(elapsed / duration, 0), 1)
            // Use the actual start time and calculated end time
            let timer = startTime...startTime.addingTimeInterval(duration)
            
            await updateLiveActivity(
                for: pouchId,
                timerInterval: timer,
                absorptionProgress: progress,
                currentNicotineLevel: currentLevel
            )
            
            updateCount += 1
            log.info("🔄 Foreground update #\(updateCount) - level: \(String(format: "%.3f", currentLevel))mg, progress: \(Int(progress * 100))%")
            
            // Update every 30 seconds in foreground for better responsiveness
            try? await Task.sleep(nanoseconds: 30 * NSEC_PER_SEC)
        }
    }
    
    // MARK: - Update Live Activity Start Time
    
    static func updateLiveActivityStartTime(for pouchId: String, newStartTime: Date, nicotineAmount: Double) async {
        let log = Logger(subsystem: "com.nicnark.nicnark-2", category: "LiveActivity")
        // Only need a boolean existence check to avoid unused variable warnings
        guard Activity<PouchActivityAttributes>.activities.contains(where: { $0.attributes.pouchId == pouchId }) else {
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
        
        // Remove from tracking dictionary FIRST to prevent any new activity creation
        // This is critical to prevent race conditions
        let wasTracked = activeActivitiesByPouchId.removeValue(forKey: pouchId) != nil
        
        guard let activity = Activity<PouchActivityAttributes>.activities.first(where: { $0.attributes.pouchId == pouchId }) else {
            if wasTracked {
                log.warning("Activity was tracked but not found for pouch: \(pouchId, privacy: .public)")
            }
            return
        }
        
        // Calculate actual time in mouth (might be less than FULL_RELEASE_TIME if removed early)
        let now = Date()
        let actualTimeInMouth = min(now.timeIntervalSince(activity.attributes.startTime), FULL_RELEASE_TIME)
        
        // Calculate the actual absorbed amount based on actual time in mouth
        let finalLevel = AbsorptionConstants.shared
            .calculateAbsorbedNicotine(
                nicotineContent: activity.attributes.totalNicotine,
                useTime: actualTimeInMouth  // Use actual time, not theoretical max time
            )
        
        let timer = activity.attributes.startTime...activity.attributes.endTime
        let finalState = PouchActivityAttributes.ContentState(
            timerInterval: timer,
            currentNicotineLevel: finalLevel,
            status: "Complete",
            absorptionRate: min(actualTimeInMouth / FULL_RELEASE_TIME, 1.0),  // Actual absorption rate
            lastUpdated: Date()
        )
        
        let finalContent = ActivityContent(state: finalState, staleDate: Date())
        let dismissAt = Calendar.current.date(byAdding: .minute, value: 2, to: Date()) ?? Date()
        await activity.end(finalContent, dismissalPolicy: .after(dismissAt))
        
        // Update widget with the actual final level before marking as ended
        let helper = WidgetPersistenceHelper()
        helper.setFromLiveActivity(
            level: finalLevel,
            peak: finalLevel,
            pouchName: "Pouch removed",
            endTime: now  // Use actual removal time
        )
        
        // Then mark as ended after a brief delay
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)  // 0.5 second delay
            helper.markActivityEnded()
            WidgetCenter.shared.reloadAllTimelines()
        }
        
        log.info("Live Activity ended - actual absorption: \(String(format: "%.3f", finalLevel))mg")
    }
    
    static func endAllLiveActivities() async {
        let log = Logger(subsystem: "com.nicnark.nicnark-2", category: "LiveActivity")
        
        // Clear all tracking first to prevent race conditions
        let trackedCount = activeActivitiesByPouchId.count
        activeActivitiesByPouchId.removeAll()
        
        let activities = Activity<PouchActivityAttributes>.activities
        log.info("Ending all activities - tracked: \(trackedCount), actual: \(activities.count)")
        
        for activity in activities {
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
        // Registration now happens synchronously in app init to avoid crashes
        // This function is kept for compatibility but does nothing
        guard !registered else { return }
        registered = true
        log.info("BGTasks already registered in app init")
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
    
    func handleRefresh(_ task: BGAppRefreshTask) async {
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
    
    func handleProcess(_ task: BGProcessingTask) async {
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
        guard !items.isEmpty else {
            log.info("No active Live Activities to update")
            return
        }
        
        log.info("🔄 Processing \(items.count) Live Activities for background update")
        
        // Process each Live Activity
        for t in items {
            // Check if pouch is still active in Core Data
            let isPouchActive = await LiveActivityManager.isPouchActive(t.pouchId)
            
            if !isPouchActive {
                // Pouch was removed, end the Live Activity
                log.info("📱 Ending Live Activity for removed pouch: \(t.pouchId, privacy: .public)")
                await LiveActivityManager.endLiveActivity(for: t.pouchId)
                continue
            }
            
            // Get actual pouch data to ensure we have the latest state
            guard let actualPouchData = await getActualPouchData(for: t.pouchId) else {
                log.warning("Could not fetch pouch data for: \(t.pouchId, privacy: .public)")
                continue
            }
            
            let effectiveStartTime = actualPouchData.startTime
            let effectiveNicotineAmount = actualPouchData.nicotineAmount
            let effectiveDuration = actualPouchData.duration  // Use pouch-specific duration
            let elapsed = max(0, now.timeIntervalSince(effectiveStartTime))
            let endTime = effectiveStartTime.addingTimeInterval(effectiveDuration)  // Use actual duration, not FULL_RELEASE_TIME
            
            // Decision matrix logging
            let isExpired = now >= endTime
            log.info("📊 Pouch \(t.pouchId, privacy: .public): active=\(actualPouchData.isActive), expired=\(isExpired), elapsed=\(Int(elapsed))s, duration=\(Int(effectiveDuration))s")
            
            if isExpired {
                log.info("⏰ Timer expired, ending Live Activity for: \(t.pouchId, privacy: .public)")
                await LiveActivityManager.endLiveActivity(for: t.pouchId)
            } else {
                // Update the Live Activity with current state
                let progress = min(max(elapsed / effectiveDuration, 0), 1)  // Use actual duration for progress
                let currentLevel = AbsorptionConstants.shared
                    .calculateCurrentNicotineLevel(nicotineContent: effectiveNicotineAmount, elapsedTime: elapsed)
                let timer = effectiveStartTime...endTime
                
                log.info("📱 Updating Live Activity: progress=\(Int(progress * 100))%, level=\(String(format: "%.3f", currentLevel))mg")
                
                await LiveActivityManager.updateLiveActivity(
                    for: t.pouchId,
                    timerInterval: timer,
                    absorptionProgress: progress,
                    currentNicotineLevel: currentLevel
                )
            }
        }
        
        log.info("✅ Background update complete at \(DateFormatter.localizedString(from: now, dateStyle: .none, timeStyle: .medium), privacy: .public)")
    }
    
    // Synchronous helper for immediate checks (used in startLiveActivity)
    func getActualPouchDataSync(for pouchId: String) -> (startTime: Date, nicotineAmount: Double, isActive: Bool, duration: TimeInterval)? {
        let context = PersistenceController.shared.container.viewContext
        
        if let uuid = UUID(uuidString: pouchId) {
            let fetch: NSFetchRequest<PouchLog> = PouchLog.fetchRequest()
            fetch.predicate = NSPredicate(format: "pouchId == %@", uuid as CVarArg)
            fetch.fetchLimit = 1
            do {
                if let pouchLog = try context.fetch(fetch).first, let startTime = pouchLog.insertionTime {
                    let isActive = pouchLog.removalTime == nil
                    // Get the pouch's specific duration (stored in minutes, convert to seconds)
                    let duration = TimeInterval(pouchLog.timerDuration * 60)
                    return (startTime: startTime, nicotineAmount: pouchLog.nicotineAmount, isActive: isActive, duration: duration)
                }
            } catch {
                log.warning("Sync fetch error: \(error.localizedDescription, privacy: .public)")
            }
        }
        return nil
    }
    
    private func getActualPouchData(for pouchId: String) async -> (startTime: Date, nicotineAmount: Double, isActive: Bool, duration: TimeInterval)? {
        return await MainActor.run {
            let context = PersistenceController.shared.container.viewContext
            
            // 1) Prefer stable UUID-based lookup to avoid Core Data URI pitfalls
            if let uuid = UUID(uuidString: pouchId) {
                let fetch: NSFetchRequest<PouchLog> = PouchLog.fetchRequest()
                fetch.predicate = NSPredicate(format: "pouchId == %@", uuid as CVarArg)
                fetch.fetchLimit = 1
                do {
                    if let pouchLog = try context.fetch(fetch).first, let startTime = pouchLog.insertionTime {
                        let isActive = pouchLog.removalTime == nil // Only active if not removed
                        // Get the pouch's specific duration (stored in minutes, convert to seconds)
                        let duration = TimeInterval(pouchLog.timerDuration * 60)
                        return (startTime: startTime, nicotineAmount: pouchLog.nicotineAmount, isActive: isActive, duration: duration)
                    } else {
                        log.warning("UUID lookup failed or missing insertionTime for pouchId: \(uuid.uuidString, privacy: .public)")
                    }
                } catch {
                    log.warning("UUID fetch error: \(error.localizedDescription, privacy: .public)")
                }
            }
            
            // 2) Legacy fallback: skip resolving Core Data URI to avoid iOS 18+ instability
            // Returning nil simply uses the currently tracked activity times.
        return nil
    }
}
}
