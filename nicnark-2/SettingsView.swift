//
// SettingsView.swift
// nicnark-2
//
// Comprehensive Settings Interface with CloudKit Integration
//
// This view provides centralized access to all app settings:
// • Inventory Management - Direct link to full inventory interface
// • Notification Management - All reminder and alert settings
// • Timer Settings - Absorption duration and auto-removal options
// • Data Export - CSV export of all pouch logs
// • CloudKit Sync - Multi-device synchronization controls
// • Support/Tips - In-app purchase tip jar
// • Data Management - Complete data deletion
//
// The view integrates deeply with CloudKit for:
// - Sync status monitoring and display
// - Manual sync triggers
// - Diagnostic tools for troubleshooting
// - Multi-device feature explanations
//
// Special features:
// - Secret developer tools (tap version 5x in DEBUG builds)
// - CloudKit schema validation checklist
// - Production deployment verification
//

import SwiftUI
import CoreData
import StoreKit
import os.log
import CloudKit
#if canImport(UIKit)
import UIKit
#endif

#if canImport(ActivityKit)
import ActivityKit
#endif

#if canImport(WidgetKit)
import WidgetKit
#endif

/**
 * SettingsView: Main settings interface for the app.
 * 
 * Organized into logical sections:
 * 1. Medical Disclaimer - Important health/safety information
 * 2. Inventory - Link to full inventory management
 * 3. Notifications - Comprehensive reminder configuration
 * 4. Timer Settings - Absorption and auto-removal preferences
 * 5. Data Export - Export all pouch logs as CSV
 * 6. App Information - Version and developer details
 * 7. CloudKit Sync - Multi-device synchronization
 * 8. Support - Tip jar for supporting development
 * 9. Data Management - Delete all data option
 * 10. About - App description and privacy statement
 * 
 * The view uses @StateObject for managers to ensure single instances
 * and @AppStorage for simple persistent preferences.
 */
struct SettingsView: View {
    // MARK: - Environment & State Management
    @Environment(\.managedObjectContext) private var viewContext           // Core Data context
    @StateObject private var tipStore = TipStore()                         // In-app purchase manager
    @StateObject private var syncManager = CloudKitSyncManager.shared      // CloudKit sync manager
    @StateObject private var timerSettings = TimerSettings.shared          // Timer duration settings
    @AppStorage("autoRemovePouches") private var autoRemovePouches = false
    @AppStorage("autoRemoveDelayMinutes") private var autoRemoveDelayMinutes: Double = 0
    @AppStorage("hideLegacyButtons") private var hideLegacyButtons = false
    @AppStorage("priorityNotifications") private var priorityNotifications = false

    // MARK: - Sleep Protection
    @AppStorage(SleepProtectionKeys.enabled) private var sleepProtectionEnabled = false
    @AppStorage(SleepProtectionKeys.bedtimeSecondsFromMidnight) private var sleepProtectionBedtimeSecondsFromMidnight: Int = 23 * 3600
    @AppStorage(SleepProtectionKeys.targetMg) private var sleepProtectionTargetMg: Double = 1.3
    @State private var showingDeleteAlert = false
    @State private var showingTipThankYou = false
    @State private var isDeleting = false
    @State private var showingFullDisclaimer = false
    @State private var isCloudKitSyncEnabled = UserDefaults.standard.object(forKey: "cloudKitSyncEnabled") as? Bool ?? true
    @State private var showingDiagnostics = false
    @State private var diagnosticsResult = ""
    @State private var isRunningDiagnostics = false
    @State private var isTestingSyncData = false
    @State private var showingSyncProgress = false
    @State private var showingExportSheet = false
    @State private var exportURL: URL?
    @State private var isExporting = false
    @State private var exportError: String?
    @State private var exportStats: (totalLogs: Int, dateRange: String) = (0, "")
    
    #if DEBUG
    @State private var debugToolsVisible = false
    @State private var secretTapCount = 0
    @State private var isCheckingSchema = false
    @State private var schemaCheckResult: String? = nil
    @State private var showingDeploymentChecklist = false
    #endif
    
    private let logger = Logger(subsystem: "com.nicnark.nicnark-2", category: "Settings")

