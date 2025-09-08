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
    
    @State private var brand = ""
    @State private var flavor = ""
    @State private var strength: Double = 6
    @State private var pouchCount: Int = 20
    @State private var barcode = ""
    @State private var showingBarcodeScanner = false
    
    let editingCan: Can?
    
    init(editingCan: Can? = nil) {
        self.editingCan = editingCan
    }
    
    var body: some View {
        NavigationView {
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
            }
        }
        .sheet(isPresented: $showingBarcodeScanner) {
            BarcodeScannerView { scannedBarcode in
                barcode = scannedBarcode
                showingBarcodeScanner = false
                
                // Check if this barcode already exists
                if let existingCan = canManager.findCanByBarcode(scannedBarcode, context: viewContext) {
                    // Pre-fill with existing can data
                    brand = existingCan.brand ?? ""
                    flavor = existingCan.flavor ?? ""
                    strength = existingCan.strength
                    // Keep the new pouch count
                }
            }
        }
    }
    
    private func checkForExistingBarcode() {
        if let existingCan = canManager.findCanByBarcode(barcode, context: viewContext) {
            // Pre-fill with existing can data
            brand = existingCan.brand ?? ""
            flavor = existingCan.flavor ?? ""
            strength = existingCan.strength
        }
    }
    
    private func saveCan() {
        if let can = editingCan {
            // Update existing can
            can.brand = brand
            can.flavor = flavor.isEmpty ? nil : flavor
            can.strength = strength
            can.pouchCount = Int32(pouchCount)
            can.barcode = barcode.isEmpty ? nil : barcode
            
            do {
                try viewContext.save()
            } catch {
                print("Failed to update can: \(error)")
            }
        } else {
            // Create new can
            _ = canManager.createCan(
                brand: brand,
                flavor: flavor.isEmpty ? nil : flavor,
                strength: strength,
                pouchCount: pouchCount,
                barcode: barcode.isEmpty ? nil : barcode,
                context: viewContext
            )
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
