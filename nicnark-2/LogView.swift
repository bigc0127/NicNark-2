//
// LogView.swift
// nicnark-2
//
// The main view where users log nicotine pouches and see countdown timers
// Uses LogService so UI/Shortcuts/URL share the same flow.
//

// Import necessary frameworks
import SwiftUI      // For building the user interface
import CoreData     // For database operations
import WidgetKit    // For updating home screen widgets
import ActivityKit  // For Live Activities (Dynamic Island & Lock Screen)
import Combine      // For handling data streams and notifications

/**
 * LogView: The primary interface for logging nicotine pouches
 * This view handles:
 * - Displaying quick buttons for common nicotine amounts (3mg, 6mg, custom amounts)
 * - Showing active pouch countdown with absorption progress
 * - Managing Live Activities for Lock Screen/Dynamic Island display
 * - Real-time timer updates and nicotine calculation
 */
struct LogView: View {
    // MARK: - Core Data Properties
    // @Environment gets the database context from the SwiftUI environment
    @Environment(\.managedObjectContext) private var ctx

    // @FetchRequest automatically fetches data from Core Data and updates the view when data changes
    // This fetches all custom nicotine amount buttons, sorted by amount (3mg, 6mg, 9mg, etc.)
    @FetchRequest(
        entity: CustomButton.entity(),
        sortDescriptors: [NSSortDescriptor(keyPath: \CustomButton.nicotineAmount, ascending: true)]
    ) private var customButtons: FetchedResults<CustomButton>

    // This fetches active pouches (ones that haven't been removed yet)
    // Sorted by insertion time (newest first), filtered to only show active pouches
    @FetchRequest(
        entity: PouchLog.entity(),
        sortDescriptors: [NSSortDescriptor(keyPath: \PouchLog.insertionTime, ascending: false)],
        predicate: NSPredicate(format: "removalTime == nil")  // Only pouches still in mouth
    ) private var activePouches: FetchedResults<PouchLog>

    // MARK: - UI State Properties
    // @State creates local state that the view owns and can modify
    @State private var showInput = false           // Whether to show the custom amount input field
    @State private var input = ""                  // Text in the custom amount input field
    @State private var tick = Date()               // Current time, updated every second for countdown
    @State private var lastWidgetUpdate = Date()   // Last time we updated home screen widgets
    @State private var lastLiveActivityUpdate = Date() // Last time we updated Live Activities

    // MARK: - Timer Properties
    // Timer for updating Live Activities (runs every minute, less battery intensive)
    @State private var liveTimer: Timer?
    
    // Timer for in-app UI updates (runs every second for smooth countdown)
    @State private var optimizedTimer: Timer?
    
    // MARK: - Constants
    private let DEFAULT_POUCH_DURATION: TimeInterval = 30 * 60  // 30 minutes in seconds
    private let TIMER_INTERVAL: TimeInterval = 1.0              // Update UI every second

