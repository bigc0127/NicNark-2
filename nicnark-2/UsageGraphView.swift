//
// UsageGraphView.swift
// nicnark-2
//
// 24-Hour Usage Timeline with Statistics and Insights
//
// This view provides a comprehensive 24-hour timeline of pouch usage with:
// • Hour-by-hour breakdown of pouch consumption
// • Real-time statistics (streak count, time since last pouch)
// • Interactive pouch cards with edit/delete capabilities
// • Smart reminder information (time-based or nicotine-level-based)
// • Nicotine level monitoring and predictions
// • Visual feedback with color coding and animations
//
// The view uses a ViewModel pattern for better separation of concerns and
// efficient data updates. It maintains a lightweight projection of Core Data
// entities to minimize memory usage and improve scrolling performance.
//

import SwiftUI
import CoreData

// MARK: - Data Models

/**
 * PouchEvent: Lightweight representation of a pouch usage event.
 * 
 * This struct is a projection of the Core Data PouchLog entity,
 * containing only the essential data needed for display. This approach:
 * - Reduces memory footprint for large datasets
 * - Improves scrolling performance
 * - Decouples UI from Core Data managed object lifecycle
 * 
 * Properties:
 * - id: Unique identifier matching the Core Data pouchId
 * - name: Display name (e.g., "6mg Pouch")
 * - removedAt: When the pouch was removed (or insertion time if still active)
 * - nicotineMg: Nicotine content for absorption calculations
 */
public struct PouchEvent: Identifiable, Hashable {
    public let id: UUID
    public let name: String
    public let removedAt: Date   // removalTime or fallback to insertionTime
    public let nicotineMg: Double
}

/**
 * HourBucket: Groups events within a single hour for timeline display.
 * 
 * The timeline is divided into 24 hour-long buckets, each containing
 * all pouches used during that hour. This structure enables:
 * - Efficient rendering of the timeline
 * - Easy identification of usage patterns
 * - Clear visual separation of time periods
 * 
 * Properties:
 * - id: Unique identifier for SwiftUI ForEach
 * - hourStart: Beginning of the hour period
 * - events: All pouches used during this hour
 */
struct HourBucket: Identifiable, Hashable {
    let id = UUID()
    let hourStart: Date
    let events: [PouchEvent]
}

// MARK: - ViewModel

/**
 * UsageGraphViewModel: Manages data and business logic for the usage timeline.
 * 
 * This ViewModel handles:
 * - Converting Core Data entities to lightweight projections
 * - Calculating time-based statistics (streak, time since last)
 * - Managing timer updates for real-time display
 * - Grouping events into hourly buckets
 * - Tracking active pouch state
 * 
 * The ViewModel pattern provides:
 * - Separation of UI and business logic
 * - Testability of data transformations
 * - Efficient update batching with @Published
 * - Memory management through lightweight projections
 * 
 * @MainActor ensures all updates happen on the main thread for UI safety.
 */
@MainActor
final class UsageGraphViewModel: ObservableObject {
    // MARK: - Published Properties
    @Published var events: [PouchEvent] = []           // All events in last 24 hours
    @Published var streakDays: Int = 0                 // Count of pouches in 24hr window

    // Time tracking for inactive state
    @Published private(set) var sinceLastPhrase: String = "0 hours 00 mins"  // Formatted time string
    @Published private(set) var sinceLastHH: Int = 0                          // Hours component
    @Published private(set) var sinceLastMM: Int = 0                          // Minutes component

    // Active pouch tracking (displays "currently in" instead of "since last")
    @Published private(set) var hasActivePouch: Bool = false      // Whether a pouch is currently in use
    @Published private(set) var activeElapsedPhrase: String = "00:00"  // MM:SS format for active timer

    // MARK: - Private Properties
    private var timer: Timer?                          // Updates time displays every 2 minutes
    private let calendar = Calendar.current            // For date calculations

    // Provides access to Core Data context for timer updates without tight coupling
    static var contextProvider: (() -> NSManagedObjectContext)?

    deinit { timer?.invalidate() }  // Clean up timer to prevent memory leaks

