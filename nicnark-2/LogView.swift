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
// Dummy sync state for older iOS versions
class DummySyncState: ObservableObject {
    @Published var isSyncing = false
    @Published var syncCompleted = true
    @Published var syncProgress: Double = 1.0
    @Published var syncMessage = "Ready"
    var isCloudKitEnabled = false
    
    func startInitialSync() async {
        // No-op for older iOS versions
    }
}

struct LogView: View {
    // MARK: - Core Data Properties
    // @Environment gets the database context from the SwiftUI environment
    @Environment(\.managedObjectContext) private var ctx
    
    // Track pouches currently being removed to prevent duplicate operations
    @State private static var pouchesBeingRemoved: Set<String> = []
    
    // MARK: - Timer Settings
    @StateObject private var timerSettings = TimerSettings.shared
    @AppStorage("autoRemovePouches") private var autoRemovePouches = false
    @AppStorage("hideLegacyButtons") private var hideLegacyButtons = false
    
    // MARK: - Can Inventory Properties
    @StateObject private var canManager = CanManager.shared
    @State private var showingAddCan = false
    @State private var showingCanSelection = false
    @State private var pendingPouchFromShortcut: PouchLog?
    @State private var showingBarcodeScanner = false
    @State private var scannedBarcode: String? = nil
    @State private var selectedCan: Can?
    @State private var showingEditCan = false
    @State private var canToEdit: Can?
    @State private var showingDuplicateCanAlert = false
    @State private var duplicateCanForAlert: Can?
    
    // Fetch active cans for display
    @FetchRequest(
        entity: Can.entity(),
        sortDescriptors: [
            NSSortDescriptor(keyPath: \Can.pouchCount, ascending: false),
            NSSortDescriptor(keyPath: \Can.dateAdded, ascending: false)
        ],
        predicate: NSPredicate(format: "pouchCount > 0")
    ) private var activeCans: FetchedResults<Can>

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
    
    // MARK: - CloudKit Sync State
    // We don't use @StateObject here as we're using the singleton directly

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
    // Timer duration is now dynamic based on user settings
    private var pouchDuration: TimeInterval {
        return timerSettings.currentTimerInterval
    }
    private let TIMER_INTERVAL: TimeInterval = 1.0              // Update UI every second

