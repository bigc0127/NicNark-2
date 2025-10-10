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

private struct LineSegment: Identifiable {
    let id = UUID()
    let points: [NicotinePoint]
    let color: Color
}

struct NicotineLevelView: View {
    // MARK: - Properties
    @Environment(\.managedObjectContext) private var viewContext
    @FetchRequest private var recentLogs: FetchedResults<PouchLog>
    
    @State private var selectedPoint: NicotinePoint?
    @State private var chartData: [NicotinePoint] = []
    @State private var lineSegments: [LineSegment] = []
    @State private var isLoading = true
    @State private var refreshTrigger = false
    @State private var updateTimer: Timer?
    @State private var lastDataGeneration = Date.distantPast
    
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
            startLiveUpdates()
        }
        .onDisappear {
            stopLiveUpdates()
        }
        .onChange(of: recentLogs.count) { _, _ in
            Task {
                await generateChartData()
                lastDataGeneration = Date()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("PouchRemoved"))) { _ in
            Task {
                await generateChartData()
                lastDataGeneration = Date()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("PouchEdited"))) { _ in
            Task {
                await generateChartData()
                lastDataGeneration = Date()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("PouchDeleted"))) { _ in
            Task {
                await generateChartData()
                lastDataGeneration = Date()
            }
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
        Chart {
            // Draw each colored segment as a series
            ForEach(lineSegments) { segment in
                ForEach(segment.points) { point in
                    LineMark(
                        x: .value("Time", point.time),
                        y: .value("Nicotine", point.level),
                        series: .value("Segment", segment.id.uuidString)
                    )
                    .foregroundStyle(segment.color)
                    .lineStyle(StrokeStyle(lineWidth: 3))
                    .interpolationMethod(.linear)
                }
            }
            
            // Area under the curve (subtle background)
            ForEach(chartData) { point in
                AreaMark(
                    x: .value("Time", point.time),
                    y: .value("Nicotine", point.level)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(
                    .linearGradient(
                        colors: [.gray.opacity(0.15), .gray.opacity(0.03)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }
            
            // Endpoint indicator (dot at the end)
            if let lastPoint = chartData.last,
               chartData.count >= 2 {
                let secondToLast = chartData[chartData.count - 2]
                let isIncreasing = lastPoint.level > secondToLast.level
                let endpointColor: Color = isIncreasing ? .green : .red
                
                PointMark(
                    x: .value("Time", lastPoint.time),
                    y: .value("Nicotine", lastPoint.level)
                )
                .foregroundStyle(endpointColor)
                .symbolSize(150)
            }
            
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
    
    // MARK: - Live Update Timer Management
    
    /**
     * Starts the live update timer that refreshes the graph every second.
     * This ensures the nicotine level graph updates in real-time while the user is viewing it.
     * The timer is registered on the common run loop to ensure updates continue during scrolling.
     */
    private func startLiveUpdates() {
        // Prevent duplicate timers
        guard updateTimer == nil else { return }
        
        updateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                // Only regenerate chart data every 15 seconds to avoid expensive recalculations
                // This provides smooth visual updates while minimizing performance impact
                let now = Date()
                if now.timeIntervalSince(self.lastDataGeneration) >= 15 {
                    await self.generateChartData()
                    self.lastDataGeneration = now
                } else {
                    // Just trigger a view refresh without regenerating data
                    self.refreshTrigger.toggle()
                }
            }
        }
        
        // Register on common run loop to keep updating during scrolling
        if let timer = updateTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
        
        logger.debug("Started live graph updates (1s check, 15s data refresh)")
    }
    
    /**
     * Stops the live update timer.
     * Called when the view disappears to conserve battery and resources.
     */
    private func stopLiveUpdates() {
        updateTimer?.invalidate()
        updateTimer = nil
        logger.debug("Stopped live graph updates")
    }
    
    // MARK: - Data Generation
    
    private func createLineSegments(from points: [NicotinePoint]) {
        guard points.count >= 2 else {
            lineSegments = []
            return
        }
        
        var segments: [LineSegment] = []
        var currentSegmentPoints: [NicotinePoint] = [points[0]]
        var currentColor: Color? = nil
        
        for index in 1..<points.count {
            let current = points[index]
            let previous = points[index - 1]
            let isIncreasing = current.level > previous.level
            let color: Color = isIncreasing ? .green : .red
            
            if currentColor == nil {
                currentColor = color
            }
            
            if color == currentColor {
                // Continue the current segment
                currentSegmentPoints.append(current)
            } else {
                // Start a new segment
                if !currentSegmentPoints.isEmpty {
                    segments.append(LineSegment(points: currentSegmentPoints, color: currentColor!))
                }
                currentSegmentPoints = [previous, current] // Include previous point to connect segments
                currentColor = color
            }
        }
        
        // Add the last segment
        if !currentSegmentPoints.isEmpty, let color = currentColor {
            segments.append(LineSegment(points: currentSegmentPoints, color: color))
        }
        
        lineSegments = segments
    }
    
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
            self.createLineSegments(from: data)
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
        
        // Calculate nicotine level at each time point using the centralized calculator
        let calculator = NicotineCalculator()
        var points: [NicotinePoint] = []
        for timePoint in timePoints {
            let level = await calculator.calculateTotalNicotineLevel(context: viewContext, at: timePoint)
            points.append(NicotinePoint(time: timePoint, level: max(0, level)))
        }
        return points
    }
    
    // Removed unused local calculation functions - now using centralized NicotineCalculator
}

// MARK: - Previews
struct NicotineLevelView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            NicotineLevelView()
        }
    }
}
