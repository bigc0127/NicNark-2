//
//  CanSelectionSheet.swift
//  nicnark-2
//
//  Can selection sheet for associating pouches from Siri Shortcuts
//

import SwiftUI
import CoreData

struct CanSelectionSheet: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss
    
    let pendingPouch: PouchLog?
    let onSelection: (Can?) -> Void
    
    @FetchRequest(
        entity: Can.entity(),
        sortDescriptors: [
            NSSortDescriptor(keyPath: \Can.pouchCount, ascending: false),
            NSSortDescriptor(keyPath: \Can.dateAdded, ascending: false)
        ],
        predicate: NSPredicate(format: "pouchCount > 0")
    ) private var activeCans: FetchedResults<Can>
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Header explanation
                VStack(spacing: 8) {
                    Image(systemName: "questionmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.blue)
                    
                    Text("Which can was this from?")
                        .font(.headline)
                    
                    if let pouch = pendingPouch {
                        Text("\(Int(pouch.nicotineAmount))mg pouch logged via Siri")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding()
                
                Divider()
                
                // Can selection list
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(activeCans, id: \.self) { can in
                            Button(action: {
                                onSelection(can)
                                dismiss()
                            }) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(can.brand ?? "Unknown")
                                            .font(.headline)
                                            .foregroundColor(.primary)
                                        
                                        if let flavor = can.flavor, !flavor.isEmpty {
                                            Text(flavor)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    
                                    Spacer()
                                    
                                    VStack(alignment: .trailing, spacing: 4) {
                                        Text("\(Int(can.strength))mg")
                                            .font(.subheadline)
                                            .fontWeight(.semibold)
                                            .foregroundColor(.primary)
                                        
                                        Text("\(can.pouchCount) left")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .padding()
                                .background(Color(.secondarySystemBackground))
                                .cornerRadius(10)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                        
                        // Ignore can option
                        Button(action: {
                            onSelection(nil)
                            dismiss()
                        }) {
                            HStack {
                                Image(systemName: "nosign")
                                    .foregroundColor(.orange)
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Don't Track Can")
                                        .font(.headline)
                                        .foregroundColor(.primary)
                                    
                                    Text("Log without associating to inventory")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                
                                Spacer()
                                
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding()
                            .background(Color(.tertiarySystemBackground))
                            .cornerRadius(10)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                    .padding()
                }
            }
            .navigationTitle("Select Can")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
}

struct CanSelectionSheet_Previews: PreviewProvider {
    static var previews: some View {
        let context = PersistenceController.preview.container.viewContext
        let pouch = PouchLog(context: context)
        pouch.nicotineAmount = 6
        
        return CanSelectionSheet(pendingPouch: pouch) { _ in
            print("Can selected")
        }
        .environment(\.managedObjectContext, context)
    }
}
