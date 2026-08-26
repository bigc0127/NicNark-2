// Import necessary frameworks and libraries
import SwiftUI           // For building the user interface
import CoreData          // For database operations (storing pouch logs)
import BackgroundTasks   // For background processing
import WidgetKit         // For home screen widgets

/**
 * ContentView: The main view of the app that contains the tab bar interface
 * This struct conforms to the View protocol, making it a SwiftUI view
 */
struct ContentView: View {
    // MARK: - Environment Properties
    // @Environment gets values from the SwiftUI environment (shared across the app)
    @Environment(\.managedObjectContext) private var viewContext  // Core Data database context
    
    // MARK: - State Properties
    // @StateObject creates and manages an observable object (like a view model)
    @StateObject private var liveActivityManager = LiveActivityManager.shared  // Manages Live Activities (shared singleton)
    @StateObject private var syncManager = CloudKitSyncManager.shared  // Manages CloudKit sync
    
    // @State creates local state that the view owns and can modify
    @State private var selectedTab: Int = 0        // Which tab is currently selected (0=Log, 1=Levels, 2=Usage)
    @State private var showingSettings = false     // Whether the settings sheet is shown
    @State private var showingFirstRunDisclaimer = false  // Whether to show the first-run disclaimer
    @State private var showingInsights = false     // Whether the Insights hub sheet is shown
    @State private var showingWhatsNew = false      // Whether the What's New greeter is shown
    @State private var showingInventory = false    // Inventory from notification tap
    
    // MARK: - Device Layout Properties
    // Track device orientation and size for better iPad support
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass  // Compact or regular width
    @Environment(\.verticalSizeClass) private var verticalSizeClass      // Compact or regular height
    @Environment(\.scenePhase) private var scenePhase  // Track app lifecycle (active/background/inactive)

    // MARK: - Main View Body
    // The 'body' is a computed property that returns the view's content
    var body: some View {
        // TabView creates a tab bar interface with multiple tabs
        // $selectedTab binds the selection to our @State variable ($ creates a binding)
        TabView(selection: $selectedTab) {

            Tab("Log", systemImage: "list.bullet", value: 0) {
                NavigationStack {
                    LogView()
                        .environmentObject(liveActivityManager)
                        .toolbar {
                            ToolbarItem(placement: .navigationBarLeading) {
                                Button {
                                    showingInsights = true
                                } label: {
                                    Image(systemName: "chart.bar.xaxis")
                                }
                            }
                            ToolbarItem(placement: .navigationBarTrailing) {
                                Button {
                                    showingSettings = true
                                } label: {
                                    Image(systemName: liveActivityManager.hasActiveNotification ? "gear.badge" : "gear")
                                }
                            }
                        }
                }
                .sheet(isPresented: $showingSettings) {
                    NavigationStack {
                        SettingsView()
                            .navigationTitle("Settings")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement: .navigationBarTrailing) {
                                    Button("Done") { showingSettings = false }
                                }
                            }
                    }
                }
                .sheet(isPresented: $showingInsights) {
                    NavigationStack {
                        InsightsView()
                    }
                }
            }

            Tab("Levels", systemImage: "chart.line.uptrend.xyaxis", value: 1) {
                NavigationStack {
                    NicotineLevelView()
                }
            }

            Tab("Usage", systemImage: "chart.bar", value: 2) {
                NavigationStack {
                    UsageGraphView()
                }
            }
        }
        // MARK: - First-Run Disclaimer
        // Show comprehensive disclaimer on first app launch for App Store compliance
        .sheet(isPresented: $showingFirstRunDisclaimer) {
            FirstRunDisclaimerView(isPresented: $showingFirstRunDisclaimer)
        }
        // What's New greeter for this update. On a fresh install it appears right after the
        // disclaimer is dismissed; on an update it's triggered from .task below.
        .sheet(isPresented: $showingWhatsNew) {
            WhatsNewView(isPresented: $showingWhatsNew)
        }
        .onChange(of: showingFirstRunDisclaimer) { _, isShowing in
            if !isShowing && !UserDefaults.standard.hasShownWhatsNew_v2_6 {
                showingWhatsNew = true
            }
        }
        
        // URL scheme handling (nicnark2://log?mg=6) is registered ONCE at the app
        // level in nicnark_2App.body. It was previously also registered here, which
        // double-logged every deep-linked pouch.

        // Inventory (full can management), not Settings root — matches NavigateToCanManagement.
        .sheet(isPresented: $showingInventory) {
            NavigationStack {
                InventoryManagementView()
            }
        }
        // MARK: - Notification tap navigation
        // NotificationDelegate posts these; wire them so taps actually switch tabs / open sheets.
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("NavigateToCanManagement"))) { _ in
            selectedTab = 0
            // Dismiss competing modals first. Do NOT touch first-run disclaimer / WhatsNew
            // flags — clearing those @State can fire onChange → WhatsNew sheet races inventory.
            showingSettings = false
            showingInsights = false
            // Match inventory scanner defer (~0.35s dismiss animation); one runloop is too short.
            // Skip if user already opened another sheet in the window during the defer.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                guard !showingSettings, !showingInsights,
                      !showingWhatsNew, !showingFirstRunDisclaimer,
                      !showingInventory else { return }
                showingInventory = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("ShowQuickLog"))) { _ in
            selectedTab = 0
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("NavigateToNicotineLevels"))) { _ in
            selectedTab = 1
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("NavigateToUsageStats"))) { _ in
            selectedTab = 2
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("NavigateToUsageGraph"))) { _ in
            selectedTab = 2
        }

        // MARK: - App Initialization
        // .task runs when the view appears (similar to viewDidLoad in UIKit)
        .task {
            // Clear any stale notification badges when app opens
            NotificationManager.clearBadge()
            
            // Check if we need to show the first-run disclaimer
            if !UserDefaults.standard.hasShownFirstRunDisclaimer {
                // Delay slightly to ensure UI is ready
                try? await Task.sleep(for: .seconds(0.5))
                showingFirstRunDisclaimer = true
            } else if !UserDefaults.standard.hasShownWhatsNew_v2_6 {
                // Disclaimer was accepted on a previous launch; show the What's New greeter
                // for this update instead.
                try? await Task.sleep(for: .seconds(0.5))
                showingWhatsNew = true
            }

            // Set up background tasks for Live Activity updates
            await BackgroundMaintainer.shared.registerIfNeeded()  // Register background task types
            await BackgroundMaintainer.shared.scheduleRegular()   // Schedule recurring updates
        }
        
        // MARK: - Scene Phase Changes
        // Clear notification badge when app becomes active (user returns from background)
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                // Clear any notification badges when user opens the app
                NotificationManager.clearBadge()
                // Re-arm configured notifications with fresh data. The daily summary uses a
                // non-repeating trigger (so its baked-in stats can't go stale), so it must be
                // re-scheduled each time the app becomes active to keep recurring.
                NotificationManager.scheduleConfiguredNotifications()
            }
        }
    }
}

#Preview {
    ContentView()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
}
