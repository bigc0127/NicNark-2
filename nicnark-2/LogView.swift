//
// LogView.swift
// nicnark-2
//
// The Primary Pouch Logging Interface
//
// This is the main tab users see when opening the app. It handles:
// • Displaying can inventory as horizontal scrollable cards
// • Quick pouch logging from tracked cans (one tap to log and decrement inventory)
// • Manual dosage entry for custom amounts
// • Live countdown display with absorption progress and nicotine level calculations
// • Real-time timer updates that sync across widgets, Live Activities, and in-app UI
// • CloudKit sync status indicators
// • Barcode scanning for adding new cans to inventory
//
// All logging operations use LogService for consistency across UI, Shortcuts, and URL schemes.
//

// Import necessary frameworks
import SwiftUI      // For building the user interface
import CoreData     // For database operations
import WidgetKit    // For updating home screen widgets
import ActivityKit  // For Live Activities (Dynamic Island & Lock Screen)
import Combine      // For handling data streams and notifications

/**
 * LogView: The main pouch logging interface that users see when they open the app.
 * 
 * This SwiftUI view is designed around the core user workflow:
 * 1. User has cans in their inventory (shown as horizontal scrollable cards)
 * 2. User taps a can to log a pouch from it (automatically decrements inventory)
 * 3. A live countdown begins showing absorption progress and current nicotine level
 * 4. Timer updates propagate to widgets, Live Activities, and other devices via CloudKit
 * 
 * The view handles multiple input methods:
 * • Can inventory cards (primary method) - one tap logging with automatic inventory tracking
 * • Manual entry - custom dosage amounts for users who don't track cans
 * • Barcode scanning - quick way to add new cans to inventory
 * • Legacy custom buttons - backward compatibility for existing users
 * 
 * Real-time features:
 * • In-app countdown timer (updates every second for smooth progress bars)
 * • Live Activity updates (every minute to preserve battery)
 * • Widget timeline updates (triggered on pouch events)
 * • CloudKit sync status overlay (shows when syncing across devices)
 */
/**
 * DummySyncState: Fallback sync state for iOS versions that don't support CloudKit sync features.
 * 
 * On iOS 16.1+, the app uses CloudKitSyncState for real sync monitoring.
 * On older iOS versions, this dummy class provides the same interface but with no-op implementations.
 * This allows the UI code to work consistently across iOS versions without #available checks everywhere.
 */
class DummySyncState: ObservableObject {
    @Published var isSyncing = false        // Always false - no real syncing on older iOS
    @Published var syncCompleted = true     // Always true - simulates completed state
    @Published var syncProgress: Double = 1.0  // Always 100% complete
    @Published var syncMessage = "Ready"    // Static ready message
    var isCloudKitEnabled = false           // CloudKit features not available
    
    func startInitialSync() async {
        // No-op for older iOS versions - no actual sync performed
    }
}

struct LogView: View {
    // MARK: - Core Data Properties
    // @Environment gets values from the SwiftUI environment that are shared across views
    @Environment(\.managedObjectContext) private var ctx  // Database context for all Core Data operations
    
    // Static set to track pouches being removed across all view instances to prevent race conditions
    // When multiple parts of the app try to remove the same pouch simultaneously (notifications, UI, etc.)
    @State private static var pouchesBeingRemoved: Set<String> = []
    
    // MARK: - User Settings & Preferences
    @StateObject private var timerSettings = TimerSettings.shared  // Global timer settings (30min default, custom durations)
    @AppStorage("autoRemovePouches") private var autoRemovePouches = false    // Auto-remove pouches when timer ends
    @AppStorage("autoRemoveDelayMinutes") private var autoRemoveDelayMinutes: Double = 0  // Delay before auto-removing (0 = immediate)
    @AppStorage("hideLegacyButtons") private var hideLegacyButtons = false    // Hide old-style quick buttons
    
    // MARK: - Can Inventory Management
    @StateObject private var canManager = CanManager.shared           // Singleton for managing can inventory
    @State private var loadedPouches: [UUID: Int] = [:]              // Track loaded pouches per can (canID -> count)
    @State private var showingAddCan = false                          // Controls "Add Can" sheet presentation
    @State private var showingBarcodeScanner = false                  // Barcode scanner sheet presentation
    @State private var scannedBarcode: String? = nil                  // Temporarily holds scanned barcode data
    @State private var selectedCan: Can?                              // Currently selected can for operations
    @State private var showingEditCan = false                         // Edit can details sheet
    @State private var canToEdit: Can?                                // Can being edited
    @State private var showingDuplicateCanAlert = false               // Alert when scanning duplicate barcodes
    @State private var duplicateCanForAlert: Can?                     // The duplicate can found
    @State private var selectedBrand: String? = nil                   // Currently selected brand filter
    
