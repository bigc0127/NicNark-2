//
//  CanCardView.swift
//  nicnark-2
//
//  Can inventory card display for v2.0
//

import SwiftUI
import CoreData
import WidgetKit

struct CanCardView: View {
    let can: Can
    let loadedCount: Int  // How many pouches are currently loaded from this can
    let activePouches: [PouchLog]  // Active pouches from this can
    let onIncrement: () -> Void
    let onDecrement: () -> Void
    let onEdit: (() -> Void)?
    @Environment(\.managedObjectContext) private var viewContext
    @StateObject private var canManager = CanManager.shared
    @State private var tick = Date()  // For timer updates
    
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
                    if can.pouchCount <= Int16(NotificationSettings.shared.canLowInventoryThreshold) {
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
            
            // Middle: Show countdown timers if active pouches
            if !activePouches.isEmpty {
                VStack(spacing: 4) {
                    ForEach(activePouches, id: \.self) { pouch in
                        compactTimer(for: pouch)
                    }
                }
                .padding(.horizontal, 8)
            }
            
            Spacer()
            
            // Right side: Show Clear All button for 2+, single X for 1, or +/- controls
            if !activePouches.isEmpty {
                // If 2+ active pouches, show bulk clear button; otherwise show individual X button
                if activePouches.count >= 2 {
                    // Show bulk clear button
                    Button(action: clearAllActivePouches) {
                        VStack(spacing: 4) {
                            Image(systemName: "trash.circle.fill")
                                .font(.system(size: 32))
                                .foregroundColor(.red)
                            Text("Clear All")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text("(\(activePouches.count) active)")
                                .font(.caption2)
                                .foregroundColor(.red)
                        }
                    }
                    .padding(.horizontal, 8)
                } else if let pouch = activePouches.first {
                    // Show single X button
                    Button(action: {
                        removePouch(pouch)
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 32))
                            .foregroundColor(.red)
                    }
                }
            } else {
                // Show +/- controls when no active pouches
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
                        .foregroundColor(loadedCount > 0 ? .blue : .secondary)
                        .frame(minWidth: 30)
                    
                    // Plus button
                    Button(action: onIncrement) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(can.pouchCount > 0 ? .green : .gray)
                    }
                    .disabled(can.pouchCount == 0)
                }
            }
        }
        .padding()
        .background(loadedCount > 0 ? Color.blue.opacity(0.1) : Color(.secondarySystemBackground))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(loadedCount > 0 ? Color.blue : (can.isEmpty ? Color.red.opacity(0.5) : Color.clear), lineWidth: loadedCount > 0 ? 2 : 1)
        )
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
        .onAppear {
            // Update timer every second for active pouches
            if !activePouches.isEmpty {
                let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                    tick = Date()
                }
                RunLoop.current.add(timer, forMode: .common)
            }
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            if !activePouches.isEmpty {
                tick = Date()
            }
        }
    }
    
    // MARK: - Timer Views
    
    @ViewBuilder
    func compactTimer(for pouch: PouchLog) -> some View {
        let insertionTime = pouch.insertionTime ?? Date()
        let elapsed = max(0, tick.timeIntervalSince(insertionTime))
        let duration = TimeInterval(pouch.timerDuration * 60)
        let remaining = max(0, duration - elapsed)
        let progress = min(max(elapsed / duration, 0), 1)
        
        VStack(alignment: .leading, spacing: 2) {
            // Timer display
            Text(formatMinutesSeconds(remaining))
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.semibold)
                .foregroundColor(remaining > 0 ? .blue : .green)
            
            // Mini progress bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.gray.opacity(0.2))
                        .frame(height: 2)
                        .cornerRadius(1)
                    
                    Rectangle()
                        .fill(remaining > 0 ? Color.blue : Color.green)
                        .frame(width: geometry.size.width * progress, height: 2)
                        .cornerRadius(1)
                }
            }
            .frame(height: 2)
        }
        .frame(width: 60)
    }
    
    @ViewBuilder
    func miniTimer(for pouch: PouchLog) -> some View {
        let insertionTime = pouch.insertionTime ?? Date()
        let elapsed = max(0, tick.timeIntervalSince(insertionTime))
        let duration = TimeInterval(pouch.timerDuration * 60)
        let remaining = max(0, duration - elapsed)
        let progress = min(max(elapsed / duration, 0), 1)
        
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                // Timer display
                Text(formatMinutesSeconds(remaining))
                    .font(.system(.callout, design: .monospaced))
                    .fontWeight(.semibold)
                    .foregroundColor(remaining > 0 ? .blue : .green)
                
                // Mini progress bar
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color.gray.opacity(0.2))
                            .frame(height: 2)
                            .cornerRadius(1)
                        
                        Rectangle()
                            .fill(remaining > 0 ? Color.blue : Color.green)
                            .frame(width: geometry.size.width * progress, height: 2)
                            .cornerRadius(1)
                    }
                }
                .frame(height: 2)
            }
            .frame(width: 70)
            
            // Remove button
            Button(action: {
                removePouch(pouch)
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.red)
            }
        }
        .padding(6)
        .background(Color(.tertiarySystemBackground))
        .cornerRadius(8)
    }
    
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
        guard can.pouchCount <= Int16(NotificationSettings.shared.canLowInventoryThreshold) else {
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
    
    private func clearAllActivePouches() {
        // Remove all active pouches for this can
        for pouch in activePouches {
            removePouch(pouch)
        }
        
        print("✅ Cleared \(activePouches.count) active pouches from \(can.brand ?? "Unknown")")
    }
    
    private func formatMinutesSeconds(_ ti: TimeInterval) -> String {
        let minutes = Int(ti) / 60
        let seconds = Int(ti) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    private func removePouch(_ pouch: PouchLog) {
        let pouchId = pouch.pouchId?.uuidString ?? pouch.objectID.uriRepresentation().absoluteString
        
        // End Live Activity if this is the last active pouch
        if #available(iOS 16.1, *) {
            Task {
                await LiveActivityManager.endLiveActivity(for: pouchId)
            }
        }
        
        // Mark pouch as removed
        pouch.removalTime = Date.now
        
        do {
            try viewContext.save()
            print("✅ Removed pouch \(pouch.nicotineAmount)mg")
        } catch {
            print("❌ Failed to remove pouch: \(error)")
        }
        
        // Cancel notification
        NotificationManager.cancelAlert(id: pouchId)
        
        // Update widgets
        WidgetCenter.shared.reloadAllTimelines()
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