    /**
     * Updates the view model with fresh data from Core Data.
     * 
     * This method:
     * 1. Converts Core Data entities to lightweight PouchEvent structs
     * 2. Filters to only include events from the last 24 hours
     * 3. Sorts events newest first for display
     * 4. Updates statistics (streak count, time since last)
     * 5. Refreshes active pouch state
     * 
     * - Parameters:
     *   - items: Array of PouchLog Core Data entities
     *   - context: Managed object context for querying active pouches
     */
    func setEvents(_ items: [PouchLog], context: NSManagedObjectContext) {
        // Convert Core Data rows into lightweight events
        let converted: [PouchEvent] = items.compactMap { row in
            guard let insertion = row.insertionTime else { return nil }
            let ts = row.removalTime ?? insertion
            let eventId = row.pouchId ?? UUID()
            let mg = max(0, row.nicotineAmount)
            let title = String(format: "%.0fmg Pouch", mg)
            return PouchEvent(id: eventId, name: title, removedAt: ts, nicotineMg: mg)
        }

        // Filter last 24 hours and sort newest first
        let now = Date()
        let cutoff = now.addingTimeInterval(-24 * 3600)
        let filtered = converted.filter { $0.removedAt >= cutoff && $0.removedAt <= now }
        events = filtered.sorted { $0.removedAt > $1.removedAt }

        // For this view, “streakDays” mirrors your original: count in the last 24 hours
        streakDays = filtered.count

        recomputeTimeSinceLast()
        startTimerIfNeeded()

        // Refresh active pouch state
        let (active, elapsed) = fetchHasActivePouch(context: context)
        hasActivePouch = active
        if let seconds = elapsed {
            activeElapsedPhrase = Self.mmss(seconds)
        } else {
            activeElapsedPhrase = "00:00"
        }
    }

    /**
     * Computed property that groups events into 24 hourly buckets.
     * 
     * Creates a descending list of 24 hours starting from the current hour.
     * Each bucket contains all events that occurred during that hour.
     * Empty hours still appear in the list with empty event arrays.
     * 
     * This structure enables the timeline view to show:
     * - Clear hour-by-hour breakdown
     * - Usage patterns throughout the day
     * - Empty periods for context
     * 
     * - Returns: Array of 24 HourBucket objects, newest hour first
     */
    var hourBuckets: [HourBucket] {
        let now = Date()
        let startOfHour = calendar.dateInterval(of: .hour, for: now)?.start
            ?? Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 / 3600) * 3600)

        // 24 hours descending from current hour start
        let startsDescending: [Date] = (0..<24).compactMap {
            calendar.date(byAdding: .hour, value: -$0, to: startOfHour)
        }

        let grouped = Dictionary(grouping: events) { evt in
            calendar.dateInterval(of: .hour, for: evt.removedAt)?.start
                ?? Date(timeIntervalSince1970: floor(evt.removedAt.timeIntervalSince1970 / 3600) * 3600)
        }

        return startsDescending.map { s in
            let eventsForHour = grouped[s] ?? []
            let sorted = eventsForHour.sorted { $0.removedAt < $1.removedAt }
            return HourBucket(hourStart: s, events: sorted)
        }
    }

    /**
     * Starts a timer to update time-based displays.
     * 
     * Timer fires every 2 minutes (optimized from 1 minute to save battery).
     * Updates:
     * - "Since last pouch" time display
     * - "Currently in" elapsed time for active pouches
     * 
     * Uses RunLoop.common mode to ensure updates continue during scrolling.
     */
    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        // Optimized: Only update every 2 minutes instead of every minute for power savings
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.recomputeTimeSinceLast()
                // Keep the "currently in" label fresh - but less frequently
                if let ctx = Self.contextProvider?() {
                    let (active, elapsed) = self.fetchHasActivePouch(context: ctx)
                    self.hasActivePouch = active
                    if let seconds = elapsed {
                        self.activeElapsedPhrase = Self.mmss(seconds)
                    } else {
                        self.activeElapsedPhrase = "00:00"
                    }
                }
            }
        }
        if let t = timer { RunLoop.main.add(t, forMode: .common) }
    }

    /**
     * Recalculates the time elapsed since the last pouch was removed.
     * 
     * Updates the display strings and numeric components used in the UI.
     * Shows "0 hours 00 mins" if no pouches have been used.
     * Only considers completed pouches (with removal time < now).
     */
    private func recomputeTimeSinceLast() {
        guard let lastRemoved = events
            .filter({ $0.removedAt < Date() })
            .max(by: { $0.removedAt < $1.removedAt })?.removedAt else {
            sinceLastHH = 0
            sinceLastMM = 0
            sinceLastPhrase = "0 hours 00 mins"
            return
        }

        let mins = Int(ceil(Date().timeIntervalSince(lastRemoved) / 60.0))
        sinceLastHH = mins / 60
        sinceLastMM = mins % 60
        sinceLastPhrase = "\(sinceLastHH) hours \(String(format: "%02d", sinceLastMM)) mins"
    }

    /**
     * Queries Core Data for currently active pouches.
     * 
     * An active pouch has removalTime == nil, indicating it's still in use.
     * Returns both the active state and elapsed time since insertion.
     * 
     * - Parameter context: Core Data context for querying
     * - Returns: Tuple of (hasActive: Bool, elapsedSeconds: TimeInterval?)
     */
    private func fetchHasActivePouch(context: NSManagedObjectContext) -> (Bool, TimeInterval?) {
        let request = NSFetchRequest<PouchLog>(entityName: "PouchLog")
        request.predicate = NSPredicate(format: "removalTime == nil")
        request.fetchLimit = 1
        if let row = try? context.fetch(request).first, let started = row.insertionTime {
            return (true, Date().timeIntervalSince(started))
        }
        return (false, nil)
    }

    /**
     * Formats a time interval as MM:SS string.
     * 
     * Used for the active pouch elapsed time display.
     * Ensures non-negative values and zero-pads components.
     * 
     * - Parameter interval: Time in seconds
     * - Returns: Formatted string like "12:34"
     */
    private static func mmss(_ interval: TimeInterval) -> String {
        let secs = Int(max(interval, 0))
        return String(format: "%02d:%02d", secs/60, secs%60)
    }
}

