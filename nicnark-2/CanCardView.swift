//
//  CanCardView.swift
//  nicnark-2
//
//  Can inventory card display for v2.0
//

import SwiftUI
import CoreData

struct CanCardView: View {
    let can: Can
    let onSelect: () -> Void
    let onEdit: (() -> Void)?
    @Environment(\.managedObjectContext) private var viewContext
    @StateObject private var canManager = CanManager.shared
    
    init(can: Can, onSelect: @escaping () -> Void, onEdit: (() -> Void)? = nil) {
        self.can = can
        self.onSelect = onSelect
        self.onEdit = onEdit
    }
    
    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 8) {
                // Brand and flavor
                VStack(spacing: 2) {
                    Text(can.brand ?? "Unknown")
                        .font(.headline)
                        .lineLimit(1)
                    
                    if let flavor = can.flavor, !flavor.isEmpty {
                        Text(flavor)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                
                // Strength badge
                Text("\(Int(can.strength))mg")
                    .font(.system(.title2, design: .rounded))
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(strengthColor)
                    .cornerRadius(8)
                
                // Pouch count
                VStack(spacing: 2) {
                    Text("\(can.pouchCount)")
                        .font(.title3)
                        .fontWeight(.semibold)
                    
                    Text("pouches")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                
                // Progress bar
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color.gray.opacity(0.2))
                            .frame(height: 4)
                            .cornerRadius(2)
                        
                        Rectangle()
                            .fill(progressColor)
                            .frame(width: geometry.size.width * can.remainingPercentage, height: 4)
                            .cornerRadius(2)
                    }
                }
                .frame(height: 4)
            }
            .padding()
            .frame(width: 150, height: 180)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(can.isEmpty ? Color.red.opacity(0.5) : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(can.isEmpty)
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
        
        return CanCardView(can: can) {
            print("Can selected")
        }
        .environment(\.managedObjectContext, context)
    }
}