    // MARK: - Core Data Fetch Requests
    // @FetchRequest automatically fetches data and updates the UI when the data changes
    
    /// Fetches all cans that have pouches OR have active timers running.
    /// This ensures cans with active pouches remain visible even when inventory reaches zero.
    /// Sorted by pouch count (fullest first), then by date added (newest first).
    /// This creates the horizontal scrollable can cards at the top of the screen.
    @FetchRequest(
        entity: Can.entity(),
        sortDescriptors: [
            NSSortDescriptor(keyPath: \Can.pouchCount, ascending: false),  // Fullest cans first
            NSSortDescriptor(keyPath: \Can.dateAdded, ascending: false)    // Then newest first
        ],
        predicate: NSPredicate(format: "pouchCount > 0 OR (ANY pouchLogs.removalTime == nil)")  // Show cans with pouches OR active timers
    ) private var activeCans: FetchedResults<Can>

    /// Fetches user-created custom dosage buttons (e.g., 4mg, 8mg, 12mg).
    /// These are created automatically when users log non-standard amounts.
    /// Sorted by nicotine amount (3mg, 4mg, 6mg, 8mg, etc.)
    /// Used for the "Legacy Quick Add" section for backward compatibility.
    @FetchRequest(
        entity: CustomButton.entity(),
        sortDescriptors: [NSSortDescriptor(keyPath: \CustomButton.nicotineAmount, ascending: true)]  // Lowest to highest
    ) private var customButtons: FetchedResults<CustomButton>

    /// Fetches pouches currently being used (removalTime == nil).
    /// The app only allows one active pouch at a time, so this should contain 0 or 1 items.
    /// When a pouch exists here, the countdown timer UI is displayed.
    /// Sorted by insertion time (newest first, though only one should exist).
    @FetchRequest(
        entity: PouchLog.entity(),
        sortDescriptors: [NSSortDescriptor(keyPath: \PouchLog.insertionTime, ascending: false)],
        predicate: NSPredicate(format: "removalTime == nil")  // Only active pouches (still in use)
    ) private var activePouches: FetchedResults<PouchLog>
    
    // MARK: - UI State Properties
    // @State creates local view state that persists across view updates
    @State private var showInput = false           // Toggle for manual dosage entry text field
    @State private var input = ""                  // User's typed dosage amount (e.g., "4.5")
    @State private var tick = Date()               // Current timestamp, updated by timer for real-time calculations
    @State private var lastWidgetUpdate = Date()   // Throttle widget updates (expensive operation)
    @State private var lastLiveActivityUpdate = Date() // Throttle Live Activity updates (battery optimization)

    // MARK: - Timer Management
    /// Timer for updating Live Activities and widgets (runs less frequently to save battery)
    /// Fires every minute to keep Lock Screen and home screen widgets updated
    @State private var liveTimer: Timer?
    
    /// Timer for in-app UI updates (runs every second for smooth countdown animations)
    /// Only active when the app is in the foreground and there's an active pouch
    @State private var optimizedTimer: Timer?
    
    // MARK: - Computed Properties
    /// Returns the current timer duration based on user settings.
    /// Can be 30 minutes (default) or custom duration set in TimerSettings.
    private var pouchDuration: TimeInterval {
        return timerSettings.currentTimerInterval
    }
    /// How often to update the in-app countdown display (1 second for smooth progress)
    private let TIMER_INTERVAL: TimeInterval = 1.0
    
    // MARK: - Multi-Pouch Loading Computed Properties
    
    /// Total number of pouches loaded across all cans
    private var totalLoadedPouches: Int {
        loadedPouches.values.reduce(0, +)
    }
    
    /// Total nicotine from all loaded pouches
    private var totalNicotine: Double {
        activeCans.reduce(0.0) { total, can in
            guard let canId = can.id, let count = loadedPouches[canId], count > 0 else { return total }
            return total + (can.strength * Double(count))
        }
    }
    