// MARK: - Main View

/**
 * UsageGraphView: Interactive 24-hour timeline of pouch usage.
 * 
 * This view provides comprehensive usage tracking with:
 * - Visual timeline divided into hourly sections
 * - Real-time statistics (streak count, time tracking)
 * - Smart reminder information based on user settings
 * - Interactive pouch cards with edit/delete capabilities
 * - Nicotine level monitoring with predictions
 * 
 * The view uses reactive updates through:
 * - @FetchRequest for Core Data changes
 * - NotificationCenter for external updates
 * - Timer-based updates for time displays
 * - @Published properties in the ViewModel
 */
struct UsageGraphView: View {
    // MARK: - Environment & State
    @Environment(\.managedObjectContext) private var viewContext           // Core Data context
    @StateObject private var vm = UsageGraphViewModel()                    // View model for data management
    @StateObject private var notificationSettings = NotificationSettings.shared  // User notification preferences

    // Core Data fetch for pouches in last 24 hours
    @FetchRequest private var recentLogs: FetchedResults<PouchLog>

    var streakDays: Int                                                    // Initial streak count (can be overridden)
    @State private var refreshTrigger = false                              // Forces view refresh on external changes
    @State private var showingEditSheet = false                            // Controls edit sheet presentation
    @State private var selectedPouchForEdit: PouchLog?                     // Pouch being edited
    @State private var nicotineInfo: (current: Double, prediction: String?, estimatedAfterCurrent: Double?) = (0.0, nil, nil)  // Current level, prediction, and estimated after current pouch
    @State private var nextPouchTime: Date?                                // Recommended time for next pouch

    init(streakDays: Int = 0) {
        self.streakDays = streakDays
        let since = Calendar.current.date(byAdding: .hour, value: -24, to: Date()) ?? Date()
        _recentLogs = FetchRequest(
            entity: PouchLog.entity(),
            sortDescriptors: [NSSortDescriptor(key: "insertionTime", ascending: false)],
            predicate: NSPredicate(format: "(insertionTime >= %@) OR (removalTime >= %@)", since as NSDate, since as NSDate),
            animation: .default
        )
    }

    var body: some View {
        mainContentView
            .onAppear(perform: setupView)
            .onChange(of: Array(recentLogs)) { _, _ in
                applyFetchToVM()
            }
            .onChange(of: refreshTrigger) { _, _ in
                applyFetchToVM()
            }
            .onReceive(pouchRemovedPublisher) { _ in
                refreshTrigger.toggle()
            }
            .onReceive(pouchEditedPublisher) { _ in
                refreshTrigger.toggle()
            }
            .onReceive(pouchDeletedPublisher) { _ in
                refreshTrigger.toggle()
            }
            .sheet(isPresented: $showingEditSheet, content: editSheetContent)
            .onChange(of: showingEditSheet) { _, newValue in
                onSheetStateChange(newValue)
            }
    }
    
