//
// NicotineLevelView.swift
// nicnark-2
//
// Fixed nicotine level chart with proper SwiftUI lifecycle
//

import SwiftUI
import Charts
import CoreData
import os.log

// MARK: - Data Models
private struct NicotinePoint: Identifiable, Hashable {
    let id = UUID()
    let time: Date
    let level: Double
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct NicotineLevelView: View {
    // MARK: - Properties
    @Environment(\.managedObjectContext) private var viewContext
    @FetchRequest private var recentLogs: FetchedResults<PouchLog>
    
    @State private var selectedPoint: NicotinePoint?
    @State private var chartData: [NicotinePoint] = []
    @State private var isLoading = true
    @State private var refreshTrigger = false
    
    private let logger = Logger(subsystem: "com.nicnark.nicnark-2", category: "NicotineLevelView")
    private let absorptionConstants = AbsorptionConstants.shared
    
    // MARK: - Initialization
    init() {
        let calendar = Calendar.current
        let twentyFourHoursAgo = calendar.date(byAdding: .hour, value: -24, to: Date()) ?? Date()
        
        self._recentLogs = FetchRequest<PouchLog>(
            entity: PouchLog.entity(),
            sortDescriptors: [NSSortDescriptor(keyPath: \PouchLog.insertionTime, ascending: true)],
            predicate: NSPredicate(format: "insertionTime >= %@", twentyFourHoursAgo as NSDate)
        )
    }
    
    var body: some View {
        VStack(spacing: 16) {
            headerView
            
            if isLoading {
                ProgressView("Generating chart data...")
                    .frame(height: 320)
            } else {
                chartView
            }
            
            selectedPointInfo
        }
        .padding()
        .navigationTitle("Nicotine Levels")
        .onAppear {
            Task {
                await generateChartData()
            }
        }
        .onChange(of: recentLogs.count) { _, _ in
            Task {
                await generateChartData()
            }
        }
        .onChange(of: refreshTrigger) { _, _ in
            Task {
                await generateChartData()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("PouchRemoved"))) { _ in
            refreshTrigger.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("PouchEdited"))) { _ in
            refreshTrigger.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("PouchDeleted"))) { _ in
            refreshTrigger.toggle()
        }
    }
    
    // MARK: - View Components
    private var headerView: some View {
        VStack(spacing: 4) {
            Text("Nicotine Levels (Last 24 Hours)")
                .font(.headline)
                .fontWeight(.semibold)
            
            if !chartData.isEmpty {
                let currentLevel = chartData.last?.level ?? 0
                Text("Current: \(currentLevel, specifier: "%.3f") mg")
                    .font(.subheadline)
                    .foregroundColor(levelColor(for: currentLevel))
                    .fontWeight(.medium)
            }
        }
    }
    
    private var chartView: some View {
        Chart(chartData) { point in
            LineMark(
                x: .value("Time", point.time),
                y: .value("Nicotine", point.level)
            )
            .interpolationMethod(.catmullRom)
            .foregroundStyle(
                .linearGradient(
                    colors: [.blue.opacity(0.8), .blue],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .lineStyle(StrokeStyle(lineWidth: 3))
            
            AreaMark(
                x: .value("Time", point.time),
                y: .value("Nicotine", point.level)
            )
            .interpolationMethod(.catmullRom)
            .foregroundStyle(
                .linearGradient(
                    colors: [.blue.opacity(0.2), .blue.opacity(0.05)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            
            if let selectedPoint = selectedPoint {
                RuleMark(x: .value("Selected", selectedPoint.time))
                    .foregroundStyle(.red.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 3]))
                
                PointMark(
                    x: .value("Selected", selectedPoint.time),
                    y: .value("Selected", selectedPoint.level)
                )
                .foregroundStyle(.red)
                .symbolSize(100)
            }
        }
        .frame(height: 320)
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 6)) { value in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour())
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel()
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                handleChartInteraction(at: value.location, proxy: proxy, geometry: geometry)
                            }
                            .onEnded { _ in
                                selectedPoint = nil
                            }
                    )
            }
        }
    }
    
    private var selectedPointInfo: some View {
        Group {
            if let selectedPoint = selectedPoint {
                VStack(spacing: 12) {
                    HStack(spacing: 20) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Time")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(selectedPoint.time, format: .dateTime.hour().minute())
                                .font(.system(size: 16, weight: .semibold, design: .monospaced))
                        }
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Level")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("\(selectedPoint.level, specifier: "%.3f") mg")
                                .font(.system(size: 16, weight: .semibold, design: .monospaced))
                                .foregroundColor(levelColor(for: selectedPoint.level))
                        }
                        
                        Spacer()
                        
                        VStack(alignment: .center, spacing: 8) {
                            ZStack {
                                Circle()
                                    .fill(Color.gray.opacity(0.2))
                                    .frame(width: 50, height: 50)
                                
                                Circle()
                                    .fill(levelColor(for: selectedPoint.level))
                                    .frame(width: CGFloat(min(50, max(10, selectedPoint.level * 5))))
                            }
                            
                            Text(levelStatus(for: selectedPoint.level))
                                .font(.caption2)
                                .fontWeight(.medium)
                                .foregroundColor(levelColor(for: selectedPoint.level))
                        }
                    }
                }
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(16)
            } else {
                Text("Tap and drag on the chart to explore data")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding()
            }
        }
    }
    
    // MARK: - Chart Interaction
    private func handleChartInteraction(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) {
        guard let timeValue: Date = proxy.value(atX: location.x) else { return }
        
        let closestPoint = chartData.min { point1, point2 in
            abs(point1.time.timeIntervalSince(timeValue)) < abs(point2.time.timeIntervalSince(timeValue))
        }
        
        selectedPoint = closestPoint
    }
    
    // MARK: - Level Helpers
    private func levelColor(for level: Double) -> Color {
        switch level {
        case 0..<1: return .green
        case 1..<3: return .yellow
        case 3..<6: return .orange
        case 6..<10: return .red
        default: return .purple
        }
    }
    
    private func levelStatus(for level: Double) -> String {
        switch level {
        case 0..<1: return "Low"
        case 1..<3: return "Moderate"
        case 3..<6: return "High"
        case 6..<10: return "Very High"
        default: return "Extreme"
        }
    }
    
    // MARK: - Data Generation
    private func generateChartData() async {
        await MainActor.run { isLoading = true }
        
        let data = await withTaskGroup(of: [NicotinePoint].self) { group in
            group.addTask {
                await self.calculateNicotineDataPoints()
            }
            
            var result: [NicotinePoint] = []
            for await taskResult in group {
                result = taskResult
            }
            return result
        }
        
        await MainActor.run {
            self.chartData = data
            self.isLoading = false
        }
    }
    
    private func calculateNicotineDataPoints() async -> [NicotinePoint] {
        let now = Date()
        let startTime = Calendar.current.date(byAdding: .hour, value: -24, to: now) ?? now
        
        // Create time points every 15 minutes
        var timePoints: [Date] = []
        var currentTime = startTime
        
        while currentTime <= now {
            timePoints.append(currentTime)
            currentTime = currentTime.addingTimeInterval(15 * 60) // 15 minutes
        }
        
        // Calculate nicotine level at each time point
        return timePoints.compactMap { timePoint in
            let totalLevel = calculateTotalNicotineLevelAt(time: timePoint)
            return NicotinePoint(time: timePoint, level: max(0, totalLevel))
        }
    }
    
    private func calculateTotalNicotineLevelAt(time: Date) -> Double {
        var totalLevel = 0.0
        
        for pouchLog in recentLogs {
            guard let insertionTime = pouchLog.insertionTime else { continue }
            
            let removalTime = pouchLog.removalTime ?? time
            let endTime = removalTime
            
            // Only consider pouches that were active or had effects at this time
            if insertionTime <= time {
                let contribution = calculatePouchContribution(
                    pouchLog: pouchLog,
                    currentTime: time,
                    insertionTime: insertionTime,
                    endTime: endTime
                )
                totalLevel += contribution
            }
        }
        
        return totalLevel
    }
    
    private func calculatePouchContribution(
        pouchLog: PouchLog,
        currentTime: Date,
        insertionTime: Date,
        endTime: Date
    ) -> Double {
        let nicotineContent = pouchLog.nicotineAmount
        
        if currentTime <= endTime {
            // During absorption phase
            let timeInMouth = min(
                currentTime.timeIntervalSince(insertionTime),
                endTime.timeIntervalSince(insertionTime)
            )
            return absorptionConstants.calculateCurrentNicotineLevel(
                nicotineContent: nicotineContent,
                elapsedTime: timeInMouth
            )
        } else {
            // Post-absorption decay phase
            let actualTimeInMouth = endTime.timeIntervalSince(insertionTime)
            let totalAbsorbed = absorptionConstants.calculateAbsorbedNicotine(
                nicotineContent: nicotineContent,
                useTime: actualTimeInMouth
            )
            
            let timeSinceRemoval = currentTime.timeIntervalSince(endTime)
            return absorptionConstants.calculateDecayedNicotine(
                initialLevel: totalAbsorbed,
                timeSinceRemoval: timeSinceRemoval
            )
        }
    }
}

// MARK: - Previews
struct NicotineLevelView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            NicotineLevelView()
        }
    }
}