    var body: some View {
        Form {
            disclaimerSection
            inventorySection
            notificationSection
            timerSettingsSection
            sleepProtectionSection
            exportSection
            appInfoSection
            cloudKitSyncSection
            #if DEBUG
            if debugToolsVisible { developerSchemaSection }
            #endif
            supportSection
            dataManagementSection
            aboutSection
        }
        .navigationTitle("Settings")
        .alert("Thank You! 🎉", isPresented: $showingTipThankYou) {
            Button("You're Welcome! ☕️") { }
        } message: {
            Text("Your support helps fund continued development!")
        }
        .alert("Delete All Data", isPresented: $showingDeleteAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Delete Everything", role: .destructive) {
                Task { await deleteAllData() }
            }
        } message: {
            Text("This permanently deletes ALL app data. This cannot be undone.")
        }
        .task {
            await tipStore.loadProducts()
            exportStats = await ExportManager.getExportStatistics(context: viewContext)
        }
        .sheet(isPresented: $showingFullDisclaimer) {
            FirstRunDisclaimerView(isPresented: $showingFullDisclaimer)
        }
        .sheet(isPresented: $showingExportSheet) {
            if let url = exportURL {
                DocumentExporter(url: url)
            }
        }
        .sheet(isPresented: $showingDiagnostics) {
            NavigationView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(diagnosticsResult)
                            .font(.system(.caption, design: .monospaced))
                            .padding()
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(8)
                    }
                    .padding()
                }
                .navigationTitle("CloudKit Diagnostics")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement: .navigationBarTrailing) {
                        Button("Copy Container ID") {
                            #if canImport(UIKit)
                            UIPasteboard.general.string = "iCloud.ConnorNeedling.nicnark-2"
                            #endif
                        }
                        Button("Done") {
                            showingDiagnostics = false
                        }
                    }
                }
            }
        }
        #if DEBUG
        .sheet(isPresented: $showingDeploymentChecklist) {
            NavigationView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(deploymentChecklistText)
                            .font(.system(.caption, design: .monospaced))
                            .padding()
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(8)
                    }
                    .padding()
                }
                .navigationTitle("Production Deployment Checklist")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Done") { showingDeploymentChecklist = false } } }
            }
        }
        #endif
        .alert("Test Sync Complete", isPresented: .constant(isTestingSyncData && !isTestingSyncData)) {
            Button("OK") { }
        } message: {
            Text("CloudKit sync test completed. Check the console logs for details.")
        }
    }

    // MARK: - View Sections
    
    /**
     * Inventory Management Section
     * 
     * Provides a prominent link to the full InventoryManagementView.
     * Features:
     * - Blue tray icon for visual identification
     * - Navigation chevron indicating it's a push navigation
     * - Descriptive footer explaining the feature
     * 
     * This is placed prominently as it's a key feature for tracking
     * pouch consumption accurately.
     */
    private var inventorySection: some View {
        Section {
            NavigationLink(destination: InventoryManagementView()) {
                HStack {
                    Image(systemName: "tray.2.fill")
                        .foregroundColor(.blue)
                        .frame(width: 28)
                    Text("Inventory Management")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        } header: {
            Text("Inventory")
        } footer: {
            Text("Manage your can inventory, add new cans, and adjust pouch counts")
        }
    }
    
    /**
     * Notification Management Section
     * 
     * Links to the comprehensive NotificationManagementView where users can:
     * - Configure usage reminders (time or nicotine-level based)
     * - Set up daily summaries
     * - Enable usage insights
     * - Configure inventory alerts
     * 
     * Uses an orange bell icon to stand out as an important configuration area.
     */
    private var notificationSection: some View {
        Section {
            NavigationLink(destination: NotificationManagementView()) {
                HStack {
                    Image(systemName: "bell.badge")
                        .foregroundColor(.orange)
                        .frame(width: 28)
                    Text("Notification Management")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text("Configure alerts for inventory, usage reminders, daily summaries, and insights")
        }
    }
    
    private var disclaimerSection: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundColor(.orange)
                    .font(.title2)
                    .padding(.top, 2)
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Important Disclaimer")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    Text("This app is for tracking nicotine consumption only. It does not provide medical advice, diagnosis, or treatment recommendations.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    Text("Consult with a healthcare provider for medical advice, treatment decisions, or questions about nicotine use and cessation.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    Text("Absorption calculations and timing are estimates based on general research and should not be considered medically accurate.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 4)
            
            Button("View Full Disclaimer") {
                showingFullDisclaimer = true
            }
            .foregroundColor(.blue)
        } header: {
            Text("Medical Disclaimer")
        }
    }

    private var timerSettingsSection: some View {
        Section {
            Picker("Absorption Timer", selection: $timerSettings.selectedDuration) {
                ForEach(TimerDuration.allCases, id: \.self) { duration in
                    Text(duration.displayName).tag(duration)
                }
            }
            .pickerStyle(MenuPickerStyle())
            
            Text("Sets how long pouches take to fully absorb nicotine")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Toggle("Auto-Remove When Complete", isOn: $autoRemovePouches)
            
            if autoRemovePouches {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Delay:")
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(autoRemoveDelayText)
                            .foregroundColor(.blue)
                    }
                    
                    Slider(value: $autoRemoveDelayMinutes, in: 0...60, step: 5)
                        .tint(.blue)
                    
                    Text("Remove pouches \(autoRemoveDelayMinutes > 0 ? "\(Int(autoRemoveDelayMinutes)) minutes after" : "immediately when") timer completes")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.leading)
            } else {
                Text("Automatically remove pouches when the timer completes")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Toggle("Hide Legacy Quick Add Buttons", isOn: $hideLegacyButtons)
            
            Text("Hides the legacy quick add buttons from the log view")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Toggle("Priority Completion Notifications", isOn: $priorityNotifications)
            
            Text("Mark absorption completion notifications as time-sensitive for immediate delivery")
                .font(.caption)
                .foregroundColor(.secondary)
        } header: {
            Text("Timer Settings")
        } footer: {
            Text("Priority notifications bypass Do Not Disturb and Focus modes. Legacy buttons can be deleted by long-pressing them.")
        }
    }

    private var sleepProtectionSection: some View {
        Section {
            Toggle("Sleep Protection", isOn: $sleepProtectionEnabled)

            if sleepProtectionEnabled {
                DatePicker(
                    "Bedtime",
                    selection: Binding(
                        get: {
                            SleepProtectionHelper.dateForTimePicker(
                                secondsFromMidnight: sleepProtectionBedtimeSecondsFromMidnight
                            )
                        },
                        set: { newValue in
                            sleepProtectionBedtimeSecondsFromMidnight = SleepProtectionHelper.secondsFromMidnight(for: newValue)
                        }
                    ),
                    displayedComponents: .hourAndMinute
                )

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Target Level")
                        Spacer()
                        Text("\(sleepProtectionTargetMg, specifier: "%.1f") mg")
                            .foregroundColor(.secondary)
                    }

                    Slider(value: $sleepProtectionTargetMg, in: 0...5, step: 0.1)
                }
            }
        } header: {
            Text("Sleep Protection")
        } footer: {
            Text("Warns you if planned pouches are predicted to keep you above your target level at bedtime.")
        }
    }
    
    private var exportSection: some View {
        Section {
            Button(action: exportPouchLogs) {
                HStack {
                    Image(systemName: "square.and.arrow.up")
                    Text("Export All Pouch Logs")
                }
            }
            .disabled(isExporting)
            
            if exportStats.totalLogs > 0 {
                HStack {
                    Text("Total Logs:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(exportStats.totalLogs)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                HStack {
                    Text("Date Range:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(exportStats.dateRange)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            if isExporting {
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Preparing export...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            if let error = exportError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        } header: {
            Text("Data Export")
        } footer: {
            Text("Export all pouch logs as CSV file, including logs older than 24 hours")
        }
    }
    
    private var appInfoSection: some View {
        Section {
            HStack {
                Text("Version")
                Spacer()
                Text("2.0.0")
                    .foregroundColor(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                #if DEBUG
                secretTapCount += 1
                if secretTapCount >= 5 {
                    debugToolsVisible.toggle()
                    secretTapCount = 0
                }
                #endif
            }
            
            HStack {
                Text("Developer")
                Spacer()
                Text("Connor Needling")
                    .foregroundColor(.secondary)
            }
        } header: {
            Text("App Information")
        }
    }
    
    /**
     * CloudKit Synchronization Section
     * 
     * Complex section handling multi-device sync configuration:
     * - Toggle for enabling/disabling sync
     * - Visual status indicator with color coding
     * - Diagnostic tools for troubleshooting
     * - Test sync functionality
     * - Manual sync trigger
     * - Multi-device feature explanation
     * 
     * Color coding:
     * - Green: Sync enabled and working
     * - Orange: Sync disabled by user
     * - Red: CloudKit unavailable (no iCloud account)
     * - Gray: Loading or unknown state
     * 
     * This section is critical for users with multiple devices
     * (iPhone and iPad) to keep data synchronized.
     */
    private var cloudKitSyncSection: some View {
        Section {
            // CloudKit Sync Toggle
            Toggle(isOn: $isCloudKitSyncEnabled) {
                HStack {
                    Image(systemName: "icloud")
                        .foregroundColor(syncManager.isCloudKitAvailable ? .blue : .gray)
                    Text("iCloud Sync")
                }
            }
            .onChange(of: isCloudKitSyncEnabled) { _, newValue in
                UserDefaults.standard.set(newValue, forKey: "cloudKitSyncEnabled")
                Task {
                    if newValue {
                        await syncManager.triggerManualSync()
                    }
                }
                logger.info("CloudKit sync \(newValue ? "enabled" : "disabled", privacy: .public)")
            }
            .disabled(!syncManager.isCloudKitAvailable)
            
            // Sync Status
            HStack {
                Image(systemName: syncStatusIcon)
                    .foregroundColor(syncStatusColor)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sync Status")
                        .font(.subheadline)
                    Text(syncStatusText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
            }
            
            // Diagnostic and sync buttons
            if syncManager.isCloudKitAvailable {
                HStack {
                    Button("Diagnose") {
                        isRunningDiagnostics = true
                        Task {
                            diagnosticsResult = await syncManager.diagnoseCloudKitSync()
                            isRunningDiagnostics = false
                            showingDiagnostics = true
                        }
                    }
                    .font(.caption2)
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(isRunningDiagnostics)
                    
                    Button("Test Sync") {
                        isTestingSyncData = true
                        Task {
                            await syncManager.testDataSync()
                            isTestingSyncData = false
                        }
                    }
                    .font(.caption2)
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(isTestingSyncData)
                    
                    if isCloudKitSyncEnabled {
                        Button("Sync Now") {
                            Task {
                                await syncManager.triggerManualSync()
                            }
                        }
                        .font(.caption2)
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                    
                    if isRunningDiagnostics || isTestingSyncData {
                        ProgressView()
                            .scaleEffect(0.6)
                    }
                }
                .padding(.top, 4)
            }
            
            // Cross-Device Features Info
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "iphone.and.ipad")
                    .foregroundColor(.green)
                    .font(.title3)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Multi-Device Features")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    
                    if isCloudKitSyncEnabled && syncManager.isCloudKitAvailable {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("✅ Data syncs across all devices")
                            Text("✅ Live Activities appear on all devices")
                            Text("✅ Widget data stays in sync")
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                    } else {
                        Text("Enable sync to use these features")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
            
        } header: {
            Text("iCloud Synchronization")
        } footer: {
            if !syncManager.isCloudKitAvailable {
                Text("iCloud sync is unavailable. Make sure you're signed into iCloud and have iCloud Drive enabled.")
            } else if isCloudKitSyncEnabled {
                Text("Your pouch data, Live Activities, and usage statistics will sync automatically across all your devices signed into the same iCloud account.")
            } else {
                Text("Enable iCloud sync to keep your data synchronized across iPhone and iPad. Live Activities will appear on all your devices.")
            }
        }
    }

    private var supportSection: some View {
        Section {
            if tipStore.isLoading {
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Loading tips...")
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 8)
            } else if tipStore.tips.isEmpty {
                Button("Reload Tips") {
                    Task { await tipStore.loadProducts() }
                }
            } else {
                ForEach(tipStore.tips, id: \.id) { tip in
                    TipRowView(tip: tip) {
                        Task {
                            await tipStore.purchaseTip(tip)
                            showingTipThankYou = true
                        }
                    }
                    .disabled(tipStore.isLoading)
                }
            }
            
            if !tipStore.errorMessage.isEmpty {
                Text(tipStore.errorMessage)
                    .foregroundColor(.red)
                    .font(.caption)
            }
        } header: {
            Text("Support the Developer")
        } footer: {
            Text("Thank you for supporting continued development! Tips help fund new features and improvements.")
        }
    }

    private var dataManagementSection: some View {
        Section {
            Button(action: { showingDeleteAlert = true }) {
                HStack {
                    if isDeleting {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .red))
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "trash.circle")
                            .foregroundColor(.red)
                    }
                    
                    Text(isDeleting ? "Deleting..." : "Delete All Data")
                        .foregroundColor(.red)
                }
            }
            .disabled(isDeleting)
        } header: {
            Text("Data Management")
        } footer: {
            Text("This permanently deletes all pouch logs and custom buttons. This action cannot be undone.")
        }
    }

    #if DEBUG
    private var developerSchemaSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("Container: iCloud.ConnorNeedling.nicnark-2")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("Record Types expected: CD_PouchLog, CD_CustomButton")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                HStack(spacing: 12) {
                    Button(isCheckingSchema ? "Checking…" : "Run Checklist") {
                        Task { await runSchemaChecklist() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isCheckingSchema)
                    
                    Button("Open CloudKit Dashboard") {
                        if let url = URL(string: "https://icloud.developer.apple.com/dashboard") {
                            UIApplication.shared.open(url)
                        }
                    }
                    .buttonStyle(.bordered)
                    
                    Button("Copy Container ID") { UIPasteboard.general.string = "iCloud.ConnorNeedling.nicnark-2" }
                        .buttonStyle(.bordered)
                    Button("Deployment Checklist") { showingDeploymentChecklist = true }
                        .buttonStyle(.bordered)
                }
                
                if let result = schemaCheckResult {
                    ScrollView {
                        Text(result)
                            .font(.system(.caption, design: .monospaced))
                            .padding(8)
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(8)
                    }
                    .frame(maxHeight: 220)
                }
            }
        } header: {
            Text("Developer • Schema Checklist")
        } footer: {
            Text("Hidden debug tools — tap the Version row 5× to toggle. Use this checklist before shipping to ensure the Production schema is deployed.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
    #endif
    
    private var aboutSection: some View {
        Section {
            HStack {
                Image(systemName: "info.circle")
                    .foregroundColor(.blue)
                VStack(alignment: .leading, spacing: 4) {
                    Text("NicNark")
                        .font(.headline)
                    Text("Track nicotine consumption with Live Activities, interactive graphs, Siri shortcuts, and NO ADs!")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text("Your data stays private and syncs securely with CloudKit.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("About")
        }
    }

    // MARK: - Computed Properties
    
    private var autoRemoveDelayText: String {
        if autoRemoveDelayMinutes == 0 {
            return "Immediate"
        } else {
            return "\(Int(autoRemoveDelayMinutes)) min"
        }
    }
    
    private var syncStatusIcon: String {
        if !syncManager.isCloudKitAvailable {
            return "icloud.slash"
        } else if isCloudKitSyncEnabled {
            return "checkmark.icloud"
        } else {
            return "icloud"
        }
    }
    
    private var syncStatusColor: Color {
        if !syncManager.isCloudKitAvailable {
            return .red
        } else if isCloudKitSyncEnabled {
            return .green
        } else {
            return .orange
        }
    }
    
    private var syncStatusText: String {
        if !syncManager.isCloudKitAvailable {
            return "iCloud unavailable"
        } else if isCloudKitSyncEnabled {
            return syncManager.getSyncStatusText()
        } else {
            return "Sync disabled"
        }
    }
    
    // MARK: - Data Deletion
    
    #if DEBUG
    private func runSchemaChecklist() async {
        isCheckingSchema = true
        defer { isCheckingSchema = false }
        var lines: [String] = []
        
        #if DEBUG
        let buildEnv = "Development"
        #else
        let buildEnv = "Production"
        #endif
        lines.append("=== CloudKit Schema Checklist ===")
        lines.append("Build: \(buildEnv)")
        lines.append("Container: iCloud.ConnorNeedling.nicnark-2")
        
        // 1) Account status
        do {
            let status = try await CKContainer(identifier: "iCloud.ConnorNeedling.nicnark-2").accountStatus()
            lines.append("Account Status: \(status)")
        } catch {
            lines.append("Account Status: ERROR — \(error.localizedDescription)")
        }
        
        // 2) Probe record types in current environment
        let ck = CKContainer(identifier: "iCloud.ConnorNeedling.nicnark-2").privateCloudDatabase
        let candidates = ["CD_PouchLog", "CD_CustomButton"]
        for type in candidates {
            do {
                let q = CKQuery(recordType: type, predicate: NSPredicate(value: true))
                let _ = try await ck.records(matching: q, resultsLimit: 1)
                lines.append("✅ Record type available: \(type)")
            } catch {
                lines.append("ℹ️ Could not query \(type): \(error.localizedDescription)")
            }
        }
        
        // 3) Local Core Data check
        let ctx = PersistenceController.shared.container.viewContext
        let count = (try? ctx.count(for: PouchLog.fetchRequest())) ?? 0
        lines.append("Local PouchLogs: \(count)")
        
        // 4) Next steps for Production
        lines.append("")
        lines.append("If building for Production/TestFlight and queries fail, deploy schema:")
        lines.append("1. Open CloudKit Dashboard → Container: iCloud.ConnorNeedling.nicnark-2")
        lines.append("2. Schema → Deploy to Production")
        lines.append("3. Reinstall a Release/TestFlight build and verify")
        lines.append("=== END CHECKLIST ===")
        
        await MainActor.run { schemaCheckResult = lines.joined(separator: "\n") }
    }
    #endif
    
    private var deploymentChecklistText: String {
        """
        === PRODUCTION DEPLOYMENT CHECKLIST ===
        1) Build: Use a Release configuration (or Archive for TestFlight/App Store).
        2) CloudKit Dashboard → Container: iCloud.ConnorNeedling.nicnark-2
           - Schema tab: verify record types CD_PouchLog and CD_CustomButton.
           - If not deployed, click "Deploy to Production".
        3) Reinstall the app from TestFlight/App Store on a clean device.
        4) Log a pouch → confirm sync works across devices.
        5) Settings → Diagnose: Build shows "Production" and Sync Status is healthy.
        6) If a device used a prior build before schema was deployed, delete/reinstall once.
        === END CHECKLIST ===
        """
    }
    
    private func exportPouchLogs() {
        isExporting = true
        exportError = nil
        
        Task {
            do {
                let url = try await ExportManager.exportAllPouchLogs(context: viewContext)
                await MainActor.run {
                    self.exportURL = url
                    self.showingExportSheet = true
                    self.isExporting = false
                }
            } catch {
                await MainActor.run {
                    self.exportError = "Export failed: \(error.localizedDescription)"
                    self.isExporting = false
                }
            }
        }
    }
    
    private func deleteAllData() async {
        isDeleting = true
        logger.info("Starting data deletion process")
        
        // End Live Activities
        await endAllLiveActivities()
        
        // Cancel notifications
        NotificationManager.cancelAllNotifications()
        
        // Delete Core Data
        await deleteAllCoreDataEntities()
        
        // Reload widgets
        await MainActor.run {
            WidgetCenter.shared.reloadAllTimelines()
        }
        
        isDeleting = false
        
        // Haptic feedback
        let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
        impactFeedback.impactOccurred()
        
        logger.info("Data deletion completed")
    }
    
    private func endAllLiveActivities() async {
        #if canImport(ActivityKit)
        if #available(iOS 16.1, *) {
            await LiveActivityManager.endAllLiveActivities()
        }
        #endif
    }
    
    private func deleteAllCoreDataEntities() async {
        await withCheckedContinuation { continuation in
            viewContext.perform {
                let entityNames = ["PouchLog", "CustomButton"]
                
                for entityName in entityNames {
                    let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: entityName)
                    let deleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)
                    
                    do {
                        try self.viewContext.execute(deleteRequest)
                    } catch {
                        self.logger.error("Failed to delete \(entityName): \(error.localizedDescription)")
                    }
                }
                
                do {
                    try self.viewContext.save()
                } catch {
                    self.logger.error("Failed to save context after deletion: \(error.localizedDescription)")
                }
                
                continuation.resume()
            }
        }
    }
}

// MARK: - Tip Row View

private struct TipRowView: View {
    let tip: Product
    let onPurchase: () -> Void

    var body: some View {
        Button(action: onPurchase) {
            HStack {
                Image(systemName: tipIcon)
                    .foregroundColor(tipColor)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(tip.displayName)
                        .foregroundColor(.primary)
                    Text(tip.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Text(tip.displayPrice)
                    .fontWeight(.semibold)
                    .foregroundColor(.blue)
            }
        }
    }

    private var tipIcon: String {
        switch tip.id {
        case "small_coffee": return "cup.and.saucer"
        case "medium_coffee": return "mug"
        case "large_coffee": return "takeoutbag.and.cup.and.straw"
        default: return "heart.circle.fill"
        }
    }

    private var tipColor: Color {
        switch tip.id {
        case "small_coffee": return .orange
        case "medium_coffee": return .brown
        case "large_coffee": return .purple
        default: return .pink
        }
    }
}

// MARK: - Previews

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            SettingsView()
        }
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
    }
}