    private var mainContentView: some View {
        VStack(spacing: 0) {
            headerTopSection
            reminderInfoSection
            Divider()
            scrollableContent
        }
    }
    
    private var scrollableContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(vm.hourBuckets) { bucket in
                    HourRowView(bucket: bucket, onEditPouch: handlePouchEdit)
                        .padding(.horizontal, 12)
                        .padding(.top, 6)
                        .padding(.bottom, 16)
                }
            }
        }
    }
    
    private var pouchRemovedPublisher: NotificationCenter.Publisher {
        NotificationCenter.default.publisher(for: NSNotification.Name("PouchRemoved"))
    }
    
    private var pouchEditedPublisher: NotificationCenter.Publisher {
        NotificationCenter.default.publisher(for: NSNotification.Name("PouchEdited"))
    }
    
    private var pouchDeletedPublisher: NotificationCenter.Publisher {
        NotificationCenter.default.publisher(for: NSNotification.Name("PouchDeleted"))
    }

    private func applyFetchToVM() {
        vm.setEvents(Array(recentLogs), context: viewContext)
    }
    
    private func setupView() {
        UsageGraphViewModel.contextProvider = { viewContext }
        viewContext.automaticallyMergesChangesFromParent = true
        applyFetchToVM()
    }
    
    private func handlePouchEdit(_ event: PouchEvent) {
        print("🔍 Looking for pouch with ID: \(event.id)")
        print("🔍 Available pouches: \(recentLogs.map { $0.pouchId?.uuidString ?? "nil" })")
        
        if let pouchLog = findPouchLog(for: event) {
            print("✅ Found matching pouch log!")
            selectedPouchForEdit = pouchLog
            showingEditSheet = true
        } else {
            print("❌ No matching pouch found for event ID: \(event.id)")
        }
    }
    
    @ViewBuilder
    private func editSheetContent() -> some View {
        if let pouchLog = selectedPouchForEdit {
            let _ = print("📋 Presenting edit sheet for pouch: \(pouchLog.pouchId?.uuidString ?? "unknown")")
            PouchEditView(
                pouchLog: pouchLog,
                onSave: {
                    print("💾 Edit saved")
                    refreshTrigger.toggle()
                },
                onDelete: {
                    print("🗑️ Edit deleted")
                    refreshTrigger.toggle()
                }
            )
        } else {
            let _ = print("❌ No pouch selected for editing")
            Text("Error: No pouch selected")
                .presentationDetents([.medium])
        }
    }
    
    private func onSheetStateChange(_ newValue: Bool) {
        print("🔄 Sheet state changed to: \(newValue)")
        print("🔄 Selected pouch: \(selectedPouchForEdit?.pouchId?.uuidString ?? "nil")")
    }
    
    private func findPouchLog(for event: PouchEvent) -> PouchLog? {
        print("🔎 FindPouchLog - Looking for: \(event.id)")
        print("🔎 FindPouchLog - Event nicotine: \(event.nicotineMg)mg")
        print("🔎 FindPouchLog - Event time: \(event.removedAt)")
        
        // First try exact UUID match
        if let foundPouch = recentLogs.first(where: { $0.pouchId == event.id }) {
            print("✅ FindPouchLog - Exact UUID match found")
            return foundPouch
        }
        
        // Enhanced fallback strategy for pouches with nil IDs or timing issues
        let sortedPouches = recentLogs.sorted { pouch1, pouch2 in
            guard let time1 = pouch1.insertionTime ?? pouch1.removalTime,
                  let time2 = pouch2.insertionTime ?? pouch2.removalTime else {
                return false
            }
            return abs(event.removedAt.timeIntervalSince(time1)) < abs(event.removedAt.timeIntervalSince(time2))
        }
        
        for (index, pouchLog) in sortedPouches.enumerated() {
            guard let insertionTime = pouchLog.insertionTime else { continue }
            
            let timeDifferenceFromInsertion = abs(event.removedAt.timeIntervalSince(insertionTime))
            let nicotineMatch = abs(pouchLog.nicotineAmount - event.nicotineMg) < 0.1
            
            // Check against removal time if it exists
            let timeDifferenceFromRemoval: Double
            if let removalTime = pouchLog.removalTime {
                timeDifferenceFromRemoval = abs(event.removedAt.timeIntervalSince(removalTime))
            } else {
                timeDifferenceFromRemoval = Double.infinity
            }
            
            let minTimeDifference = min(timeDifferenceFromInsertion, timeDifferenceFromRemoval)
            
            print("🔎 Pouch #\(index): Nicotine \(pouchLog.nicotineAmount)mg, ID: \(pouchLog.pouchId?.uuidString ?? "nil")")
            print("🔎   Time diff (insertion): \(timeDifferenceFromInsertion)s")
            print("🔎   Time diff (removal): \(timeDifferenceFromRemoval == Double.infinity ? "N/A" : "\(timeDifferenceFromRemoval)s")")
            print("🔎   Nicotine match: \(nicotineMatch)")
            
            // More lenient matching: within 2 hours and exact nicotine match
            if nicotineMatch && minTimeDifference < 7200 { // 2 hours = 7200 seconds
                print("✅ FindPouchLog - Fallback match found (Pouch #\(index))")
                return pouchLog
            }
        }
        
        // Last resort: just match by nicotine amount (for debugging)
        if let lastResortPouch = recentLogs.first(where: { abs($0.nicotineAmount - event.nicotineMg) < 0.1 }) {
            print("🆘 FindPouchLog - Last resort match by nicotine amount only")
            return lastResortPouch
        }
        
        print("❌ FindPouchLog - No match found")
        print("🔎 Available pouches count: \(recentLogs.count)")
        
        return nil
    }

    /**
     * Header section displaying key statistics.
     * 
     * Shows two main metrics:
     * 1. 24-Hour Streak: Total pouches used in last 24 hours (left side)
     * 2. Time Display: Either "Since last pouch" or "Currently in" (right side)
     * 
     * The right side dynamically switches based on active pouch state:
     * - Active pouch: Shows elapsed time in MM:SS format
     * - No active: Shows time since last in "X hours YY mins" format
     * 
     * Colors indicate state:
     * - Orange: Streak count
     * - Blue: Active pouch timer
     * - Green: Time since last pouch
     */
    private var headerTopSection: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("24‑Hour Streak")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("\(vm.streakDays) pouches")
                    .font(.title3).bold()
                    .foregroundColor(.orange)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(vm.hasActivePouch ? "Pouch is currently in" : "Since last pouch")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(vm.hasActivePouch ? vm.activeElapsedPhrase : vm.sinceLastPhrase)
                    .font(.title3).bold()
                    .monospacedDigit()
                    .foregroundColor(vm.hasActivePouch ? .blue : .green)
                    .accessibilityLabel(vm.hasActivePouch
                                        ? "\(vm.activeElapsedPhrase) elapsed"
                                        : "\(vm.sinceLastHH) hours \(vm.sinceLastMM) minutes")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
    
    /**
     * Reminder information section below the header.
     * 
     * Displays different content based on reminder type:
     * 
     * Time-based reminders:
     * - Shows next reminder time
     * - Calculates remaining time until reminder
     * - Indicates when reminder is due
     * 
     * Nicotine-level-based reminders:
     * - Shows current nicotine level in mg
     * - Indicates if level is in/above/below target range
     * - Predicts when next boundary crossing will occur
     * - Shows decay rate when applicable
     * 
     * Hidden when reminders are disabled.
     */
    @ViewBuilder
    private var reminderInfoSection: some View {
        if notificationSettings.reminderType != .disabled {
            HStack {
                Image(systemName: notificationSettings.reminderType == .nicotineLevelBased ? "chart.line.uptrend.xyaxis" : "clock")
                    .foregroundColor(.secondary)
                    .font(.caption)
                
                if notificationSettings.reminderType == .nicotineLevelBased {
                    // Show nicotine level info
                    VStack(alignment: .leading, spacing: 2) {
                        if vm.hasActivePouch, let estimated = nicotineInfo.estimatedAfterCurrent {
                            // Show estimated level after current pouch completes
                            Text("Estimated after current pouch")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            HStack(spacing: 4) {
                                Text(String(format: "%.3f mg", estimated))
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundColor(.blue)
                            }
                        } else {
                            // Show current level when no active pouch
                            Text("Current Nicotine Level")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            HStack(spacing: 4) {
                                Text(String(format: "%.3f mg", nicotineInfo.current))
                                    .font(.caption)
                                    .fontWeight(.medium)
                                
                                // Show if in/out of target range
                                if nicotineInfo.current < notificationSettings.nicotineRangeLow {
                                    Text("(Below target)")
                                        .font(.caption2)
                                        .foregroundColor(.orange)
                                } else if nicotineInfo.current > notificationSettings.nicotineRangeHigh {
                                    Text("(Above target)")
                                        .font(.caption2)
                                        .foregroundColor(.red)
                                } else {
                                    Text("(In range)")
                                        .font(.caption2)
                                        .foregroundColor(.green)
                                }
                            }
                        }
                        
                        if let prediction = nicotineInfo.prediction {
                            Text(prediction)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                } else {
                    // Show time-based reminder info
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Next Reminder")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        
                        if vm.hasActivePouch {
                            Text("After pouch removal")
                                .font(.caption)
                                .fontWeight(.medium)
                        } else {
                            let intervalText = notificationSettings.reminderInterval == .custom
                                ? "\(notificationSettings.customReminderMinutes) min"
                                : notificationSettings.reminderInterval.displayName
                            let remainingMins = max(0, notificationSettings.effectiveReminderMinutes - (vm.sinceLastHH * 60 + vm.sinceLastMM))
                            
                            if remainingMins > 0 {
                                let hours = remainingMins / 60
                                let mins = remainingMins % 60
                                let timeText = hours > 0 ? "\(hours)h \(mins)m" : "\(mins)m"
                                Text("In \(timeText) (\(intervalText) interval)")
                                    .font(.caption)
                                    .fontWeight(.medium)
                            } else {
                                Text("Due now (\(intervalText) interval)")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundColor(.orange)
                            }
                        }
                        
                        // Show next recommended pouch time
                        if let nextTime = nextPouchTime {
                            Text("Next pouch recommended: \(formattedTime(nextTime))")
                                .font(.caption2)
                                .foregroundColor(.blue)
                                .padding(.top, 2)
                        }
                    }
                }
                
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(.systemGray6))
            .onAppear {
                updateNicotineInfo()
            }
            .onChange(of: refreshTrigger) { _, _ in
                updateNicotineInfo()
                calculateNextPouchTime()
            }
            .onAppear {
                calculateNextPouchTime()
            }
        }
    }
    
    // MARK: - Helper Functions
    
    /**
     * Formats a Date as a time string (e.g., "3:45 PM")
     */
    private func formattedTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }
    
    /**
     * Calculates the recommended time for the next pouch based on reminder settings.
     * 
     * For time-based reminders:
     * - Calculates last pouch removal time + configured interval
     * 
     * For nicotine-level-based reminders:
     * - Projects when nicotine level will fall below the target range
     * - Uses NicotineCalculator to predict future levels
     */
    private func calculateNextPouchTime() {
        guard notificationSettings.reminderType != .disabled else {
            nextPouchTime = nil
            return
        }
        
        if notificationSettings.reminderType == .timeBased {
            // Time-based: last pouch + interval
            if let lastRemoved = vm.events
                .filter({ $0.removedAt < Date() })
                .max(by: { $0.removedAt < $1.removedAt })?.removedAt {
                let interval = notificationSettings.getEffectiveReminderInterval()
                nextPouchTime = lastRemoved.addingTimeInterval(interval)
            } else {
                // No previous pouches, suggest now
                nextPouchTime = Date()
            }
        } else {
            // Nicotine-level-based: project when level drops below range
            Task {
                let calculator = NicotineCalculator()
                let projection = await calculator.projectNicotineLevels(
                    context: viewContext,
                    settings: notificationSettings,
                    duration: 10 * 3600  // Look ahead 10 hours
                )
                
                await MainActor.run {
                    if let crossing = projection.lowBoundaryCrossing, crossing > Date() {
                        nextPouchTime = crossing
                    } else if projection.currentLevel < notificationSettings.nicotineRangeLow {
                        // Already below range, suggest now
                        nextPouchTime = Date()
                    } else {
                        nextPouchTime = nil
                    }
                }
            }
        }
    }
    
    /**
     * Updates nicotine level information for level-based reminders.
     * 
     * Calculates:
     * - Current total nicotine level from all sources
     * - Whether level is in target range
     * - Predictions for boundary crossings
     * - Decay rate information
     * 
     * This runs asynchronously to avoid blocking the UI during
     * complex calculations involving multiple pouches and decay curves.
     */
    private func updateNicotineInfo() {
        guard notificationSettings.reminderType == .nicotineLevelBased else { return }
        
        Task {
            let calculator = NicotineCalculator()
            let currentLevel = await calculator.calculateTotalNicotineLevel(context: viewContext)
            
            // Calculate estimated level after current pouch completes
            var estimatedAfterCurrent: Double? = nil
            if vm.hasActivePouch {
                // Get the active pouch details
                let request: NSFetchRequest<PouchLog> = PouchLog.fetchRequest()
                request.predicate = NSPredicate(format: "removalTime == nil")
                request.fetchLimit = 1
                
                if let activePouch = try? viewContext.fetch(request).first,
                   let insertionTime = activePouch.insertionTime {
                    // Calculate what the level will be when this pouch completes
                    let pouchDuration = TimeInterval(activePouch.timerDuration * 60) // Convert minutes to seconds
                    let completionTime = insertionTime.addingTimeInterval(pouchDuration)
                    estimatedAfterCurrent = await calculator.calculateTotalNicotineLevel(context: viewContext, at: completionTime)
                }
            }
            
            var predictionText: String? = nil
            
            if currentLevel < notificationSettings.nicotineRangeLow - notificationSettings.nicotineAlertThreshold {
                // Already below alert threshold, show immediate alert
                predictionText = "⚠️ Below alert threshold"
            } else if currentLevel > notificationSettings.nicotineRangeHigh + notificationSettings.nicotineAlertThreshold {
                // Already above alert threshold
                predictionText = "⚠️ Above alert threshold"  
            } else {
                // Get projection to find future boundary crossings
                let projection = await calculator.projectNicotineLevels(
                    context: viewContext,
                    settings: notificationSettings,
                    duration: 4 * 3600 // Project 4 hours ahead
                )
                
                // Check for predicted boundary crossings
                if let lowCrossing = projection.lowBoundaryCrossing {
                    let minutesUntil = Int(lowCrossing.timeIntervalSinceNow / 60)
                    if minutesUntil > 0 {
                        let hours = minutesUntil / 60
                        let mins = minutesUntil % 60
                        let timeText = hours > 0 ? "\(hours)h \(mins)m" : "\(mins)m"
                        predictionText = "Alert in ~\(timeText) (going below range)"
                    }
                } else if let highCrossing = projection.highBoundaryCrossing {
                    let minutesUntil = Int(highCrossing.timeIntervalSinceNow / 60)
                    if minutesUntil > 0 {
                        let hours = minutesUntil / 60
                        let mins = minutesUntil % 60
                        let timeText = hours > 0 ? "\(hours)h \(mins)m" : "\(mins)m"
                        predictionText = "Alert in ~\(timeText) (going above range)"
                    }
                } else if currentLevel >= notificationSettings.nicotineRangeLow && currentLevel <= notificationSettings.nicotineRangeHigh {
                    predictionText = "✓ Stable in target range"
                }
                
                // Show decay info if current level is significant but no alerts predicted
                if predictionText == nil && currentLevel > 0.1 {
                    let halfLife = 2.0 * 60 * 60 // 2 hours in seconds
                    let decayRate = currentLevel * 0.693 / halfLife * 60 // mg per minute
                    if decayRate > 0.001 {
                        predictionText = String(format: "Decaying at %.3f mg/min", decayRate)
                    }
                }
            }
            
            await MainActor.run {
                nicotineInfo = (currentLevel, predictionText, estimatedAfterCurrent)
            }
        }
    }
}

