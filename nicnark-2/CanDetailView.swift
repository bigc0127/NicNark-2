//
//  CanDetailView.swift
//  nicnark-2
//
//  Can detail view for adding/editing cans in v2.0
//

import SwiftUI
import CoreData

struct CanDetailView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss
    @StateObject private var canManager = CanManager.shared
    
    let editingCan: Can?
    let initialBarcode: String?
    
    @State private var brand = ""
    @State private var flavor = ""
    @State private var strength: Double = 6.0
    @State private var pouchCount: Int = 20
    @State private var barcode = ""
    @State private var showingBarcodeScanner = false
    @State private var hasCustomDuration = false
    @State private var duration: Int = 30  // Default 30 minutes
    
    init(editingCan: Can? = nil, barcode: String? = nil) {
        self.editingCan = editingCan
        self.initialBarcode = barcode
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Brand Information")) {
                    TextField("Brand Name", text: $brand)
                        .textInputAutocapitalization(.words)
                    
                    TextField("Flavor (optional)", text: $flavor)
                        .textInputAutocapitalization(.words)
                }
                
                Section(header: Text("Nicotine Strength")) {
                    HStack {
                        Text("Strength:")
                        Spacer()
                        Text("\(Int(strength))mg")
                            .fontWeight(.semibold)
                    }
                    
                    Slider(value: $strength, in: 1...20, step: 1)
                }
                
                Section(header: Text("Pouch Count")) {
                    Stepper(value: $pouchCount, in: 1...50) {
                        HStack {
                            Text("Pouches in can:")
                            Spacer()
                            Text("\(pouchCount)")
                                .fontWeight(.semibold)
                        }
                    }
                }
                
                Section(header: Text("Timer Duration (Optional)")) {
                    Toggle("Custom Timer Duration", isOn: $hasCustomDuration)
                    
                    if hasCustomDuration {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Duration:")
                                Spacer()
                                Text("\(duration) minutes")
                                    .fontWeight(.semibold)
                            }
                            
                            Slider(value: Binding(
                                get: { Double(duration) },
                                set: { duration = Int($0) }
                            ), in: 5...120, step: 5)
                            
                            Text("This brand's recommended pouch duration")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Text("Will use your default timer settings")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Section(header: Text("Barcode (Optional)")) {
                    HStack {
                        TextField("Barcode", text: $barcode)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        
                        Button(action: {
                            showingBarcodeScanner = true
                        }) {
                            Image(systemName: "barcode.viewfinder")
                                .font(.title2)
                        }
                    }
                    
                    Text("Scan or enter barcode for quick add in the future")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                if editingCan == nil {
                    Section {
                        Button(action: checkForExistingBarcode) {
                            HStack {
                                Image(systemName: "magnifyingglass")
                                Text("Check if barcode exists")
                            }
                        }
                        .disabled(barcode.isEmpty)
                    }
                }
            }
            .navigationTitle(editingCan == nil ? "Add Can" : "Edit Can")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        saveCan()
                    }
                    .disabled(brand.isEmpty)
                }
            }
        }
        .onAppear {
            if let can = editingCan {
                brand = can.brand ?? ""
                flavor = can.flavor ?? ""
                strength = can.strength
                pouchCount = Int(can.pouchCount)
                barcode = can.barcode ?? ""
                // Load duration if set
                if can.duration > 0 {
                    hasCustomDuration = true
                    duration = Int(can.duration)
                }
            } else if let initialBarcode = initialBarcode {
                // Pre-fill barcode if provided
                barcode = initialBarcode
                // First check for CanTemplate data
                if let template = canManager.findCanTemplateByBarcode(initialBarcode, context: viewContext) {
                    brand = template.brand ?? ""
                    flavor = template.flavor ?? ""
                    strength = template.strength
                    // Load duration from template if set
                    if template.duration > 0 {
                        hasCustomDuration = true
                        duration = Int(template.duration)
                    }
                    // Keep default pouch count for new can
                } else if let existingCan = canManager.findCanByBarcode(initialBarcode, context: viewContext) {
                    // Fall back to existing can data if no template
                    brand = existingCan.brand ?? ""
                    flavor = existingCan.flavor ?? ""
                    strength = existingCan.strength
                    if existingCan.duration > 0 {
                        hasCustomDuration = true
                        duration = Int(existingCan.duration)
                    }
                    // Keep default pouch count for new can
                }
            }
        }
        .sheet(isPresented: $showingBarcodeScanner) {
            BarcodeScannerView { scannedBarcode in
                barcode = scannedBarcode
                showingBarcodeScanner = false
                
                // Check if this barcode already exists
                if let template = canManager.findCanTemplateByBarcode(scannedBarcode, context: viewContext) {
                    // Pre-fill with template data
                    brand = template.brand ?? ""
                    flavor = template.flavor ?? ""
                    strength = template.strength
                    if template.duration > 0 {
                        hasCustomDuration = true
                        duration = Int(template.duration)
                    }
                    // Keep the new pouch count
                } else if let existingCan = canManager.findCanByBarcode(scannedBarcode, context: viewContext) {
                    // Fall back to existing can data if no template
                    brand = existingCan.brand ?? ""
                    flavor = existingCan.flavor ?? ""
                    strength = existingCan.strength
                    if existingCan.duration > 0 {
                        hasCustomDuration = true
                        duration = Int(existingCan.duration)
                    }
                    // Keep the new pouch count
                }
            }
        }
    }
    
    private func checkForExistingBarcode() {
        if let template = canManager.findCanTemplateByBarcode(barcode, context: viewContext) {
            // Pre-fill with template data
            brand = template.brand ?? ""
            flavor = template.flavor ?? ""
            strength = template.strength
            if template.duration > 0 {
                hasCustomDuration = true
                duration = Int(template.duration)
            }
        } else if let existingCan = canManager.findCanByBarcode(barcode, context: viewContext) {
            // Fall back to existing can data if no template
            brand = existingCan.brand ?? ""
            flavor = existingCan.flavor ?? ""
            strength = existingCan.strength
            if existingCan.duration > 0 {
                hasCustomDuration = true
                duration = Int(existingCan.duration)
            }
        }
    }
    
    private func saveCan() {
        if let can = editingCan {
            // Update existing can
            can.brand = brand
            can.flavor = flavor.isEmpty ? nil : flavor
            can.strength = round(strength)  // Round to avoid floating-point precision issues
            can.pouchCount = Int32(pouchCount)
            can.barcode = barcode.isEmpty ? nil : barcode
            can.duration = hasCustomDuration ? Int32(duration) : 0
            
            // Also update CanTemplate if barcode is provided
            if let barcode = can.barcode, !barcode.isEmpty {
                canManager.createOrUpdateCanTemplate(
                    barcode: barcode,
                    brand: brand,
                    flavor: flavor.isEmpty ? nil : flavor,
                    strength: round(strength),  // Round to avoid floating-point precision issues
                    duration: hasCustomDuration ? duration : 0,
                    context: viewContext
                )
            }
            
            do {
                try viewContext.save()
                // Check inventory levels for notifications
                NotificationManager.checkCanInventory(context: viewContext)
            } catch {
                print("Failed to update can: \(error)")
            }
        } else {
            // Create new can (createCan already handles CanTemplate creation)
            _ = canManager.createCan(
                brand: brand,
                flavor: flavor.isEmpty ? nil : flavor,
                strength: round(strength),  // Round to avoid floating-point precision issues
                pouchCount: pouchCount,
                barcode: barcode.isEmpty ? nil : barcode,
                duration: hasCustomDuration ? duration : 0,
                context: viewContext
            )
            // Check inventory levels for notifications
            NotificationManager.checkCanInventory(context: viewContext)
        }
        
        canManager.fetchActiveCans(context: viewContext)
        dismiss()
    }
}

struct CanDetailView_Previews: PreviewProvider {
    static var previews: some View {
        CanDetailView()
            .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
    }
}
