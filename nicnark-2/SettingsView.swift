//
// SettingsView.swift
// nicnark-2
//
// Fixed settings view with proper initialization
//

import SwiftUI
import CoreData
import StoreKit
import os.log

#if canImport(ActivityKit)
import ActivityKit
#endif

#if canImport(WidgetKit)
import WidgetKit
#endif

struct SettingsView: View {
    // MARK: - Properties
    @Environment(\.managedObjectContext) private var viewContext
    @StateObject private var tipStore = TipStore()
    @StateObject private var syncManager = CloudKitSyncManager.shared
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
    
    private let logger = Logger(subsystem: "com.nicnark.nicnark-2", category: "Settings")

    var body: some View {
        Form {
            disclaimerSection
            appInfoSection
            cloudKitSyncSection
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
        }
        .sheet(isPresented: $showingFullDisclaimer) {
            FirstRunDisclaimerView(isPresented: $showingFullDisclaimer)
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
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Done") {
                            showingDiagnostics = false
                        }
                    }
                }
            }
        }
        .alert("Test Sync Complete", isPresented: .constant(isTestingSyncData && !isTestingSyncData)) {
            Button("OK") { }
        } message: {
            Text("CloudKit sync test completed. Check the console logs for details.")
        }
    }

    // MARK: - View Sections
    
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

    private var appInfoSection: some View {
        Section("App Information") {
            LabeledContent("Version", value: "1.0.0")
            LabeledContent("Developer", value: "Connor Needling")
        }
    }
    
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

    private var aboutSection: some View {
        Section("About") {
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
        }
    }

    // MARK: - Computed Properties
    
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
