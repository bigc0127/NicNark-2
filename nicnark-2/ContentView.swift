// Import necessary frameworks and libraries
import SwiftUI           // For building the user interface
import CoreData          // For database operations (storing pouch logs)
import TipKit            // For in-app tips and hints
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
    @StateObject private var liveActivityManager = LiveActivityManager()  // Manages Live Activities
    @StateObject private var syncManager = CloudKitSyncManager.shared  // Manages CloudKit sync
    
    // @State creates local state that the view owns and can modify
    @State private var selectedTab: Int = 0        // Which tab is currently selected (0=Log, 1=Levels, 2=Usage)
    @State private var showingSettings = false     // Whether the settings sheet is shown
    @State private var showingFirstRunDisclaimer = false  // Whether to show the first-run disclaimer
    
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
            
            // MARK: - Tab 1: Log Tab (Main pouch logging interface)
            NavigationStack {  // NavigationStack provides navigation capabilities (back/forward)
                LogView()  // The main view where users log pouches
                    .environmentObject(liveActivityManager)  // Pass the live activity manager to LogView
                    .toolbar {  // Add toolbar items to the navigation bar
                        ToolbarItem(placement: .navigationBarTrailing) {  // Put item on right side of nav bar
                            Button {
                                // When button is tapped, show the settings sheet
                                showingSettings = true
                            } label: {
                                // Show different gear icon if there are active notifications
                                Image(systemName: liveActivityManager.hasActiveNotification ? "gear.badge" : "gear")
                            }
                        }
                    }
            }
            // .sheet presents a modal view (settings) when showingSettings becomes true
            .sheet(isPresented: $showingSettings) {
                NavigationStack {
                    SettingsView()  // The settings interface
                        .navigationTitle("Settings")  // Title for the settings view
                        .navigationBarTitleDisplayMode(.inline)  // Small title style
                        .toolbar {
                            ToolbarItem(placement: .navigationBarTrailing) {
                                // Done button to dismiss the settings sheet
                                Button("Done") { showingSettings = false }
                            }
                        }
                }
            }
            .tabItem {  // Define what appears in the tab bar for this tab
                Image(systemName: "list.bullet")  // Tab icon
                Text("Log")  // Tab label
            }
            .tag(0)  // Unique identifier for this tab

            // MARK: - Tab 2: Nicotine Levels Tab (Charts and graphs)
            NavigationStack {
                NicotineLevelView()  // View showing nicotine level over time
            }
            .tabItem {
                Image(systemName: "chart.line.uptrend.xyaxis")  // Chart icon
                Text("Levels")  // Tab label
            }
            .tag(1)  // Unique identifier for this tab

            // MARK: - Tab 3: Usage Statistics Tab
            NavigationStack {
                UsageGraphView()  // View showing usage patterns and statistics
            }
            .tabItem {
                Image(systemName: "chart.bar")  // Bar chart icon
                Text("Usage")  // Tab label
            }
            .tag(2)  // Unique identifier for this tab
        }
        // MARK: - First-Run Disclaimer
        // Show comprehensive disclaimer on first app launch for App Store compliance
        .sheet(isPresented: $showingFirstRunDisclaimer) {
            FirstRunDisclaimerView(isPresented: $showingFirstRunDisclaimer)
        }
        
        // MARK: - URL Scheme Handling
        // Handle custom URL schemes like "nicnark2://log?mg=6" (from shortcuts, web links, etc.)
        .onOpenURL { url in
            print("📱 Received URL: \(url)")  // Debug logging
            
            // DispatchQueue.main.async ensures UI updates happen on the main thread
            // (iOS requires all UI updates to happen on the main thread)
            DispatchQueue.main.async {
                // LogPouchRouter parses the URL and logs the pouch if valid
                let success = LogPouchRouter.handle(
                    url: url,
                    ctx: viewContext  // Pass database context for saving
                )
                
                if success {
                    print("📱 Successfully handled URL: \(url)")
                    // Update all home screen widgets after logging
                    WidgetCenter.shared.reloadAllTimelines()
                } else {
                    print("📱 Failed to handle URL: \(url)")
                }
            }
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
            }
            
            // Configure TipKit for in-app tips and tutorials
            do {
                try Tips.configure([
                    .displayFrequency(.immediate),        // Show tips immediately when available
                    .datastoreLocation(.applicationDefault) // Use default storage location
                ])
            } catch {
                print("Failed to configure TipKit: \(error)")
            }

            // Set up background tasks for Live Activity updates (iOS 16.1+ only)
            if #available(iOS 16.1, *) {
                await BackgroundMaintainer.shared.registerIfNeeded()  // Register background task types
                await BackgroundMaintainer.shared.scheduleRegular()   // Schedule recurring updates
            }
        }
        
        // MARK: - Scene Phase Changes
        // Clear notification badge when app becomes active (user returns from background)
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                // Clear any notification badges when user opens the app
                NotificationManager.clearBadge()
            }
        }
    }
}

#Preview {
    ContentView()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
}
