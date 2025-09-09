//
//  InventoryManagementView.swift
//  nicnark-2
//
//  Dedicated inventory management interface for nicotine pouch cans
//
//  This view provides comprehensive can inventory management functionality:
//  • Display all cans with visual progress indicators and quick actions
//  • Add new cans manually or via barcode scanning
//  • Edit existing can details (brand, flavor, strength, pouch count)
//  • Delete cans with confirmation dialogs
//  • Search/filter cans by brand or flavor
//  • Expandable rows with additional details and quick increment/decrement
//  • Real-time sync with Core Data and CloudKit
//
//  The UI uses color-coded progress bars:
//  • Green: >50% pouches remaining (well-stocked)
//  • Orange: 20-50% remaining (running low)
//  • Red: <20% remaining (critical)
//
//  Integration points:
//  • CanManager singleton for centralized can operations
//  • BarcodeScannerView for camera-based barcode input
//  • CanDetailView for adding/editing can information
//  • Core Data with automatic CloudKit sync
//

import SwiftUI
import CoreData

/**
 * InventoryManagementView: Full-screen inventory management interface.
 * 
 * This view is presented modally from Settings and provides a dedicated
 * interface for managing the user's can inventory. It replaces the need
 * to manually track how many pouches remain in each can.
 * 
 * Key features:
 * - Visual progress indicators showing remaining pouches
 * - Barcode scanning for quick can addition
 * - Search functionality for large inventories
 * - Quick actions (edit, delete, adjust count) on each can
 * - Summary statistics at the top (total cans, pouches, empty cans)
 */
struct InventoryManagementView: View {
    // MARK: - Environment & State Management
    @Environment(\.managedObjectContext) private var viewContext  // Core Data context for database operations
    @Environment(\.dismiss) private var dismiss                    // Dismisses the modal presentation
    @StateObject private var canManager = CanManager.shared        // Singleton manager for can operations
    
    // MARK: - Core Data Fetch Request
    /// Fetches ALL cans from the database, including empty ones.
    /// Sorted by pouch count (fullest first) then by date added (newest first).
    /// This ensures the most relevant cans appear at the top of the list.
    @FetchRequest(
        entity: Can.entity(),
        sortDescriptors: [
            NSSortDescriptor(keyPath: \Can.pouchCount, ascending: false),  // Fullest cans first
            NSSortDescriptor(keyPath: \Can.dateAdded, ascending: false)    // Then newest first
        ]
    ) private var allCans: FetchedResults<Can>
    
    // MARK: - UI State Properties
    @State private var showingAddCan = false                      // Controls "Add Can" sheet presentation
    @State private var showingBarcodeScanner = false              // Controls barcode scanner sheet
    @State private var scannedBarcode: String?                    // Temporarily holds scanned barcode data
    @State private var selectedCan: Can?                          // Currently selected can for edit operations
    @State private var showingEditCan = false                     // Controls edit can sheet presentation
    @State private var showingDeleteConfirmation = false          // Shows delete confirmation alert
    @State private var canToDelete: Can?                          // Can pending deletion (awaiting confirmation)
    @State private var searchText = ""                            // Search filter text
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Summary header
                summaryHeader
                
