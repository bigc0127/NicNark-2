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
    let loadedCount: Int
    let activePouches: [PouchLog]
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
            VStack(alignment: .leading, spacing: 6) {
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
                
                HStack(spacing: 6) {
                    Text("\(Int(can.strength))mg")
                        .font(.system(.body, design: .rounded))
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(strengthColor)
                        .cornerRadius(6)
                    Text(maxAbsorptionLabel)
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundColor(.blue)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.blue.opacity(0.14))
                        .clipShape(Capsule())
                }
                
                HStack(spacing: 4) {
                    Text("\(can.pouchCount)")
                        .font(.caption)
                        .fontWeight(.semibold)
                    Text("left")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                
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
            
            VStack(spacing: 4) {
                HStack(spacing: 12) {
                    Button(action: onDecrement) {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(loadedCount > 0 ? .red : .gray)
                    }
                    .disabled(loadedCount == 0)
                    
                    Text("\(loadedCount)")
                        .font(.system(.title3, design: .rounded))
                        .fontWeight(.bold)
                        .foregroundColor(loadedCount > 0 ? .primary : .secondary)
                        .frame(minWidth: 30)
                    
                    Button(action: onIncrement) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(can.pouchCount > 0 ? .green : .gray)
                    }
                    .disabled(can.pouchCount == 0)
                }
                
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
            Button(role: .destructive) {
                canManager.deleteCan(can, context: viewContext)
            } label: {
                Label("Delete Can", systemImage: "trash")
            }
        }
    }
    
    private var loadedTint: Color { Color(red: 1.0, green: 0.72, blue: 0.0) }

    private var maxAbsorptionFraction: Double {
        BrandAbsorptionProfile.fraction(forBrand: can.brand)
    }

    private var maxAbsorptionPercent: Int {
        Int((maxAbsorptionFraction * 100).rounded())
    }

    private var maxAbsorptionMg: Double {
        can.strength * maxAbsorptionFraction
    }

    private var maxAbsorptionLabel: String {
        String(format: "Max %d%% · %.2fmg", maxAbsorptionPercent, maxAbsorptionMg)
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
    
    private func handleCanNameTap() {
        guard Int(can.pouchCount) <= NotificationSettings.shared.canLowInventoryThreshold else {
            return
        }
        if let url = URL(string: "maps://?q=gas+stations") {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
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
            onIncrement: { },
            onDecrement: { }
        )
        .environment(\.managedObjectContext, context)
        .padding()
    }
}