    /// Estimated total nicotine absorption (30% of total nicotine)
    private var estimatedTotalAbsorption: Double {
        return totalNicotine * ABSORPTION_FRACTION
    }
    
    /// Whether the Start Timer button should be enabled
    private var canStartTimer: Bool {
        totalLoadedPouches > 0  // Can start even if other pouches are active
    }
    
    /// Weighted average duration based on loaded pouches
    private var weightedDuration: TimeInterval {
        var pouchData: [(nicotineAmount: Double, duration: TimeInterval)] = []
        
        for can in activeCans {
            guard let canId = can.id, let count = loadedPouches[canId], count > 0 else { continue }
            
            let duration: TimeInterval
            if can.duration > 0 {
                // Can has custom duration
                duration = TimeInterval(can.duration * 60)
            } else {
                // Use app default
                duration = FULL_RELEASE_TIME
            }
            
            // Add each pouch from this can
            for _ in 0..<count {
                pouchData.append((nicotineAmount: can.strength, duration: duration))
            }
        }
        
        return LogService.calculateWeightedDuration(pouches: pouchData)
    }
    
    /// Unique brand names from active cans for filtering
    private var uniqueBrands: [String] {
        let brands = activeCans.compactMap { $0.brand }.filter { !$0.isEmpty }
        return Array(Set(brands)).sorted()
    }
    
    /// Filtered cans based on selected brand
    private var filteredCans: [Can] {
        if let brand = selectedBrand {
            return activeCans.filter { $0.brand == brand }
        }
        return Array(activeCans)
    }

    var body: some View {
        ZStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Loading interface
                    Text("Load Pouches")
                        .font(.headline)
                        .padding(.top, 16)
                    
                    // Brand filter row
                    if !uniqueBrands.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                // "All" button
                                Button(action: {
                                    selectedBrand = nil
                                }) {
                                    Text("All")
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 8)
                                        .background(selectedBrand == nil ? Color.blue : Color(.secondarySystemBackground))
                                        .foregroundColor(selectedBrand == nil ? .white : .primary)
                                        .cornerRadius(20)
                                }
                                
