//
//  InventoryManagementView.swift
//  nicnark-2
//
//  Dedicated inventory management interface for nicotine pouch cans
//

import SwiftUI
import CoreData

struct InventoryManagementView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss
    @StateObject private var canManager = CanManager.shared
    
    // Fetch all cans, including empty ones
    @FetchRequest(
        entity: Can.entity(),
        sortDescriptors: [
            NSSortDescriptor(keyPath: \Can.pouchCount, ascending: false),
            NSSortDescriptor(keyPath: \Can.dateAdded, ascending: false)
        ]
    ) private var allCans: FetchedResults<Can>
    
    @State private var showingAddCan = false
    @State private var showingBarcodeScanner = false
    @State private var scannedBarcode: String?
    @State private var selectedCan: Can?
    @State private var showingEditCan = false
    @State private var showingDeleteConfirmation = false
    @State private var canToDelete: Can?
    @State private var searchText = ""
    
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
    
    // MARK: - Views
    
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
    
    private var totalPouchCount: Int {
        allCans.reduce(0) { $0 + Int($1.pouchCount) }
    }
    
    private var emptyCansCount: Int {
        allCans.filter { $0.pouchCount == 0 }.count
    }
    
    // MARK: - Actions
    
    private func deleteItems(offsets: IndexSet) {
        withAnimation {
            offsets.map { filteredCans[$0] }.forEach(deleteCan)
        }
    }
    
    private func deleteCan(_ can: Can) {
        canManager.deleteCan(can, context: viewContext)
        canToDelete = nil
    }
}

// MARK: - Can Row View

struct CanRowView: View {
    let can: Can
    let onEdit: () -> Void
    let onDelete: () -> Void
    
    @State private var isExpanded = false
    
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
    
    private func incrementCount() {
        can.pouchCount = min(can.pouchCount + 1, 50)
        try? can.managedObjectContext?.save()
    }
    
    private func decrementCount() {
        can.pouchCount = max(can.pouchCount - 1, 0)
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
