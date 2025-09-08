//
// PouchEditView.swift
// nicnark-2
//
// Modal view for editing pouch details with validation and Core Data updates
//

import SwiftUI
import CoreData
import WidgetKit

struct PouchEditView: View {
    // MARK: - Properties
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss
    
    let pouchLog: PouchLog
    let onSave: () -> Void
    let onDelete: () -> Void
    
    // MARK: - State
    @State private var insertionTime: Date
    @State private var removalTime: Date?
    @State private var nicotineAmount: String
    @State private var hasRemovalTime: Bool
    
    @State private var showingDeleteAlert = false
    @State private var showingError = false
    @State private var errorMessage = ""
    
    // MARK: - Computed Properties
    private var isValid: Bool {
        guard let amount = Double(nicotineAmount), amount > 0, amount <= 100 else { return false }
        if let removal = removalTime {
            return removal >= insertionTime
        }
        return true
    }
    
    // MARK: - Initialization
    init(pouchLog: PouchLog, onSave: @escaping () -> Void, onDelete: @escaping () -> Void) {
        self.pouchLog = pouchLog
        self.onSave = onSave
        self.onDelete = onDelete
        
        // Initialize state from pouch data
        _insertionTime = State(initialValue: pouchLog.insertionTime ?? Date())
        _removalTime = State(initialValue: pouchLog.removalTime)
        _nicotineAmount = State(initialValue: String(format: "%.1f", pouchLog.nicotineAmount))
        _hasRemovalTime = State(initialValue: pouchLog.removalTime != nil)
    }
    
    var body: some View {
        NavigationStack {
            Form {
                timingSection
                nicotineSection
                actionsSection
            }
            .navigationTitle("Edit Pouch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        savePouch()
                    }
                    .fontWeight(.semibold)
                    .disabled(!isValid)
                }
            }
        }
        .alert("Delete Pouch", isPresented: $showingDeleteAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                deletePouch()
            }
        } message: {
            Text("Are you sure you want to delete this pouch? This action cannot be undone.")
        }
        .alert("Error", isPresented: $showingError) {
            Button("OK") { }
        } message: {
            Text(errorMessage)
        }
    }
    
    // MARK: - View Sections
    
    private var timingSection: some View {
        Section {
            DatePicker("Insertion Time", selection: $insertionTime, displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.compact)
            
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Has removal time", isOn: $hasRemovalTime)
                
                if hasRemovalTime {
                    DatePicker("Removal Time", selection: Binding(
                        get: { removalTime ?? insertionTime.addingTimeInterval(30 * 60) },
                        set: { removalTime = $0 }
                    ), in: insertionTime..., displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.compact)
                } else {
                    Text("Currently active - no removal time set")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        } header: {
            Text("Timing")
        } footer: {
            if hasRemovalTime, let removal = removalTime {
                let duration = removal.timeIntervalSince(insertionTime)
                Text("Duration: \(formatDuration(duration))")
                    .font(.caption)
            }
        }
    }
    
    private var nicotineSection: some View {
        Section {
            HStack {
                TextField("Amount", text: $nicotineAmount)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                
                Text("mg")
                    .foregroundColor(.secondary)
            }
            
            if let amount = Double(nicotineAmount), amount > 0 {
                let maxAbsorbed = amount * ABSORPTION_FRACTION
                Text("Max absorption: \(String(format: "%.3f", maxAbsorbed)) mg")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        } header: {
            Text("Nicotine Amount")
        } footer: {
            if !nicotineAmount.isEmpty && Double(nicotineAmount) == nil {
                Text("Please enter a valid number")
                    .foregroundColor(.red)
            } else if let amount = Double(nicotineAmount), amount <= 0 {
                Text("Amount must be greater than 0")
                    .foregroundColor(.red)
            } else if let amount = Double(nicotineAmount), amount > 100 {
                Text("Amount seems unusually high - please verify")
                    .foregroundColor(.orange)
            }
        }
    }
    
    private var actionsSection: some View {
        Section {
            Button(role: .destructive) {
                showingDeleteAlert = true
            } label: {
                HStack {
                    Image(systemName: "trash.fill")
                    Text("Delete Pouch")
                }
                .foregroundColor(.red)
            }
        }
    }
    
    // MARK: - Actions
    
    private func savePouch() {
        guard let amount = Double(nicotineAmount), amount > 0 else {
            showError("Please enter a valid nicotine amount")
            return
        }
        
        // Store original values to check for changes
        let originalStartTime = pouchLog.insertionTime
        let originalRemovalTime = pouchLog.removalTime
        let hasActivePouch = originalRemovalTime == nil
        let startTimeChanged = originalStartTime != insertionTime
        
        // Update pouch properties
        pouchLog.insertionTime = insertionTime
        pouchLog.removalTime = hasRemovalTime ? removalTime : nil
        pouchLog.nicotineAmount = amount
        
        // Save to Core Data
        do {
            try viewContext.save()
            
            // If this is an active pouch and the start time changed, update the Live Activity
            if #available(iOS 16.1, *), hasActivePouch && startTimeChanged {
                let pouchId = pouchLog.pouchId?.uuidString ?? pouchLog.objectID.uriRepresentation().absoluteString
                Task {
                    await LiveActivityManager.updateLiveActivityStartTime(
                        for: pouchId,
                        newStartTime: insertionTime,
                        nicotineAmount: amount
                    )
                }
            }
            
            // Update widgets and Live Activities
            WidgetCenter.shared.reloadAllTimelines()
            
            // Post notification for other views to update
            NotificationCenter.default.post(name: NSNotification.Name("PouchEdited"), object: nil)
            
            onSave()
            dismiss()
        } catch {
            showError("Failed to save changes: \(error.localizedDescription)")
        }
    }
    
    private func deletePouch() {
        // If this pouch was from a can, restore the pouch count
        if let can = pouchLog.can {
            can.pouchCount += 1  // Restore one pouch to the can
            print("📦 Restored pouch to can \(can.brand ?? "Unknown") after deletion - new count: \(can.pouchCount)")
        }
        
        // Delete from Core Data
        viewContext.delete(pouchLog)
        
        do {
            try viewContext.save()
            
            // Update widgets
            WidgetCenter.shared.reloadAllTimelines()
            
            // Post notification for other views to update
            NotificationCenter.default.post(name: NSNotification.Name("PouchDeleted"), object: nil)
            
            // Update can manager to refresh inventory
            CanManager.shared.fetchActiveCans(context: viewContext)
            
            onDelete()
            dismiss()
        } catch {
            showError("Failed to delete pouch: \(error.localizedDescription)")
        }
    }
    
    private func showError(_ message: String) {
        errorMessage = message
        showingError = true
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }
}

// MARK: - Preview
struct PouchEditView_Previews: PreviewProvider {
    static var previews: some View {
        let context = PersistenceController.preview.container.viewContext
        let pouch = PouchLog(context: context)
        pouch.pouchId = UUID()
        pouch.insertionTime = Date().addingTimeInterval(-3600) // 1 hour ago
        pouch.removalTime = Date() // Just removed
        pouch.nicotineAmount = 3.0
        
        return PouchEditView(pouchLog: pouch, onSave: {}, onDelete: {})
            .environment(\.managedObjectContext, context)
    }
}