// MARK: - Hour Row Component

/**
 * HourRowView: Single row in the timeline representing one hour.
 * 
 * Layout:
 * - Hour label (e.g., "3PM") on the left
 * - Hour range title (e.g., "3:00 PM - 3:59 PM")
 * - Horizontal scroll of pouch cards or empty state
 * 
 * The horizontal scrolling allows multiple pouches per hour
 * without vertical space constraints.
 * 
 * - Parameter bucket: HourBucket containing hour info and events
 * - Parameter onEditPouch: Callback when a pouch card is tapped for editing
 */
private struct HourRowView: View {
    let bucket: HourBucket                         // Hour data and events
    let onEditPouch: (PouchEvent) -> Void         // Edit action handler

    // Static formatter for hour labels (reused for performance)
    private static let hourLabel: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "ha"
        f.amSymbol = "AM"
        f.pmSymbol = "PM"
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(Self.hourLabel.string(from: bucket.hourStart))
                .font(.headline)
                .frame(width: 54, alignment: .leading)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Text(hourTitle)
                    .font(.subheadline)
                    .foregroundColor(.primary)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        if bucket.events.isEmpty {
                            EmptyHourPill()
                        } else {
                            ForEach(bucket.events) { event in
                                PouchCard(event: event, onEdit: {
                                    onEditPouch(event)
                                })
                            }
                        }
                    }
                    .padding(.trailing, 12)  // Add trailing padding for scrolling
                }
                .frame(maxWidth: .infinity, alignment: .leading)  // ScrollView takes full width
            }
            .layoutPriority(1)  // Give VStack priority to expand
        }
        .padding(.vertical, 4)
    }

    private var hourTitle: String {
        let df = DateFormatter()
        df.dateFormat = "h:mm a"
        let endDate = Calendar.current.date(byAdding: .minute, value: 59, to: bucket.hourStart)
        let endString = df.string(from: endDate ?? bucket.hourStart)
        return "\(df.string(from: bucket.hourStart)) – \(endString)"
    }
}