    var body: some View {
        VStack(spacing: 20) {
            Text("Log a Pouch").font(.headline)

            if activePouches.isEmpty {
                quickButtonsView
                if showInput { customRowView }
            }

            if let pouch = activePouches.first { countdownPane(for: pouch) }
        }
        .padding()
        .navigationTitle("NicNark")
        .navigationBarTitleDisplayMode(.large)
        .onAppear {
            cleanUpStale()
            if #available(iOS 16.1, *) {
                let authInfo = ActivityAuthorizationInfo()
                print("📱 Live Activities enabled: \(authInfo.areActivitiesEnabled)")
            }
            WidgetCenter.shared.reloadAllTimelines()
        }
        .onChange(of: activePouches.isEmpty) { _, isEmpty in
            if isEmpty {
                stopOptimizedTimer()
            } else {
                startOptimizedTimer()
            }
        }
        .onAppear {
            if !activePouches.isEmpty {
                startOptimizedTimer()
            }
        }
        .onDisappear {
            stopOptimizedTimer()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("RemovePouchFromNotification"))) { _ in
            if let activePouch = activePouches.first {
                removePouch(activePouch)
                WidgetCenter.shared.reloadAllTimelines()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("PouchLogged"))) { _ in
            // When a pouch is logged from anywhere (shortcuts, URL schemes, etc.), start the Live Activity timer
            startLiveTimerIfNeeded()
            // Also start the optimized timer for in-app updates
            if !activePouches.isEmpty {
                startOptimizedTimer()
            }
        }
    }

    // MARK: - UI Components

    var quickButtonsView: some View {
        VStack(spacing: 12) {
            // Centered layout using HStack with Spacers for proper centering
            HStack(spacing: 8) {
                Spacer() // Push buttons to center
                
                Button("3 mg") { logPouch(3) }
                    .buttonStyle(.bordered)
                    .frame(height: 44)
                
                Button("6 mg") { logPouch(6) }
                    .buttonStyle(.bordered)
                    .frame(height: 44)

                ForEach(customButtons, id: \.self) { button in
                    Button("\(button.nicotineAmount, specifier: "%.0f") mg") {
                        logPouch(button.nicotineAmount)
                    }
                    .buttonStyle(.bordered)
                    .frame(height: 44)
                }
                
                Spacer() // Push buttons to center
            }
            
            // Separate "Custom" button that's wider and centered
            HStack {
                Spacer()
                Button("Custom") { showInput.toggle() }
                    .buttonStyle(.borderedProminent)
                    .frame(height: 44)
                    .frame(minWidth: 120) // Ensure "Custom" text is fully visible
                Spacer()
            }
        }
        .padding(.horizontal)
    }

    var customRowView: some View {
        HStack {
            TextField("Enter mg", text: $input)
                .keyboardType(.decimalPad)
                .textFieldStyle(.roundedBorder)
                .frame(width: 90)

            Button("Save") {
                guard let mg = Double(input), mg > 0 else { return }
                LogService.ensureCustomButton(for: mg, in: ctx)
                try? ctx.save()
                input = ""
                showInput = false
                WidgetCenter.shared.reloadAllTimelines()
            }
            .buttonStyle(.borderedProminent)

            Button("Cancel") {
                input = ""
                showInput = false
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: – Countdown Display

    @ViewBuilder
    func countdownPane(for pouch: PouchLog) -> some View {
        let insertionTime = pouch.insertionTime ?? tick
        let elapsed = max(0, tick.timeIntervalSince(insertionTime))
        // Ensure remaining time never shows more than the default duration
        let remaining = max(min(DEFAULT_POUCH_DURATION - elapsed, DEFAULT_POUCH_DURATION), 0)
        let progress = min(max(elapsed / DEFAULT_POUCH_DURATION, 0), 1)
        let isCompleted = remaining == 0

        let currentAbsorption = AbsorptionConstants.shared
            .calculateCurrentNicotineLevel(nicotineContent: pouch.nicotineAmount, elapsedTime: elapsed)
        let maxPossibleAbsorption = AbsorptionConstants.shared
            .calculateAbsorbedNicotine(nicotineContent: pouch.nicotineAmount, useTime: DEFAULT_POUCH_DURATION)
        let absorptionProgress = maxPossibleAbsorption > 0 ? currentAbsorption / maxPossibleAbsorption : 0

        VStack(spacing: 12) {
            Button("Remove Pouch") { removePouch(pouch) }.buttonStyle(.borderedProminent)

            Text(isCompleted ? "Timer Complete" : "Live Timer").font(.headline)

            Text(isCompleted ? "Complete!" : formatMinutesSeconds(remaining))
                .font(.system(size: 32, weight: .bold, design: .monospaced))
                .foregroundColor(isCompleted ? .green : .blue)

            Text("Time in: \(formatHoursMinutesSeconds(elapsed))")
                .font(.caption).foregroundColor(.secondary)

            ProgressView(value: progress).scaleEffect(y: 2)

            Text("Absorbed: \(String(format: "%.3f", currentAbsorption)) mg (\(Int(absorptionProgress * 100))%)")
                .font(.caption).foregroundColor(.secondary)

            if isCompleted {
                Text("Ready to remove!")
                    .font(.caption)
                    .foregroundColor(.green)
                    .fontWeight(.semibold)
            }
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(12)
    }

    // MARK: – CRUD Operations

    func logPouch(_ mg: Double) {
        LogService.logPouch(amount: mg, ctx: ctx)
        startLiveTimerIfNeeded()
        
        // Update widget persistence helper immediately after logging
        updateWidgetPersistenceHelper()
    }

    func removePouch(_ pouch: PouchLog) {
        let removalTime = Date.now
        pouch.removalTime = removalTime
        try? ctx.save()
        endLiveActivityIfNeeded(for: pouch)

        let pouchId = pouch.pouchId?.uuidString ?? pouch.objectID.uriRepresentation().absoluteString
        NotificationManager.cancelAlert(id: pouchId)
        
        // Update widget persistence helper with the actual removal time
        updateWidgetPersistenceHelperForRemoval(pouch: pouch, removalTime: removalTime)
        
        WidgetCenter.shared.reloadAllTimelines()
        NotificationCenter.default.post(name: NSNotification.Name("PouchRemoved"), object: nil)
    }

    // MARK: – Live Activity tick (UI refresh loop)

    private func startLiveTimerIfNeeded() {
        liveTimer?.invalidate()
        liveTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in 
            Task { @MainActor in
                await self.updateLiveActivityTick()
            }
        }
        if let t = liveTimer { RunLoop.main.add(t, forMode: .common) }
    }

    private func endLiveActivityIfNeeded(for pouch: PouchLog) {
        guard #available(iOS 16.1, *) else { return }
        liveTimer?.invalidate()
        liveTimer = nil
        let pouchId = pouch.pouchId?.uuidString ?? pouch.objectID.uriRepresentation().absoluteString
        Task {
            await LiveActivityManager.endLiveActivity(for: pouchId)
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    private func updateLiveActivityTick() async {
        guard #available(iOS 16.1, *) else { return }
        guard let pouch = activePouches.first,
              let insertionTime = pouch.insertionTime else { return }

        let elapsed = Date().timeIntervalSince(insertionTime)
        let remaining = max(DEFAULT_POUCH_DURATION - elapsed, 0)
        let progress = min(max(elapsed / DEFAULT_POUCH_DURATION, 0), 1)

        let currentLevel = AbsorptionConstants.shared.calculateCurrentNicotineLevel(
            nicotineContent: pouch.nicotineAmount,
            elapsedTime: elapsed
        )

        let pouchId = pouch.pouchId?.uuidString ?? pouch.objectID.uriRepresentation().absoluteString
        
        // Update Live Activity with accurate timer interval based on current pouch data
        let endTime = insertionTime.addingTimeInterval(DEFAULT_POUCH_DURATION)
        let timerInterval = insertionTime...endTime
        
        await LiveActivityManager.updateLiveActivity(
            for: pouchId,
            timerInterval: timerInterval,
            absorptionProgress: progress,
            currentNicotineLevel: currentLevel
        )

        if remaining == 0 {
            endLiveActivityIfNeeded(for: pouch)
        } else {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    private func updateLiveActivityTickIfNeeded() async {
        let now = Date()
        let timeSinceLastLiveActivityUpdate = now.timeIntervalSince(lastLiveActivityUpdate)
        
        // Only update Live Activity every 15 seconds or when pouch completes
        // More frequent updates ensure numeric text stays current
        let shouldUpdateLiveActivity = timeSinceLastLiveActivityUpdate >= 15 || checkIfPouchCompleted()
        
        if shouldUpdateLiveActivity {
            await updateLiveActivityTick()
            lastLiveActivityUpdate = now
        }
    }

    // MARK: – Optimized Timer Management
    
    private func startOptimizedTimer() {
        stopOptimizedTimer() // Ensure no duplicate timers
        optimizedTimer = Timer.scheduledTimer(withTimeInterval: TIMER_INTERVAL, repeats: true) { _ in
            Task { @MainActor in
                self.tick = Date()
                // Update Live Activity less frequently to save battery
                await self.updateLiveActivityTickIfNeeded()
                // Only reload widgets when UI actually changes or every 2 minutes
                self.smartWidgetReload()
            }
        }
        if let timer = optimizedTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }
    
    private func stopOptimizedTimer() {
        optimizedTimer?.invalidate()
        optimizedTimer = nil
    }
    
    // MARK: – Helpers
    
    private func smartWidgetReload() {
        let now = Date()
        let timeSinceLastUpdate = now.timeIntervalSince(lastWidgetUpdate)
        
        // Only update widgets if:
        // 1. It's been more than 2 minutes since last update (reduces battery drain)
        // 2. OR if the pouch just completed (remaining time hit 0)
        let shouldUpdate = timeSinceLastUpdate >= 120 || checkIfPouchCompleted()
        
        if shouldUpdate {
            WidgetCenter.shared.reloadAllTimelines()
            lastWidgetUpdate = now
        }
    }
    
    private func checkIfPouchCompleted() -> Bool {
        guard let pouch = activePouches.first,
              let insertionTime = pouch.insertionTime else { return false }
        let elapsed = Date().timeIntervalSince(insertionTime)
        let remaining = max(DEFAULT_POUCH_DURATION - elapsed, 0)
        return remaining == 0
    }

    func throttledWidgetReload(at now: Date) {
        if now.timeIntervalSince(lastWidgetUpdate) >= 30 {
            WidgetCenter.shared.reloadAllTimelines()
            lastWidgetUpdate = now
        }
    }

    func formatHoursMinutesSeconds(_ timeInterval: TimeInterval) -> String {
        let seconds = Int(max(timeInterval, 0))
        return String(format: "%02d:%02d:%02d", seconds/3_600, (seconds%3_600)/60, seconds%60)
    }

    func formatMinutesSeconds(_ timeInterval: TimeInterval) -> String {
        let seconds = Int(max(timeInterval, 0))
        return String(format: "%02d:%02d", seconds/60, seconds%60)
    }

    func cleanUpStale() {
        let request = PouchLog.fetchRequest()
        request.predicate = NSPredicate(format:"removalTime == nil AND insertionTime < %@", Date(timeIntervalSinceNow: -1800) as CVarArg)
        if let logs = try? ctx.fetch(request) {
            logs.forEach(removePouch)
        }
    }
    
    // MARK: - Widget Persistence Helper Update
    
    private func updateWidgetPersistenceHelper() {
        let helper = WidgetPersistenceHelper()
        
        // Check if there are any active pouches
        if activePouches.isEmpty {
            // No active pouches, mark activity as ended
            helper.markActivityEnded()
        } else {
            // Calculate current nicotine levels for active pouches
            let currentLevel = calculateCurrentTotalNicotineLevel()
            let pouchName = "\(activePouches.count) active pouch\(activePouches.count > 1 ? "es" : "")"
            let endTime = activePouches.first?.insertionTime?.addingTimeInterval(DEFAULT_POUCH_DURATION)
            
            // Update the persistence helper with current data
            helper.setFromLiveActivity(
                level: currentLevel,
                peak: currentLevel, // Use current as peak for simplicity in widget
                pouchName: pouchName,
                endTime: endTime
            )
        }
    }
    
    private func calculateCurrentTotalNicotineLevel() -> Double {
        let now = Date()
        var totalLevel = 0.0
        
        for pouch in activePouches {
            guard let insertionTime = pouch.insertionTime else { continue }
            let elapsed = now.timeIntervalSince(insertionTime)
            
            let currentContribution = AbsorptionConstants.shared.calculateCurrentNicotineLevel(
                nicotineContent: pouch.nicotineAmount,
                elapsedTime: elapsed
            )
            totalLevel += currentContribution
        }
        
        return totalLevel
    }
    
    // MARK: - Special handling for removal to sync with widget
    private func updateWidgetPersistenceHelperForRemoval(pouch: PouchLog, removalTime: Date) {
        let helper = WidgetPersistenceHelper()
        
        guard let insertionTime = pouch.insertionTime else {
            helper.markActivityEnded()
            return
        }
        
        // Calculate the actual absorbed amount based on actual time in mouth
        let actualTimeInMouth = removalTime.timeIntervalSince(insertionTime)
        let actualAbsorbed = AbsorptionConstants.shared.calculateAbsorbedNicotine(
            nicotineContent: pouch.nicotineAmount,
            useTime: actualTimeInMouth
        )
        
        // Update widget with the actual absorbed amount and removal time
        // This ensures widget shows the same level as main app
        helper.setFromLiveActivity(
            level: actualAbsorbed,
            peak: actualAbsorbed,
            pouchName: "Pouch removed",
            endTime: removalTime  // Use actual removal time, not theoretical end time
        )
        
        // After a brief delay, mark as ended since pouch is removed
        Task {
            try? await Task.sleep(nanoseconds: 1 * NSEC_PER_SEC)
            helper.markActivityEnded()
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}

#Preview {
    LogView()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
}