    var body: some View {
        ZStack {
            VStack(spacing: 20) {
                Text("Log a Pouch").font(.headline)

                if activePouches.isEmpty {
                    quickButtonsView
                    if showInput { customRowView }
                }

                if let pouch = activePouches.first { countdownPane(for: pouch) }
            }
            .padding()
            
            // Sync overlay - only shows when syncing and iCloud is enabled
            if #available(iOS 16.1, *) {
                if CloudKitSyncState.shared.isCloudKitEnabled && CloudKitSyncState.shared.isSyncing {
                    syncOverlay
                }
            }
        }
        .navigationTitle("NicNark")
        .navigationBarTitleDisplayMode(.large)
        .onAppear {
            cleanUpStale()
            if #available(iOS 16.1, *) {
                let authInfo = ActivityAuthorizationInfo()
                print("📱 Live Activities enabled: \(authInfo.areActivitiesEnabled)")
                
                // Start initial sync if needed
                Task {
                    if #available(iOS 16.1, *) {
                        await CloudKitSyncState.shared.startInitialSync()
                    }
                }
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
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("PouchRemoved"))) { notification in
            // Only handle notifications that come from external sources (like notification actions)
            // and contain a specific pouchId to avoid duplicate processing
            if let userInfo = notification.userInfo,
               let notificationPouchId = userInfo["pouchId"] as? String,
               let activePouch = activePouches.first {
                let activePouchId = activePouch.pouchId?.uuidString ?? activePouch.objectID.uriRepresentation().absoluteString
                // Only remove if the notification is for the current active pouch
                if notificationPouchId == activePouchId {
                    removePouch(activePouch)
                    WidgetCenter.shared.reloadAllTimelines()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("PouchLogged"))) { notification in
            // When a pouch is logged from anywhere (shortcuts, URL schemes, etc.), start the Live Activity timer
            startLiveTimerIfNeeded()
            // Also start the optimized timer for in-app updates
            if !activePouches.isEmpty {
                startOptimizedTimer()
            }
            
            // Check if this was from a shortcut and needs can association
            if let userInfo = notification.userInfo,
               let isFromShortcut = userInfo["isFromShortcut"] as? Bool,
               isFromShortcut,
               let pouchId = userInfo["pouchId"] as? String {
                // Find the pouch and show can selection
                if let pouch = activePouches.first(where: { $0.pouchId?.uuidString == pouchId }) {
                    pendingPouchFromShortcut = pouch
                    showingCanSelection = true
                }
            }
        }
        .sheet(isPresented: $showingAddCan) {
            CanDetailView(barcode: scannedBarcode)
                .environment(\.managedObjectContext, ctx)
                .onDisappear {
                    scannedBarcode = nil
                }
        }
        .sheet(isPresented: $showingEditCan) {
            if let can = canToEdit {
                CanDetailView(editingCan: can)
                    .environment(\.managedObjectContext, ctx)
            } else {
                // Fallback if can is nil (shouldn't happen)
                Text("Error: No can selected")
                    .onAppear {
                        showingEditCan = false
                    }
            }
        }
        .onChange(of: showingEditCan) { _, isShowing in
            if !isShowing {
                canToEdit = nil
                canManager.fetchActiveCans(context: ctx)
            }
        }
        .sheet(isPresented: $showingBarcodeScanner) {
            BarcodeScannerView { barcode in
                showingBarcodeScanner = false
                handleScannedBarcode(barcode)
            }
        }
        .sheet(isPresented: $showingCanSelection) {
            CanSelectionSheet(pendingPouch: pendingPouchFromShortcut) { selectedCan in
                if let pouch = pendingPouchFromShortcut {
                    canManager.associatePouchWithCan(pouch, can: selectedCan, context: ctx)
                }
                pendingPouchFromShortcut = nil
                showingCanSelection = false
            }
            .environment(\.managedObjectContext, ctx)
        }
        .onAppear {
            canManager.fetchActiveCans(context: ctx)
        }
        .alert("Can Already in Inventory", isPresented: $showingDuplicateCanAlert) {
            Button("Add Pouches to Existing Can") {
                if let can = duplicateCanForAlert {
                    // Add the full pouch count to the existing can
                    can.pouchCount += can.initialCount
                    do {
                        try ctx.save()
                        canManager.fetchActiveCans(context: ctx)
                    } catch {
                        print("Failed to update can count: \(error)")
                    }
                }
                duplicateCanForAlert = nil
            }
            Button("Add as Separate Can") {
                // Show add can screen to create a new can with the same barcode
                if let can = duplicateCanForAlert {
                    scannedBarcode = can.barcode
                    showingAddCan = true
                }
                duplicateCanForAlert = nil
            }
            Button("Cancel", role: .cancel) {
                duplicateCanForAlert = nil
            }
        } message: {
            if let can = duplicateCanForAlert {
                Text("\(can.brand ?? "Unknown") \(can.flavor ?? "") (\(Int(can.strength))mg) is already in your inventory with \(can.pouchCount) pouches. Would you like to add more pouches to this can or track it as a separate can?")
            }
        }
    }

    // MARK: - UI Components

    var quickButtonsView: some View {
        VStack(spacing: 16) {
            // Can inventory scroll view
            if !activeCans.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(activeCans, id: \.self) { can in
                            CanCardView(
                                can: can,
                                onSelect: {
                                    // Log pouch from this can
                                    logPouchFromCan(can)
                                },
                                onEdit: {
                                    // Edit this can
                                    canToEdit = can
                                    // Small delay to ensure canToEdit is set before sheet presents
                                    DispatchQueue.main.async {
                                        showingEditCan = true
                                    }
                                }
                            )
                        }
                    }
                    .padding(.horizontal)
                }
                .frame(height: 200)
            } else {
                // Empty state - no cans
                VStack(spacing: 12) {
                    Image(systemName: "tray")
                        .font(.system(size: 48))
                        .foregroundColor(.gray)
                    
                    Text("No cans in inventory")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    
                    Text("Add a can to start tracking")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(height: 180)
                .frame(maxWidth: .infinity)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)
                .padding(.horizontal)
            }
            
            // Add can and manual log buttons
            HStack(spacing: 12) {
                Button(action: {
                    showingAddCan = true
                }) {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                        Text("Add Can")
                    }
                }
                .buttonStyle(.borderedProminent)
                .frame(height: 44)
                
                Button(action: {
                    showInput.toggle()
                }) {
                    HStack {
                        Image(systemName: "number")
                        Text("Manual Log")
                    }
                }
                .buttonStyle(.bordered)
                .frame(height: 44)
            }
            .padding(.horizontal)
            
            // Scan Can button
            Button(action: {
                showingBarcodeScanner = true
            }) {
                HStack {
                    Image(systemName: "barcode.viewfinder")
                    Text("Scan Can")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .frame(height: 44)
            .padding(.horizontal)
            
            // Legacy custom buttons for backward compatibility
            if !customButtons.isEmpty && !hideLegacyButtons {
                Divider()
                    .padding(.horizontal)
                
                Text("Quick Add (Legacy)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                HStack(spacing: 8) {
                    ForEach(customButtons, id: \.self) { button in
                        Button("\(button.nicotineAmount, specifier: "%.0f") mg") {
                            logPouch(button.nicotineAmount)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .contextMenu {
                            Button(role: .destructive) {
                                deleteCustomButton(button)
                            } label: {
                                Label("Delete Button", systemImage: "trash")
                            }
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
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
        // Use the pouch's specific duration (stored in minutes, convert to seconds)
        let actualDuration = TimeInterval(pouch.timerDuration * 60)
        // Ensure remaining time never shows more than the pouch's duration
        let remaining = max(min(actualDuration - elapsed, actualDuration), 0)
        let progress = min(max(elapsed / actualDuration, 0), 1)
        let isCompleted = remaining == 0

        let currentAbsorption = AbsorptionConstants.shared
            .calculateCurrentNicotineLevel(nicotineContent: pouch.nicotineAmount, elapsedTime: elapsed)
        let maxPossibleAbsorption = AbsorptionConstants.shared
            .calculateAbsorbedNicotine(nicotineContent: pouch.nicotineAmount, useTime: actualDuration)
        let absorptionProgress = maxPossibleAbsorption > 0 ? currentAbsorption / maxPossibleAbsorption : 0

        VStack(spacing: 12) {
            Button("Remove Pouch") { 
                removePouch(pouch) 
            }
            .buttonStyle(.borderedProminent)
            .disabled(shouldDisableRemoveButton)
            .opacity(shouldDisableRemoveButton ? 0.6 : 1.0)

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
    
    func handleScannedBarcode(_ barcode: String) {
        // Check if there's an active can with this barcode in inventory
        if let activeCan = canManager.findActiveCanByBarcode(barcode, context: ctx) {
            // Can exists with pouches, show dialog to ask user what to do
            duplicateCanForAlert = activeCan
            showingDuplicateCanAlert = true
        } else {
            // Either no can exists or can is empty
            // Show add can screen with barcode and any template data pre-filled
            scannedBarcode = barcode
            showingAddCan = true
        }
    }

    func logPouch(_ mg: Double) {
        LogService.logPouch(amount: mg, ctx: ctx)
        startLiveTimerIfNeeded()
        
        // Update widget persistence helper immediately after logging
        updateWidgetPersistenceHelper()
    }
    
    func logPouchFromCan(_ can: Can) {
        guard can.pouchCount > 0 else { return }
        
        // Log the pouch with can association
        let success = canManager.logPouchFromCan(
            can: can,
            amount: can.strength,
            context: ctx
        )
        
        if success {
            startLiveTimerIfNeeded()
            updateWidgetPersistenceHelper()
            
            // Refresh can list to update counts
            canManager.fetchActiveCans(context: ctx)
        }
    }

    func removePouch(_ pouch: PouchLog) {
        let pouchId = pouch.pouchId?.uuidString ?? pouch.objectID.uriRepresentation().absoluteString
        
        // Idempotent guard: prevent duplicate removal operations
        guard !LogView.pouchesBeingRemoved.contains(pouchId) else {
            print("⚠️ Pouch removal already in progress for: \(pouchId)")
            return
        }
        
        // Mark as being removed
        LogView.pouchesBeingRemoved.insert(pouchId)
        defer {
            LogView.pouchesBeingRemoved.remove(pouchId)
        }
        
        // CRITICAL: End Live Activity FIRST before marking as removed in Core Data
        // This prevents background tasks from seeing an inactive pouch and creating a new activity
        Task { @MainActor in
            // End the Live Activity immediately
            if #available(iOS 16.1, *) {
                await LiveActivityManager.endLiveActivity(for: pouchId)
            }
            
            // Stop timers immediately to prevent any further updates
            liveTimer?.invalidate()
            liveTimer = nil
            stopOptimizedTimer()
            
            // Now mark as removed in Core Data
            let removalTime = Date.now
            pouch.removalTime = removalTime
            
            // NOTE: We do NOT restore the pouch to the can here.
            // Pouches are only restored when deleted from usage log, not when marked as complete.
            
            try? ctx.save()
            
            // Cancel notifications
            NotificationManager.cancelAlert(id: pouchId)
            
            // Refresh can list to show updated counts
            canManager.fetchActiveCans(context: ctx)
            
            // Update widget persistence helper with the actual removal time
            updateWidgetPersistenceHelperForRemoval(pouch: pouch, removalTime: removalTime)
            
            WidgetCenter.shared.reloadAllTimelines()
        }
        // Note: PouchRemoved notification is only posted by NotificationManager for external removals
    }
    
    func deleteCustomButton(_ button: CustomButton) {
        // Delete the custom button from Core Data
        ctx.delete(button)
        
        do {
            try ctx.save()
            print("✅ Deleted custom button: \(button.nicotineAmount)mg")
        } catch {
            print("❌ Failed to delete custom button: \(error)")
        }
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

        // Use the pouch's specific duration (stored in minutes, convert to seconds)
        let actualDuration = TimeInterval(pouch.timerDuration * 60)
        let elapsed = Date().timeIntervalSince(insertionTime)
        let remaining = max(actualDuration - elapsed, 0)
        let progress = min(max(elapsed / actualDuration, 0), 1)

        let currentLevel = AbsorptionConstants.shared.calculateCurrentNicotineLevel(
            nicotineContent: pouch.nicotineAmount,
            elapsedTime: elapsed
        )

        let pouchId = pouch.pouchId?.uuidString ?? pouch.objectID.uriRepresentation().absoluteString
        
        // Update Live Activity with accurate timer interval based on current pouch data
        let endTime = insertionTime.addingTimeInterval(actualDuration)
        let timerInterval = insertionTime...endTime
        
        await LiveActivityManager.updateLiveActivity(
            for: pouchId,
            timerInterval: timerInterval,
            absorptionProgress: progress,
            currentNicotineLevel: currentLevel
        )

        if remaining == 0 {
            endLiveActivityIfNeeded(for: pouch)
            
            // Auto-remove if enabled
            if autoRemovePouches {
                Task { @MainActor in
                    // Wait a moment for the user to see completion
                    try? await Task.sleep(nanoseconds: 1 * NSEC_PER_SEC)
                    removePouch(pouch)
                    print("🔄 Auto-removed completed pouch")
                }
            }
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
        let remaining = max(pouchDuration - elapsed, 0)
        let isCompleted = remaining == 0
        
        // Auto-remove if enabled and just completed
        if isCompleted && autoRemovePouches && !LogView.pouchesBeingRemoved.contains(
            pouch.pouchId?.uuidString ?? pouch.objectID.uriRepresentation().absoluteString
        ) {
            Task { @MainActor in
                removePouch(pouch)
                print("🔄 Auto-removed completed pouch from timer check")
            }
        }
        
        return isCompleted
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
            let endTime = activePouches.first?.insertionTime?.addingTimeInterval(pouchDuration)
            
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
    
    // MARK: - Sync Overlay
    
    @available(iOS 16.1, *)
    private var syncOverlay: some View {
        let syncState = CloudKitSyncState.shared
        return ZStack {
            // Background blur
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .transition(.opacity)
            
            // Sync status card
            VStack(spacing: 20) {
                // Icon or progress indicator
                if syncState.syncCompleted {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.green)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    ProgressView()
                        .scaleEffect(1.5)
                        .progressViewStyle(CircularProgressViewStyle(tint: .blue))
                }
                
                // Status text
                Text(syncState.syncCompleted ? "Sync Complete" : syncState.syncMessage)
                    .font(.headline)
                    .foregroundColor(.primary)
                
                // Progress bar
                if !syncState.syncCompleted {
                    ProgressView(value: syncState.syncProgress)
                        .frame(width: 200)
                        .progressViewStyle(.linear)
                        .tint(.blue)
                }
                
                // Additional info text
                if !syncState.syncCompleted {
                    Text("Please wait while we sync with your other devices")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 250)
                }
            }
            .padding(30)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(.regularMaterial)
                    .shadow(radius: 10)
            )
            .scaleEffect(syncState.syncCompleted ? 1.05 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: syncState.syncCompleted)
        }
    }
    
    // MARK: - Computed Properties
    
    private var shouldDisableRemoveButton: Bool {
        if #available(iOS 16.1, *) {
            // Disable button if CloudKit is enabled and we haven't completed initial sync
            return CloudKitSyncState.shared.isCloudKitEnabled && !CloudKitSyncState.shared.syncCompleted
        }
        return false
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