                                // Brand buttons
                                ForEach(uniqueBrands, id: \.self) { brand in
                                    Button(action: {
                                        selectedBrand = brand
                                    }) {
                                        Text(brand)
                                            .font(.subheadline)
                                            .fontWeight(.semibold)
                                            .padding(.horizontal, 16)
                                            .padding(.vertical, 8)
                                            .background(selectedBrand == brand ? Color.blue : Color(.secondarySystemBackground))
                                            .foregroundColor(selectedBrand == brand ? .white : .primary)
                                            .cornerRadius(20)
                                    }
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                    
                    // Vertical scrolling can inventory
                    if !activeCans.isEmpty {
                        ForEach(filteredCans, id: \.self) { can in
                            if let canId = can.id {
                                // Get active pouches for this specific can
                                let canActivePouches = activePouches.filter { pouch in
                                    pouch.can?.id == canId
                                }
                                
                                CanCardView(
                                    can: can,
                                    loadedCount: loadedPouches[canId] ?? 0,
                                    activePouches: Array(canActivePouches),
                                    onIncrement: {
                                        incrementPouch(for: canId)
                                    },
                                    onDecrement: {
                                        decrementPouch(for: canId)
                                    },
                                    onEdit: {
                                        canToEdit = can
                                        DispatchQueue.main.async {
                                            showingEditCan = true
                                        }
                                    }
                                )
                                .padding(.horizontal)
                            }
                        }
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
                    
                    // Add can and scan buttons
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
                            showingBarcodeScanner = true
                        }) {
                            HStack {
                                Image(systemName: "barcode.viewfinder")
                                Text("Scan Barcode")
                            }
                        }
                        .buttonStyle(.bordered)
                        .frame(height: 44)
                    }
                    .padding(.horizontal)
                    .padding(.bottom, calculateBottomPadding()) // Space for buttons at bottom
                }
            }
            
            // Bottom buttons overlay
            VStack {
                Spacer()
                
                VStack(spacing: 8) {
                    // Active pouches countdown display
                    if !activePouches.isEmpty {
                        ForEach(activePouches.prefix(3), id: \.self) { pouch in
                            compactCountdownPane(for: pouch)
                        }
                    }
                    
                    // Remove All Active Pouches button (shown when any pouches are active)
                    if !activePouches.isEmpty {
                        removeAllActivePouchesButton
                    }
                    
                    // Start Timer button (shown when pouches are loaded)
                    if canStartTimer {
                        startTimerButton
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 16)
                .background(Color(.systemBackground))
            }
            
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
            // Only clean up stale pouches after a delay to avoid conflicts with CloudKit sync
            // This prevents accidentally removing pouches that are still being synced
            Task {
                // Wait a moment for CloudKit sync to update pouch states
                try? await Task.sleep(nanoseconds: 2 * NSEC_PER_SEC)
                await MainActor.run {
                    cleanUpStale()
                }
            }
            
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
            // When a pouch is logged from anywhere (URL schemes, etc.), start the Live Activity timer
            startLiveTimerIfNeeded()
            // Also start the optimized timer for in-app updates
            if !activePouches.isEmpty {
                startOptimizedTimer()
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
    
    var removeAllActivePouchesButton: some View {
        Button(action: removeAllActivePouches) {
            HStack {
                Image(systemName: "xmark.circle.fill")
                Text("Remove All Active Pouches")
                    .fontWeight(.semibold)
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color.red)
            .foregroundColor(.white)
            .cornerRadius(12)
            .shadow(radius: 4)
        }
    }
    
    var startTimerButton: some View {
        Button(action: startTimerWithLoadedPouches) {
            VStack(spacing: 8) {
                HStack {
                    Image(systemName: "play.fill")
                    Text("Start Timer")
                        .fontWeight(.semibold)
                }
                .font(.title2)
                
                Text("\(totalLoadedPouches) pouch\(totalLoadedPouches == 1 ? "" : "es") • \(String(format: "%.1f", totalNicotine))mg")
                    .font(.caption)
                
                Text("Estimated absorption: \(String(format: "%.2f", estimatedTotalAbsorption)) mg")
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.9))
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color.blue)
            .foregroundColor(.white)
            .cornerRadius(12)
            .shadow(radius: 4)
        }
        .disabled(!canStartTimer)
    }

    // LEGACY VIEW - No longer used in v2.1 (multi-pouch loading)
    // Kept for reference/rollback purposes
    /*
    var quickButtonsView: some View {
        VStack(spacing: 16) {
            // Old horizontal scroll view implementation
        }
    }
    */

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
    func compactCountdownPane(for pouch: PouchLog) -> some View {
        let insertionTime = pouch.insertionTime ?? tick
        let elapsed = max(0, tick.timeIntervalSince(insertionTime))
        let actualDuration = TimeInterval(pouch.timerDuration * 60)
        let remaining = max(min(actualDuration - elapsed, actualDuration), 0)
        let progress = min(max(elapsed / actualDuration, 0), 1)
        let isCompleted = remaining == 0

        let currentAbsorption = AbsorptionConstants.shared
            .calculateCurrentNicotineLevel(nicotineContent: pouch.nicotineAmount, elapsedTime: elapsed)
        let maxPossibleAbsorption = AbsorptionConstants.shared
            .calculateAbsorbedNicotine(nicotineContent: pouch.nicotineAmount, useTime: actualDuration)
        let absorptionProgress = maxPossibleAbsorption > 0 ? currentAbsorption / maxPossibleAbsorption : 0

        HStack(spacing: 12) {
            VStack(spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        if let brand = pouch.can?.brand {
                            Text(brand)
                                .font(.caption)
                                .fontWeight(.semibold)
                        }
                        Text("\(String(format: "%.1f", pouch.nicotineAmount))mg")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(isCompleted ? "Complete!" : formatMinutesSeconds(remaining))
                            .font(.system(size: 16, weight: .bold, design: .monospaced))
                            .foregroundColor(isCompleted ? .green : .blue)
                        
                        Text("\(String(format: "%.3f", currentAbsorption))mg (\(Int(absorptionProgress * 100))%)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                ProgressView(value: progress)
                    .scaleEffect(y: 1.2)
            }
            
            // Remove button
            Button(action: {
                removePouch(pouch)
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.red)
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(shouldDisableRemoveButton)
            .opacity(shouldDisableRemoveButton ? 0.5 : 1.0)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(10)
    }

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

    // MARK: – Multi-Pouch Loading Operations
    
    func incrementPouch(for canId: UUID) {
        let current = loadedPouches[canId] ?? 0
        loadedPouches[canId] = current + 1
    }
    
    func decrementPouch(for canId: UUID) {
        guard let current = loadedPouches[canId], current > 0 else { return }
        if current == 1 {
            loadedPouches.removeValue(forKey: canId)
        } else {
            loadedPouches[canId] = current - 1
        }
    }
    
    func startTimerWithLoadedPouches() {
        guard canStartTimer else { return }
        
        // Haptic feedback
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
        
        var successCount = 0
        var longestDuration: TimeInterval = 0
        var longestPouchId: String?
        var totalNicotine: Double = 0
        
        // First, log all pouches WITHOUT starting Live Activities
        // We'll manually create ONE Live Activity afterward
        for can in activeCans {
            guard let canId = can.id, let count = loadedPouches[canId], count > 0 else { continue }
            
            // Log each pouch from this can individually
            for i in 0..<count {
                // Create pouch without triggering Live Activity
                let pouch = PouchLog(context: ctx)
                pouch.pouchId = UUID()
                // Add microsecond offset to prevent visual grouping in Usage view
                // Each pouch gets a unique timestamp (0ms, 100ms, 200ms, etc.)
                pouch.insertionTime = Date.now.addingTimeInterval(TimeInterval(i) * 0.1)
                pouch.nicotineAmount = can.strength
                
                // Set duration
                let durationSeconds: TimeInterval
                if can.duration > 0 {
                    durationSeconds = TimeInterval(can.duration * 60)
                } else {
                    durationSeconds = FULL_RELEASE_TIME
                }
                pouch.timerDuration = Int32(durationSeconds / 60)
                
                // Associate with can and decrement inventory
                can.addToPouchLogs(pouch)
                can.usePouch()
                
                totalNicotine += can.strength
                
                // Track longest duration pouch for Live Activity
                if durationSeconds >= longestDuration {
                    longestDuration = durationSeconds
                    longestPouchId = pouch.pouchId?.uuidString
                }
                
                successCount += 1
                print("✅ Logged \(can.strength)mg pouch from \(can.brand ?? "Unknown")")
            }
        }
        
        // Save all pouches
        do {
            try ctx.save()
            print("✅ Saved \(successCount) pouches")
        } catch {
            print("❌ Failed to save pouches: \(error)")
            let errorGenerator = UINotificationFeedbackGenerator()
            errorGenerator.notificationOccurred(.error)
            return
        }
        
        if successCount > 0, let pouchId = longestPouchId {
            // Clear loaded pouches
            loadedPouches.removeAll()
            
            // Create ONE Live Activity for the longest timer
            if #available(iOS 16.1, *) {
                Task {
                    _ = await LiveActivityManager.startLiveActivity(
                        for: pouchId,
                        nicotineAmount: totalNicotine,  // Show total nicotine
                        insertionTime: Date.now,
                        duration: longestDuration
                    )
                }
            }
            
            // Schedule completion notification for longest timer
            let fireDate = Date().addingTimeInterval(longestDuration)
            NotificationManager.scheduleCompletionAlert(
                id: pouchId,
                title: "Absorption complete",
                body: "Your pouches have finished absorbing.",
                fireDate: fireDate
            )
            
            // Start Live Activity timer
            startLiveTimerIfNeeded()
            updateWidgetPersistenceHelper()
            
            // Refresh can list
            canManager.fetchActiveCans(context: ctx)
            
            // Trigger CloudKit sync
            Task {
                await PersistenceController.shared.triggerCloudKitSync()
            }
            
            // Update widgets
            WidgetCenter.shared.reloadAllTimelines()
            
            // Success haptic
            let successGenerator = UINotificationFeedbackGenerator()
            successGenerator.notificationOccurred(.success)
            
            print("✅ Started \(successCount) separate timers with ONE Live Activity (longest: \(longestDuration/60) min)")
        } else {
            // Error haptic
            let errorGenerator = UINotificationFeedbackGenerator()
            errorGenerator.notificationOccurred(.error)
            print("❌ Failed to start timers")
        }
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
        // Round strength to avoid floating-point precision issues (9.0000000001 -> 9.0)
        let roundedStrength = round(can.strength)
        let success = canManager.logPouchFromCan(
            can: can,
            amount: roundedStrength,
            context: ctx
        )
        
        if success {
            startLiveTimerIfNeeded()
            updateWidgetPersistenceHelper()
            
            // Refresh can list to update counts
            canManager.fetchActiveCans(context: ctx)
        }
    }

    func removeAllActivePouches() {
        // Remove all active pouches
        let allActivePouches = Array(activePouches)
        
        for pouch in allActivePouches {
            removePouch(pouch)
        }
        
        print("✅ Removed all \(allActivePouches.count) active pouches")
        
        // Haptic feedback
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
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
            
            do {
                try ctx.save()
            } catch {
                print("❌ Failed to save pouch removal: \(error.localizedDescription)")
                print("❌ Full error: \(error)")
            }
            
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
                    // Apply user-configured delay (convert minutes to nanoseconds)
                    let delayNanoseconds = UInt64(autoRemoveDelayMinutes * 60 * Double(NSEC_PER_SEC))
                    // Always wait at least 1 second for the user to see completion
                    let finalDelay = max(delayNanoseconds, NSEC_PER_SEC)
                    try? await Task.sleep(nanoseconds: finalDelay)
                    removePouch(pouch)
                    print("🔄 Auto-removed completed pouch after \(autoRemoveDelayMinutes) minute delay")
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
    
    private func calculateBottomPadding() -> CGFloat {
        var padding: CGFloat = 16
        
        // Add space for "Remove All Active Pouches" button if active pouches exist
        if !activePouches.isEmpty {
            padding += 70  // Button height + spacing
        }
        
        // Add space for "Start Timer" button if loaded pouches exist
        if canStartTimer {
            padding += 90  // Button height + spacing
        }
        
        return padding
    }
    
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
        // Use the pouch's specific duration, not the app's default
        let actualDuration = TimeInterval(pouch.timerDuration * 60)  // Convert minutes to seconds
        let elapsed = Date().timeIntervalSince(insertionTime)
        let delaySeconds = autoRemoveDelayMinutes * 60  // Convert delay to seconds
        let totalDuration = actualDuration + delaySeconds
        let remaining = max(actualDuration - elapsed, 0)
        let isCompleted = remaining == 0
        
        // Auto-remove if enabled and delay period has passed
        if autoRemovePouches && elapsed >= totalDuration && !LogView.pouchesBeingRemoved.contains(
            pouch.pouchId?.uuidString ?? pouch.objectID.uriRepresentation().absoluteString
        ) {
            Task { @MainActor in
                removePouch(pouch)
                print("🔄 Auto-removed completed pouch from timer check after \(autoRemoveDelayMinutes) minute delay")
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
        // Only clean up stale pouches if auto-remove is enabled
        // AND the pouch has actually completed its timer duration + delay
        guard autoRemovePouches else { return }
        
        let request = PouchLog.fetchRequest()
        request.predicate = NSPredicate(format:"removalTime == nil")
        
        if let logs = try? ctx.fetch(request) {
            for pouch in logs {
                guard let insertionTime = pouch.insertionTime else { continue }
                
                // Use the pouch's specific timer duration (stored in minutes)
                let pouchDurationSeconds = TimeInterval(pouch.timerDuration * 60)
                let delaySeconds = autoRemoveDelayMinutes * 60
                let totalDuration = pouchDurationSeconds + delaySeconds
                let elapsed = Date().timeIntervalSince(insertionTime)
                
                // Only auto-remove if the timer + delay has completed
                // Add 5 second grace period to avoid edge cases
                if elapsed > (totalDuration + 5) {
                    print("🧹 Cleaning up completed pouch from \(elapsed / 60) minutes ago (after \(autoRemoveDelayMinutes) min delay)")
                    removePouch(pouch)
                }
            }
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
            // Use the pouch's specific duration, not the app default
            let pouchSpecificDuration = activePouches.first.map { TimeInterval($0.timerDuration * 60) } ?? FULL_RELEASE_TIME
            let endTime = activePouches.first?.insertionTime?.addingTimeInterval(pouchSpecificDuration)
            
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
        // Use the centralized calculator to ensure consistency across all views
        let calculator = NicotineCalculator()
        // Calculate asynchronously but return synchronously for UI compatibility
        let semaphore = DispatchSemaphore(value: 0)
        var result: Double = 0.0
        
        Task {
            result = await calculator.calculateTotalNicotineLevel(context: ctx)
            semaphore.signal()
        }
        
        // Wait for async calculation to complete (with timeout)
        _ = semaphore.wait(timeout: .now() + 0.5)
        return result
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