// MARK: - Pouch Card Component

/**
 * PouchCard: Interactive card representing a single pouch usage event.
 * 
 * Visual design:
 * - Blue pill icon with white background
 * - Pouch name and strength
 * - Time and absorbed nicotine amount
 * - Subtle press animation for feedback
 * 
 * Interaction:
 * - Double tap to edit (primary action)
 * - Long press (0.8s) to edit (alternative)
 * - Visual feedback with scale animation
 * - Haptic feedback on activation
 * 
 * The card calculates absorbed nicotine based on the
 * standard absorption model (30% of total over 30 minutes).
 * 
 * - Parameter event: PouchEvent data to display
 * - Parameter onEdit: Callback when edit is triggered
 */
private struct PouchCard: View {
    let event: PouchEvent                          // Event data to display
    let onEdit: () -> Void                         // Edit action handler
    
    @State private var isPressed = false           // Tracks press state for animation

    // Static formatter for time display (reused for performance)
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    /**
     * Calculates the absorbed nicotine amount for this event.
     * 
     * Uses the standard absorption model:
     * - Maximum absorption = 30% of pouch nicotine content
     * - Assumes full absorption for completed pouches
     * 
     * This provides consistent display across the app.
     * 
     * - Returns: Absorbed nicotine in mg
     */
    private func absorbedAtEvent() -> Double {
        let maxAbsorbed = event.nicotineMg * ABSORPTION_FRACTION
        return maxAbsorbed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Title row
            HStack(spacing: 8) {
                Label {
                    Text(event.name)
                        .font(.subheadline)
                        .foregroundColor(.primary)
                } icon: {
                    Image(systemName: "pills.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .white)
                        .padding(6)
                        .background(Circle().fill(Color.blue))
                }
                .labelStyle(.titleAndIcon)
            }

            let timeString = Self.timeFormatter.string(from: event.removedAt)
            let absorbed = absorbedAtEvent()
            HStack(spacing: 4) {
                Text("\(timeString)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Text("•")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Text(String(format: "%.3f mg", absorbed))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(10)
        .frame(width: 150)  // Narrower fixed width for better fit
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(.secondarySystemBackground))
                .scaleEffect(isPressed ? 0.95 : 1.0)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(.separator), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            // Double tap to edit (temporary for debugging)
            print("🎯 Double tap triggered for pouch: \(event.name)")
            onEdit()
            
            // Haptic feedback
            let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
            impactFeedback.impactOccurred()
        }
        .onLongPressGesture(minimumDuration: 0.8, pressing: { isPressing in
            withAnimation(.easeInOut(duration: 0.1)) {
                self.isPressed = isPressing
            }
        }, perform: {
            // Trigger long press action
            print("🎯 Long press triggered for pouch: \(event.name)")
            onEdit()
            
            // Haptic feedback
            let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
            impactFeedback.impactOccurred()
        })
    }
}

/**
 * EmptyHourPill: Placeholder shown for hours with no pouch usage.
 * 
 * Provides visual consistency in the timeline by showing
 * a subtle "No pouches" indicator instead of empty space.
 * Uses tertiary fill color for minimal visual weight.
 */
private struct EmptyHourPill: View {
    var body: some View {
        Text("No pouches")
            .font(.caption)
            .foregroundColor(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(.tertiarySystemFill))
            )
    }
}
