//
//  CanCardView.swift
//  nicnark-2
//
//  Can inventory card display for v2.0
//

import SwiftUI
import CoreData
import WidgetKit
import UIKit

struct CanCardView: View {
    let can: Can
    let loadedCount: Int  // How many pouches are currently loaded from this can
    let activePouches: [PouchLog]  // Active pouches from this can
    let onIncrement: () -> Void
    let onDecrement: () -> Void
    let onEdit: (() -> Void)?
    @Environment(\.managedObjectContext) private var viewContext
    @StateObject private var canManager = CanManager.shared

    init(can: Can, loadedCount: Int = 0, activePouches: [PouchLog] = [], onIncrement: @escaping () -> Void, onDecrement: @escaping () -> Void, onEdit: (() -> Void)? = nil) {
        self.can = can
        self.loadedCount = loadedCount
        self.activePouches = activePouches
        self.onIncrement = onIncrement
        self.onDecrement = onDecrement
        self.onEdit = onEdit
    }
    
    var body: some View {
        HStack(spacing: 12) {
            // Attached can photo (if one has been added for this can). Reads Core Data so a
            // photo that synced in from another device shows without waiting for a reconcile.
            if let photo = CanImageStore.image(for: can) {
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 46, height: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            // Left: Can info
            VStack(alignment: .leading, spacing: 6) {
                // Brand/Flavor with Maps tap for low inventory
                HStack(spacing: 4) {
                    if let flavor = can.flavor, !flavor.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(flavor)
                                .font(.headline)
                                .lineLimit(1)
                            Text(can.brand ?? "Unknown")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    } else {
                        Text(can.brand ?? "Unknown")
                            .font(.headline)
                            .lineLimit(1)
                    }
                    
                    // Show map pin icon when inventory is low
                    if Int(can.pouchCount) <= NotificationSettings.shared.canLowInventoryThreshold {
                        Image(systemName: "map.fill")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    handleCanNameTap()
                }
                
                // Strength badge
                Text("\(Int(can.strength))mg")
                    .font(.system(.body, design: .rounded))
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(strengthColor)
                    .cornerRadius(6)
                
                // Remaining count with progress
                HStack(spacing: 4) {
                    Text("\(can.pouchCount)")
                        .font(.caption)
                        .fontWeight(.semibold)
                    Text("left")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                
                // Mini progress bar
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color.gray.opacity(0.2))
                            .frame(height: 3)
                            .cornerRadius(1.5)
                        
                        Rectangle()
                            .fill(progressColor)
                            .frame(width: geometry.size.width * can.remainingPercentage, height: 3)
                            .cornerRadius(1.5)
                    }
                }
                .frame(height: 3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            Spacer()
            
            // Right side: Always show +/- controls (timers will be displayed at bottom)
            VStack(spacing: 4) {
                // Visible edit affordance (the context-menu "Edit Can" was undiscoverable).
                if let onEdit = onEdit {
                    Button(action: onEdit) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 18))
                            .foregroundColor(.blue)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .accessibilityLabel("Edit can")
                }

                HStack(spacing: 12) {
                    // Minus button
                    Button(action: onDecrement) {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(loadedCount > 0 ? .red : .gray)
                    }
                    .disabled(loadedCount == 0)
                    
                    // Loaded count
                    Text("\(loadedCount)")
                        .font(.system(.title3, design: .rounded))
                        .fontWeight(.bold)
                        // High-contrast on the amber loaded state so the count clearly stands out.
                        .foregroundColor(loadedCount > 0 ? .primary : .secondary)
                        .frame(minWidth: 30)
                    
                    // Plus button
                    Button(action: onIncrement) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(can.pouchCount > 0 ? .green : .gray)
                    }
                    .disabled(can.pouchCount == 0)
                }
                
                // Active pouches indicator
                if !activePouches.isEmpty {
                    Text("\(activePouches.count) active")
                        .font(.caption2)
                        .foregroundColor(.orange)
                        .fontWeight(.semibold)
                }
            }
        }
        .padding()
        .glassEffect(loadedCount > 0 ? .regular.tint(loadedTint) : .regular, in: .rect(cornerRadius: 12))
        .opacity(can.isEmpty ? 0.6 : 1.0)
        .contextMenu {
            if let onEdit = onEdit {
                Button(action: onEdit) {
                    Label("Edit Can", systemImage: "pencil")
                }
            }
            
            Button(role: .destructive) {
                canManager.deleteCan(can, context: viewContext)
            } label: {
                Label("Delete Can", systemImage: "trash")
            }
        }
    }
    
    /// Warm amber tint applied to a can card while pouches are loaded from it (replaces the
    /// old blue). Bright and clearly "armed", while staying light enough that the dark card
    /// text/badges keep high contrast on top of the translucent glass.
    private var loadedTint: Color { Color(red: 1.0, green: 0.72, blue: 0.0) }

    private var strengthColor: Color {
        switch can.strength {
        case 0..<4:
            return .green
        case 4..<7:
            return .orange
        default:
            return .red
        }
    }
    
    private var progressColor: Color {
        let percentage = can.remainingPercentage
        switch percentage {
        case 0.5...1.0:
            return .green
        case 0.25..<0.5:
            return .orange
        default:
            return .red
        }
    }
    
    // MARK: - Helper Functions
    
    private func handleCanNameTap() {
        // Only open Maps if inventory is low
        guard Int(can.pouchCount) <= NotificationSettings.shared.canLowInventoryThreshold else {
            print("ℹ️ Can has sufficient inventory (\(can.pouchCount) pouches), not opening Maps")
            return
        }
        
        // Open Maps with search for gas stations
        if let url = URL(string: "maps://?q=gas+stations") {
            UIApplication.shared.open(url, options: [:]) { success in
                if success {
                    print("📍 Opened Maps to search for gas stations (\(can.brand ?? "Unknown") is low: \(can.pouchCount) pouches)")
                } else {
                    print("❌ Failed to open Maps")
                }
            }
        }
    }
    
}

struct CanCardView_Previews: PreviewProvider {
    static var previews: some View {
        let context = PersistenceController.preview.container.viewContext
        let can = Can(context: context)
        can.brand = "ZYN"
        can.flavor = "Cool Mint"
        can.strength = 6
        can.pouchCount = 15
        can.initialCount = 20
        
        return CanCardView(
            can: can,
            loadedCount: 2,
            onIncrement: { print("Increment") },
            onDecrement: { print("Decrement") }
        )
        .environment(\.managedObjectContext, context)
        .padding()
    }
}
