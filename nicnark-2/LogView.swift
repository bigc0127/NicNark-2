//
// LogView.swift
// nicnark-2
//
// Restored from main. Timer/action methods live in LogView+Actions.swift.
//
import SwiftUI
import CoreData
import WidgetKit
import ActivityKit
import Combine

struct LogView: View {
    @Environment(\.managedObjectContext) private var ctx
    @StateObject private var timerSettings = TimerSettings.shared
    @AppStorage("autoRemovePouches") private var autoRemovePouches = false
    @AppStorage("autoRemoveDelayMinutes") private var autoRemoveDelayMinutes: Double = 0
    @AppStorage("hideLegacyButtons") private var hideLegacyButtons = false
    @AppStorage(SleepProtectionKeys.enabled) private var sleepProtectionEnabled = false
    @AppStorage(SleepProtectionKeys.bedtimeSecondsFromMidnight) private var sleepProtectionBedtimeSecondsFromMidnight: Int = 23 * 3600
    @AppStorage(SleepProtectionKeys.targetMg) private var sleepProtectionTargetMg: Double = 1.3
    @StateObject private var canManager = CanManager.shared
    @State private var loadedPouches: [UUID: Int] = [:]
    @State private var showingAddCan = false
    @State private var showingBarcodeScanner = false
    @State private var scannedBarcode: String? = nil
    @State private var pendingBarcodeAfterScan: String? = nil
    @State private var selectedCan: Can?
    @State private var showingEditCan = false
    @State private var canToEdit: Can?
    @State private var showingDuplicateCanAlert = false
    @State private var duplicateCanForAlert: Can?
    @State private var selectedBrand: String? = nil
    @State private var currentNicotineLevel: Double = 0.0
    @State private var estimatedNicotineLevel: Double? = nil
    @State private var sleepProtectionBedtime: Date? = nil
    @State private var sleepProtectionPredictedLevelAtBedtime: Double? = nil
    @State private var isEvaluatingSleepProtection = false
    @FetchRequest(
        entity: Can.entity(),
        sortDescriptors: [
            NSSortDescriptor(keyPath: \Can.pouchCount, ascending: false),
            NSSortDescriptor(keyPath: \Can.dateAdded, ascending: false)
        ],
        predicate: NSPredicate(format: "pouchCount > 0 OR (ANY pouchLogs.removalTime == nil)")
    ) private var activeCans: FetchedResults<Can>
    @FetchRequest(
        entity: CustomButton.entity(),
        sortDescriptors: [NSSortDescriptor(keyPath: \CustomButton.nicotineAmount, ascending: true)]
    ) private var customButtons: FetchedResults<CustomButton>
    @FetchRequest(
        entity: PouchLog.entity(),
        sortDescriptors: [NSSortDescriptor(keyPath: \PouchLog.insertionTime, ascending: false)],
        predicate: NSPredicate(format: "removalTime == nil")
    ) private var activePouches: FetchedResults<PouchLog>
    @State private var showInput = false
    @State private var input = ""
    @State private var tick = Date()
    @State private var lastWidgetUpdate = Date()
    @State private var lastLiveActivityUpdate = Date()
    @State private var timersExpanded = true
    @State private var liveTimer: Timer?
    @State private var optimizedTimer: Timer?
    private var pouchDuration: TimeInterval { timerSettings.currentTimerInterval }
    private let TIMER_INTERVAL: TimeInterval = 1.0
    private var totalLoadedPouches: Int { loadedPouches.values.reduce(0, +) }
    private var totalNicotine: Double {
        activeCans.reduce(0.0) { total, can in
            guard let canId = can.id, let count = loadedPouches[canId], count > 0 else { return total }
            return total + (can.strength * Double(count))
        }
    }
    private var estimatedTotalAbsorption: Double {
        activeCans.reduce(0.0) { total, can in
            guard let canId = can.id, let count = loadedPouches[canId], count > 0 else { return total }
            let fraction = BrandAbsorptionProfile.fraction(forBrand: can.brand)
            return total + (can.strength * Double(count) * fraction)
        }
    }
    private var canStartTimer: Bool { totalLoadedPouches > 0 }
    private var weightedDuration: TimeInterval {
        var pouchData: [(nicotineAmount: Double, duration: TimeInterval)] = []
        for can in activeCans {
            guard let canId = can.id, let count = loadedPouches[canId], count > 0 else { continue }
            let duration: TimeInterval = can.duration > 0 ? TimeInterval(can.duration * 60) : FULL_RELEASE_TIME
            for _ in 0..<count { pouchData.append((nicotineAmount: can.strength, duration: duration)) }
        }
        return LogService.calculateWeightedDuration(pouches: pouchData)
    }
    private var uniqueBrands: [String] {
        Array(Set(activeCans.compactMap { $0.brand }.filter { !$0.isEmpty })).sorted()
    }
    private var filteredCans: [Can] {
        if let brand = selectedBrand { return activeCans.filter { $0.brand == brand } }
        return Array(activeCans)
    }
    var body: some View {
        ZStack {
            ScrollView {
                VStack(spacing: 16) {
                    DailyGoalCard()
                    Text("Load Pouches").font(.headline).padding(.top, 16)
                    if !uniqueBrands.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                Button(action: { selectedBrand = nil }) {
                                    Text("All").font(.subheadline).fontWeight(.semibold)
                                        .padding(.horizontal, 16).padding(.vertical, 8)
                                        .background(selectedBrand == nil ? Color.blue : Color(.secondarySystemBackground))
                                        .foregroundColor(selectedBrand == nil ? .white : .primary)
                                        .cornerRadius(20)
                                }
                                ForEach(uniqueBrands, id: \.self) { brand in
                                    Button(action: { selectedBrand = brand }) {
                                        Text(brand).font(.subheadline).fontWeight(.semibold)
                                            .padding(.horizontal, 16).padding(.vertical, 8)
                                            .background(selectedBrand == brand ? Color.blue : Color(.secondarySystemBackground))
                                            .foregroundColor(selectedBrand == brand ? .white : .primary)
                                            .cornerRadius(20)
                                    }
                                }
                            }.padding(.horizontal)
                        }
                    }
                    if !activeCans.isEmpty {
                        ForEach(filteredCans, id: \.self) { can in
                            if let canId = can.id {
                                let canActivePouches = activePouches.filter { $0.can?.id == canId }
                                CanCardView(
                                    can: can,
                                    loadedCount: loadedPouches[canId] ?? 0,
                                    activePouches: Array(canActivePouches),
                                    onIncrement: { incrementPouch(for: canId) },
                                    onDecrement: { decrementPouch(for: canId) },
                                    onEdit: {
                                        canToEdit = can
                                        DispatchQueue.main.async { showingEditCan = true }
                                    }
                                ).padding(.horizontal)
                            }
                        }
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "tray").font(.system(size: 48)).foregroundColor(.gray)
                            Text("No cans in inventory").font(.headline).foregroundColor(.secondary)
                            Text("Add a can to start tracking").font(.caption).foregroundColor(.secondary)
                        }
                        .frame(height: 180).frame(maxWidth: .infinity)
                        .background(Color(.secondarySystemBackground)).cornerRadius(12).padding(.horizontal)
                    }
                    HStack(spacing: 12) {
                        Button(action: { showingAddCan = true }) {
                            HStack { Image(systemName: "plus.circle.fill"); Text("Add Can") }
                        }.buttonStyle(.borderedProminent).frame(height: 44)
                        Button(action: { pendingBarcodeAfterScan = nil; showingBarcodeScanner = true }) {
                            HStack { Image(systemName: "barcode.viewfinder"); Text("Scan Barcode") }
                        }.buttonStyle(.bordered).frame(height: 44)
                    }.padding(.horizontal).padding(.bottom, calculateBottomPadding())
                }
            }
            VStack {
                Spacer()
                VStack(spacing: 8) {
                    if !activePouches.isEmpty {
                        Button(action: { withAnimation { timersExpanded.toggle() } }) {
                            HStack {
                                Image(systemName: timersExpanded ? "chevron.down" : "chevron.up")
                                Text(timersExpanded ? "Collapse" : "Expand \(activePouches.count) Timer\(activePouches.count == 1 ? "" : "s")").font(.caption)
                            }.foregroundColor(.blue)
                        }
                        if timersExpanded {
                            ForEach(activePouches, id: \.self) { pouch in compactCountdownPane(for: pouch) }
                        } else {
                            collapsedTimerSummary
                        }
                    }
                    if !activePouches.isEmpty { removeAllActivePouchesButton }
                    if canStartTimer { startTimerButton }
                }.padding(.horizontal).padding(.bottom, 16).background(.regularMaterial)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            if CloudKitSyncState.shared.isCloudKitEnabled && CloudKitSyncState.shared.isSyncing { syncOverlay }
        }
        .navigationTitle("NicNark")
        .navigationBarTitleDisplayMode(.large)
        .onAppear {
            Task {
                try? await Task.sleep(nanoseconds: 2 * NSEC_PER_SEC)
                await MainActor.run { cleanUpStale() }
            }
            print("Live Activities enabled: \(ActivityAuthorizationInfo().areActivitiesEnabled)")
            Task { await CloudKitSyncState.shared.startInitialSync() }
            WidgetReloadCoordinator.reload()
            if !activePouches.isEmpty { startOptimizedTimer() }
            updateNicotineLevels()
            updateSleepProtectionEvaluation()
            canManager.fetchActiveCans(context: ctx)
            if !showingBarcodeScanner { pendingBarcodeAfterScan = nil }
        }
        .onChange(of: activePouches.isEmpty) { _, isEmpty in
            if isEmpty { stopOptimizedTimer() } else { startOptimizedTimer() }
        }
        .onDisappear { stopOptimizedTimer() }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("PouchRemoved"))) { _ in
            if activePouches.isEmpty { stopOptimizedTimer() } else { startOptimizedTimer(); startLiveTimerIfNeeded() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("PouchLogged"))) { _ in
            startLiveTimerIfNeeded()
            if !activePouches.isEmpty { startOptimizedTimer() }
            updateNicotineLevels()
        }
        .onChange(of: loadedPouches) { _, _ in updateNicotineLevels(); updateSleepProtectionEvaluation() }
        .onChange(of: sleepProtectionEnabled) { _, _ in updateSleepProtectionEvaluation() }
        .onChange(of: sleepProtectionBedtimeSecondsFromMidnight) { _, _ in updateSleepProtectionEvaluation() }
        .onChange(of: sleepProtectionTargetMg) { _, _ in updateSleepProtectionEvaluation() }
        .sheet(isPresented: $showingAddCan) {
            CanDetailView(barcode: scannedBarcode).environment(\.managedObjectContext, ctx).onDisappear { scannedBarcode = nil }
        }
        .sheet(isPresented: $showingEditCan) {
            if let can = canToEdit {
                CanDetailView(editingCan: can).environment(\.managedObjectContext, ctx)
            } else {
                Text("Error: No can selected").onAppear { showingEditCan = false }
            }
        }
        .onChange(of: showingEditCan) { _, isShowing in
            if !isShowing { canToEdit = nil; canManager.fetchActiveCans(context: ctx) }
        }
        .sheet(isPresented: $showingBarcodeScanner, onDismiss: {
            guard let code = pendingBarcodeAfterScan else { return }
            pendingBarcodeAfterScan = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                guard !showingBarcodeScanner, pendingBarcodeAfterScan == nil else { return }
                handleScannedBarcode(code)
            }
        }) {
            BarcodeScannerView { barcode in pendingBarcodeAfterScan = barcode; showingBarcodeScanner = false }
        }
        .alert("Can Already in Inventory", isPresented: $showingDuplicateCanAlert) {
            Button("Add Pouches to Existing Can") {
                if let can = duplicateCanForAlert {
                    can.pouchCount += can.initialCount
                    do { try ctx.save(); canManager.fetchActiveCans(context: ctx) } catch { print("Failed to update can count: \(error)") }
                }
                duplicateCanForAlert = nil
            }
            Button("Add as Separate Can") {
                if let can = duplicateCanForAlert { scannedBarcode = can.barcode; showingAddCan = true }
                duplicateCanForAlert = nil
            }
            Button("Cancel", role: .cancel) { duplicateCanForAlert = nil }
        } message: {
            if let can = duplicateCanForAlert {
                Text("\(can.brand ?? "Unknown") \(can.flavor ?? "") (\(Int(can.strength))mg) is already in your inventory with \(can.pouchCount) pouches. Would you like to add more pouches to this can or track it as a separate can?")
            }
        }
    }
}