                // Main content
                if allCans.isEmpty {
                    emptyStateView
                } else {
                    canListView
                }
            }
            .navigationTitle("Inventory Management")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button(action: { showingAddCan = true }) {
                            Label("Add Can Manually", systemImage: "plus.circle")
                        }
                        
                        Button(action: { showingBarcodeScanner = true }) {
                            Label("Scan Barcode", systemImage: "barcode.viewfinder")
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.body.bold())
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search cans...")
            .sheet(isPresented: $showingAddCan) {
                CanDetailView(barcode: scannedBarcode)
                    .environment(\.managedObjectContext, viewContext)
                    .onDisappear {
                        scannedBarcode = nil
                        canManager.fetchActiveCans(context: viewContext)
                    }
            }
            .sheet(isPresented: $showingEditCan) {
                if let can = selectedCan {
                    CanDetailView(editingCan: can)
                        .environment(\.managedObjectContext, viewContext)
                        .onDisappear {
                            selectedCan = nil
                            canManager.fetchActiveCans(context: viewContext)
                        }
                }
            }
            .sheet(isPresented: $showingBarcodeScanner) {
                BarcodeScannerView { barcode in
                    scannedBarcode = barcode
                    showingBarcodeScanner = false
                    
                    // Check if can with this barcode exists
                    if let existingCan = canManager.findCanByBarcode(barcode, context: viewContext) {
                        // Edit existing can
                        selectedCan = existingCan
                        showingEditCan = true
                    } else {
                        // Add new can with barcode
                        showingAddCan = true
                    }
                }
            }
            .alert("Delete Can?", isPresented: $showingDeleteConfirmation) {
                Button("Cancel", role: .cancel) {
                    canToDelete = nil
                }
                Button("Delete", role: .destructive) {
                    if let can = canToDelete {
                        deleteCan(can)
                    }
                }
            } message: {
                if let can = canToDelete {
                    Text("Delete \(can.brand ?? "this can") \(can.flavor ?? "")? This action cannot be undone.")
                }
            }
        }
    }
    
    // MARK: - View Components
    
    /**
     * Summary header showing aggregate inventory statistics.
     * Displays three key metrics:
     * - Total Cans: All cans in inventory (including empty)
     * - Total Pouches: Sum of all remaining pouches across all cans
     * - Empty Cans: Cans with 0 pouches (may need restocking)
     * 
     * Uses a gray background to visually separate from the main content.
     */
    private var summaryHeader: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading) {
                Text("Total Cans")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("\(allCans.count)")
                    .font(.title2.bold())
            }
            
            Divider()
                .frame(height: 40)
            
            VStack(alignment: .leading) {
                Text("Total Pouches")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("\(totalPouchCount)")
                    .font(.title2.bold())
                    .foregroundColor(.green)
            }
            
            Divider()
                .frame(height: 40)
            
            VStack(alignment: .leading) {
                Text("Empty Cans")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("\(emptyCansCount)")
                    .font(.title2.bold())
                    .foregroundColor(.orange)
            }
            
            Spacer()
        }
        .padding()
        .background(Color(.systemGray6))
    }
    
    /**
     * Empty state view shown when no cans are in inventory.
     * Provides:
     * - Visual indicator (tray icon)
     * - Helpful message explaining the empty state
     * - Two prominent action buttons (Add Can, Scan)
     * 
     * This encourages users to add their first can to get started.
     */
    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Spacer()
            
            Image(systemName: "tray.2")
                .font(.system(size: 60))
                .foregroundColor(.secondary)
            
            Text("No Cans in Inventory")
                .font(.title2.bold())
            
            Text("Add your first can to start tracking inventory")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            HStack(spacing: 15) {
                Button(action: { showingAddCan = true }) {
                    Label("Add Can", systemImage: "plus.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                
                Button(action: { showingBarcodeScanner = true }) {
                    Label("Scan", systemImage: "barcode.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 40)
            
            Spacer()
        }
        .padding()
    }
    
    /**
     * Main list view displaying all cans in inventory.
     * Each can is rendered as a CanRowView with:
     * - Visual progress indicator
     * - Brand, flavor, and strength information
     * - Quick action buttons (edit, delete)
     * - Expandable details section
     * 
     * Supports swipe-to-delete and search filtering.
     */
    private var canListView: some View {
        List {
            ForEach(filteredCans) { can in
                CanRowView(
                    can: can,
                    onEdit: { 
                        selectedCan = can
                        showingEditCan = true
                    },
                    onDelete: {
                        canToDelete = can
                        showingDeleteConfirmation = true
                    }
                )
            }
            .onDelete(perform: deleteItems)
        }
        .listStyle(InsetGroupedListStyle())
    }
    
    // MARK: - Computed Properties
    
    /**
     * Filters cans based on search text.
     * Searches both brand and flavor fields (case-insensitive).
     * Returns all cans if search is empty.
     */
    private var filteredCans: [Can] {
        if searchText.isEmpty {
            return Array(allCans)
        } else {
            return allCans.filter { can in
                let brand = can.brand?.lowercased() ?? ""
                let flavor = can.flavor?.lowercased() ?? ""
                let search = searchText.lowercased()
                return brand.contains(search) || flavor.contains(search)
            }
        }
    }
    
    /**
     * Calculates total number of pouches across all cans.
     * Used in the summary header to show overall inventory level.
     */
    private var totalPouchCount: Int {
        allCans.reduce(0) { $0 + Int($1.pouchCount) }
    }
    
    /**
     * Counts how many cans have 0 pouches remaining.
     * Useful for identifying cans that need restocking.
     */
    private var emptyCansCount: Int {
        allCans.filter { $0.pouchCount == 0 }.count
    }
    
    // MARK: - Actions
    
    /**
     * Handles swipe-to-delete action from the list.
     * Maps the index to the actual can and deletes it.
     * 
     * - Parameter offsets: IndexSet of rows to delete
     */
    private func deleteItems(offsets: IndexSet) {
        withAnimation {
            offsets.map { filteredCans[$0] }.forEach(deleteCan)
        }
    }
    
    /**
     * Deletes a can from inventory.
     * Uses CanManager to handle the Core Data deletion and sync.
     * Clears the canToDelete reference after deletion.
     * 
     * - Parameter can: The Can entity to delete
     */
    private func deleteCan(_ can: Can) {
        canManager.deleteCan(can, context: viewContext)
        canToDelete = nil
    }
}

// MARK: - Can Row View

/**
 * CanRowView: Individual row component for displaying a can in the inventory list.
 * 
 * Features an expandable design with two states:
 * 1. Collapsed: Shows icon, name, strength, count, progress bar, and action buttons
 * 2. Expanded: Additionally shows date added, barcode, and quick adjustment buttons
 * 
 * Visual feedback:
 * - Color-coded icon and progress bar based on remaining pouches
 * - Badge overlay showing exact pouch count
 * - Animated expansion/collapse with spring animation
 * - Press effects for better touch feedback
 * 
 * - Parameter can: The Can entity to display
 * - Parameter onEdit: Closure called when edit button is tapped
 * - Parameter onDelete: Closure called when delete button is tapped
 */
struct CanRowView: View {
    let can: Can                           // The can entity to display
    let onEdit: () -> Void                 // Edit action handler
    let onDelete: () -> Void               // Delete action handler
    
    @State private var isExpanded = false  // Tracks expanded/collapsed state
    
    /**
     * Determines the color for progress indicators based on remaining percentage.
     * - Green: >50% remaining (well stocked)
     * - Orange: 20-50% remaining (running low)
     * - Red: <20% remaining (critical - needs restocking)
     */
    private var progressColor: Color {
        let percentage = Double(can.pouchCount) / Double(can.initialCount)
        if percentage > 0.5 {
            return .green
        } else if percentage > 0.2 {
            return .orange
        } else {
            return .red
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Main row content
            HStack {
                // Can icon with count badge
                ZStack(alignment: .topTrailing) {
                    Image(systemName: can.pouchCount > 0 ? "cylinder.fill" : "cylinder")
                        .font(.largeTitle)
                        .foregroundColor(can.pouchCount > 0 ? progressColor : .gray)
                    
                    if can.pouchCount > 0 {
                        Text("\(can.pouchCount)")
                            .font(.caption2.bold())
                            .foregroundColor(.white)
                            .padding(4)
                            .background(progressColor)
                            .clipShape(Circle())
                            .offset(x: 8, y: -5)
                    }
                }
                .frame(width: 50)
                
                // Can details
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(can.brand ?? "Unknown") \(can.flavor ?? "")")
                        .font(.headline)
                        .lineLimit(1)
                    
                    HStack {
                        Text("\(Int(can.strength))mg")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        
                        if can.duration > 0 {
                            Text("• \(can.duration)min timer")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        if can.barcode != nil {
                            Image(systemName: "barcode")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    // Progress bar
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color(.systemGray5))
                                .frame(height: 4)
                            
                            RoundedRectangle(cornerRadius: 2)
                                .fill(progressColor)
                                .frame(
                                    width: geometry.size.width * (Double(can.pouchCount) / Double(can.initialCount)),
                                    height: 4
                                )
                        }
                    }
                    .frame(height: 4)
                    
                    Text("\(can.pouchCount) of \(can.initialCount) pouches remaining")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                // Action buttons
                VStack(spacing: 8) {
                    Button(action: onEdit) {
                        Image(systemName: "pencil.circle.fill")
                            .font(.title2)
                            .foregroundColor(.blue)
                    }
                    
                    Button(action: onDelete) {
                        Image(systemName: "trash.circle.fill")
                            .font(.title2)
                            .foregroundColor(.red)
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.spring(response: 0.3)) {
                    isExpanded.toggle()
                }
            }
            
            // Expanded details
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    Divider()
                    
                    HStack {
                        Label("Added", systemImage: "calendar")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Spacer()
                        
                        if let date = can.dateAdded {
                            Text(date, style: .date)
                                .font(.caption)
                        }
                    }
                    
                    if let barcode = can.barcode {
                        HStack {
                            Label("Barcode", systemImage: "barcode")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            Spacer()
                            
                            Text(barcode)
                                .font(.caption.monospaced())
                                .lineLimit(1)
                        }
                    }
                    
                    // Quick actions
                    HStack(spacing: 12) {
                        Button(action: { incrementCount() }) {
                            Label("Add Pouch", systemImage: "plus.circle")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(can.pouchCount >= 50)
                        
                        Button(action: { decrementCount() }) {
                            Label("Remove Pouch", systemImage: "minus.circle")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(can.pouchCount <= 0)
                        
                        Spacer()
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 8)
    }
    
    /**
     * Increments the pouch count by 1 (max 50).
     * Used for quick adjustments without opening the edit sheet.
     * Saves immediately to Core Data for instant sync.
     */
    private func incrementCount() {
        can.pouchCount = min(can.pouchCount + 1, 50)  // Cap at 50 pouches
        try? can.managedObjectContext?.save()
    }
    
    /**
     * Decrements the pouch count by 1 (min 0).
     * Used for manual adjustments when pouches are used outside the app.
     * Saves immediately to Core Data for instant sync.
     */
    private func decrementCount() {
        can.pouchCount = max(can.pouchCount - 1, 0)   // Floor at 0 pouches
        try? can.managedObjectContext?.save()
    }
}

// MARK: - Preview

struct InventoryManagementView_Previews: PreviewProvider {
    static var previews: some View {
        InventoryManagementView()
            .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
    }
}
