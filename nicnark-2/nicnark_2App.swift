//
// nicnark_2App.swift
// nicnark-2
//
// The main app entry point - this is where the app starts when launched
// Created by Connor Needling on 8/3/25.
//

// Import necessary frameworks
import SwiftUI    // For building the user interface
import WidgetKit  // For managing home screen widgets
import BackgroundTasks  // For background task scheduling
import CoreData   // For viewContext access

/**
 * @main: This attribute tells Swift this is the app's entry point (where execution begins)
 * 
 * nicnark_2App: The root app structure that conforms to the App protocol
 * This handles app-wide configuration, initialization, and the main window setup
 */
@main
struct nicnark_2App: App {
    // MARK: - Core Data Setup
    // Create a shared Core Data persistence controller (database manager)
    // This manages the SQLite database where pouch logs and settings are stored
    let persistenceController = PersistenceController.shared
    
    // MARK: - Background Task Registration
    // Register background task handlers synchronously to avoid crashes
    private func registerBackgroundTasks() {
        #if os(iOS)
        if #available(iOS 13.0, *) {
            BGTaskScheduler.shared.register(
                forTaskWithIdentifier: "com.nicnark.nicnark-2.bg.refresh",
                using: nil
            ) { task in
                Task { @MainActor in
                    if #available(iOS 16.1, *),
                       let refreshTask = task as? BGAppRefreshTask {
                        await BackgroundMaintainer.shared.handleRefresh(refreshTask)
                    } else {
                        task.setTaskCompleted(success: false)
                    }
                }
            }

            BGTaskScheduler.shared.register(
                forTaskWithIdentifier: "com.nicnark.nicnark-2.bg.process",
                using: nil
            ) { task in
                Task { @MainActor in
                    if #available(iOS 16.1, *),
                       let processTask = task as? BGProcessingTask {
                        await BackgroundMaintainer.shared.handleProcess(processTask)
                    } else {
                        task.setTaskCompleted(success: false)
                    }
                }
            }
        }
        #endif
    }

    // MARK: - App Initialization
    /**
     * init(): Called when the app is first created (before any UI appears)
     * This is where we set up app-wide configurations that need to happen early
     */
    init() {
        // Set up push notifications for pouch completion alerts
        NotificationManager.configure()

        // Enable WatchConnectivity message handling for Apple Watch actions.
        // (No-op on devices that don't support WCSession.)
        WatchConnectivityBridge.shared.start()
        
        // MARK: - Background Task Registration
        // CRITICAL: Register background task handlers SYNCHRONOUSLY before app finishes launching
        // This must happen in init() to avoid NSInternalInconsistencyException
        registerBackgroundTasks()
        
        // MARK: - iPad Compatibility Configuration
        // Force iPhone behavior even on iPad for consistent user experience
        // This prevents iPad-specific UI patterns (like split screen sidebars)
        #if os(iOS)  // Only compile this code for iOS (not macOS, watchOS, etc.)
        if UIDevice.current.userInterfaceIdiom == .pad {  // Check if running on iPad
            // Use Objective-C runtime to set iPad to behave like iPhone
            // This is a low-level approach to force iPhone-style layouts on iPad
            if let cls = NSClassFromString("UIDevice") as? NSObject.Type,
               cls.responds(to: Selector(("setPreferredUserInterfaceIdiom:"))) {
                // Set userInterfaceIdiom to phone (1) instead of pad (2)
                // 0=unspecified, 1=phone, 2=pad
                cls.perform(Selector(("setPreferredUserInterfaceIdiom:")), with: 1 as NSNumber)
            }
        }
        #endif
    }

    // MARK: - App Scene Configuration
    /**
     * body: Defines the app's scene structure (windows, interface, etc.)
     * In SwiftUI, a Scene represents a part of your app's user interface
     * WindowGroup creates a standard window that can have multiple instances
     */
    var body: some Scene {
        WindowGroup {  // Creates the main app window
            ContentView()  // The root view containing the tab bar interface
                // Provide the Core Data context to all child views
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
                
                // MARK: - iPad Layout Constraints
                // Limit width on iPad to prevent overly wide layouts (like iPhone style)
                .frame(maxWidth: UIDevice.current.userInterfaceIdiom == .pad ? 500 : .infinity)
                .frame(maxHeight: .infinity)  // Allow full height on all devices
                .background(Color(.systemBackground))  // Use system background color (adapts to light/dark mode)
                
                // MARK: - URL Scheme Handling
                // Handle custom URL schemes like "nicnark2://log?mg=6"
                // This allows the app to be opened from Safari, shortcuts, or other apps
                .onOpenURL { url in
                    print("📱 Received URL: \(url)")  // Debug logging to console
                    
                    // All UI operations must happen on the main thread in iOS
                    DispatchQueue.main.async {
                        // LogPouchRouter parses the URL and extracts the nicotine amount
                        let success = LogPouchRouter.handle(
                            url: url,
                            ctx: persistenceController.container.viewContext
                        )
                        
                        if success {
                            print("📱 Successfully handled URL: \(url)")
                            // Tell all home screen widgets to refresh their data
                            WidgetCenter.shared.reloadAllTimelines()
                        } else {
                            print("📱 Failed to handle URL: \(url)")
                        }
                    }
                }
                
                // MARK: - App Launch Configuration
                // Set up services when the app interface appears
                .onAppear {
                    // Set up notification handling (for when notifications are tapped)
                    UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
                    // Initialize the notification system (idempotent, safe to call again)
                    NotificationManager.configure()
                    
                    // Schedule all configured notifications based on user settings
                    Task { @MainActor in
                        NotificationManager.scheduleConfiguredNotifications()
                    }
                    
                    // Schedule background tasks (handlers already registered in init)
                    if #available(iOS 16.1, *) {
                        Task {
                            // Only schedule tasks, registration already done in init()
                            await BackgroundMaintainer.shared.scheduleRegular()
                        }
                    }
                }
        }
    }
}
