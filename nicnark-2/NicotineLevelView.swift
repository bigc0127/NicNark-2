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

private struct PredictionPoint: Identifiable {
    let id = UUID()
    let time: Date
    let level: Double
    let label: String
}

private struct AbsorptionRateData: Identifiable {
    let id = UUID()
    let time: Date
    let pouches: [PouchAbsorptionInfo]
    let effectiveRate: Double // mg/min at this time (sum of active pouches)
}

private struct PouchAbsorptionInfo {
    let pouchId: UUID
    let nicotineAmount: Double
    let absorptionRate: Double // mg/minute
    let absorptionPercent: Double // 0.0 to 1.0
}

struct NicotineLevelView: View {
    // MARK: - Properties
    @Environment(\.managedObjectContext) private var viewContext
    @FetchRequest private var recentLogs: FetchedResults<PouchLog>
    
    @State private var selectedPoint: NicotinePoint?
    @State private var chartData: [NicotinePoint] = []
    @State private var lineSegments: [LineSegment] = []
    @State private var predictionData: [NicotinePoint] = []
    @State private var futurePredictions: [PredictionPoint] = []
    @State private var absorptionRates: [AbsorptionRateData] = []
    @State private var selectedAbsorptionData: AbsorptionRateData?
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
        ScrollView {
            VStack(spacing: 16) {
                headerView
                
                if isLoading {
                    ProgressView("Generating chart data...")
                        .frame(height: 320)
                } else {
                    chartView
                }
                
                selectedPointInfo
                
                // Always show absorption rate when there's an active pouch
                if let absorption = selectedAbsorptionData, !absorption.pouches.isEmpty {
                    absorptionRateView(absorption)
                }
                
                if !futurePredictions.isEmpty {
                    predictionListView
                }
            }
            .padding()
        }
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
            
            // Prediction line (dashed, semi-transparent)
            if !predictionData.isEmpty {
                ForEach(predictionData) { point in
                    LineMark(
                        x: .value("Time", point.time),
                        y: .value("Nicotine", point.level)
                    )
                    .foregroundStyle(.blue.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 3]))
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
    
    @ViewBuilder
    private func absorptionRateView(_ absorption: AbsorptionRateData) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .foregroundColor(.blue)
                Text("Absorption Rate")
                    .font(.headline)
                    .fontWeight(.semibold)
            }
            
            // Effective total absorption rate
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Effective Total")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text(String(format: "%.4f mg/min", absorption.effectiveRate))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 2) {
                    Text(String(format: "%.2f mg/hour", absorption.effectiveRate * 60))
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .foregroundColor(.blue)
                    Text("at this moment")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(Color(.systemGray6))
            .cornerRadius(8)
            
            // Per-pouch absorption rates
            if !absorption.pouches.isEmpty {
                Text("Per-Pouch Rates")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
                    .padding(.top, 4)
                
                VStack(spacing: 6) {
                    ForEach(absorption.pouches, id: \.pouchId) { pouch in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(String(format: "%.0f mg", pouch.nicotineAmount))
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                Text(String(format: "%.1f%% absorbed", pouch.absorptionPercent * 100))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(String(format: "%.4f mg/min", pouch.absorptionRate))
                                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                    .foregroundColor(.blue)
                                Text(String(format: "%.2f mg/h", pouch.absorptionRate * 60))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                        .background(Color(.systemGray6))
                        .cornerRadius(6)
                    }
                }
            }
        }
        .padding(.top, 4)
    }
    
    private var predictionListView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundColor(.blue)
                Text("Predicted Levels")
                    .font(.headline)
                    .fontWeight(.semibold)
            }
            
            VStack(spacing: 8) {
                ForEach(futurePredictions) { prediction in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(prediction.label)
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Text(prediction.time, format: .dateTime.hour().minute())
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                        
                        HStack(spacing: 8) {
                            Text("\(prediction.level, specifier: "%.3f") mg")
                                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                                .foregroundColor(levelColor(for: prediction.level))
                            
                            Circle()
                                .fill(levelColor(for: prediction.level))
                                .frame(width: 10, height: 10)
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(Color(.systemGray6))
                    .cornerRadius(8)
                }
            }
        }
        .padding(.top, 8)
    }
    
    // MARK: - Chart Interaction
    private func handleChartInteraction(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) {
        guard let timeValue: Date = proxy.value(atX: location.x) else { return }
        
        let closestPoint = chartData.min { point1, point2 in
            abs(point1.time.timeIntervalSince(timeValue)) < abs(point2.time.timeIntervalSince(timeValue))
        }
        
        selectedPoint = closestPoint
        
        // Update absorption data selection to match the nearest time
        if let time = closestPoint?.time {
            selectedAbsorptionData = absorptionRates.min { a, b in
                abs(a.time.timeIntervalSince(time)) < abs(b.time.timeIntervalSince(time))
            }
        } else {
            selectedAbsorptionData = nil
        }
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
        
        let (historicalData, futureData, predictions, absorptionData) = await withTaskGroup(of: (historical: [NicotinePoint], future: [NicotinePoint], predictions: [PredictionPoint], absorption: [AbsorptionRateData]).self) { group in
            group.addTask {
                let historical = await self.calculateNicotineDataPoints()
                let future = await self.calculateFuturePredictions()
                let predictions = await self.calculatePredictionPoints()
                let absorption = await self.calculateAbsorptionRates()
                return (historical: historical, future: future, predictions: predictions, absorption: absorption)
            }
            
            var result: (historical: [NicotinePoint], future: [NicotinePoint], predictions: [PredictionPoint], absorption: [AbsorptionRateData]) = ([], [], [], [])
            for await taskResult in group {
                result = taskResult
            }
            return result
        }
        
        await MainActor.run {
            self.chartData = historicalData
            self.predictionData = futureData
            self.futurePredictions = predictions
            self.absorptionRates = absorptionData
            self.createLineSegments(from: historicalData)
            self.isLoading = false
            
            // Automatically select current absorption data if there's an active pouch
            self.selectCurrentAbsorptionData()
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
    
    private func calculateFuturePredictions() async -> [NicotinePoint] {
        let now = Date()
        let endTime = Calendar.current.date(byAdding: .hour, value: 12, to: now) ?? now
        
        // Create time points every 15 minutes for the next 12 hours
        var timePoints: [Date] = []
        var currentTime = now
        
        while currentTime <= endTime {
            timePoints.append(currentTime)
            currentTime = currentTime.addingTimeInterval(15 * 60) // 15 minutes
        }
        
        // Calculate predicted nicotine level at each future time point
        let calculator = NicotineCalculator()
        var points: [NicotinePoint] = []
        for timePoint in timePoints {
            let level = await calculator.calculateTotalNicotineLevel(context: viewContext, at: timePoint)
            points.append(NicotinePoint(time: timePoint, level: max(0, level)))
        }
        return points
    }
    
    private func calculatePredictionPoints() async -> [PredictionPoint] {
        let now = Date()
        let calculator = NicotineCalculator()
        
        // Define prediction intervals
        let intervals: [(minutes: Int, label: String)] = [
            (30, "30 minutes"),
            (60, "1 hour"),
            (120, "2 hours"),
            (240, "4 hours"),
            (360, "6 hours"),
            (720, "12 hours")
        ]
        
        var predictions: [PredictionPoint] = []
        
        for interval in intervals {
            let futureTime = now.addingTimeInterval(TimeInterval(interval.minutes * 60))
            let level = await calculator.calculateTotalNicotineLevel(context: viewContext, at: futureTime)
            predictions.append(PredictionPoint(
                time: futureTime,
                level: max(0, level),
                label: interval.label
            ))
        }
        
        return predictions
    }
    
    private func calculateAbsorptionRates() async -> [AbsorptionRateData] {
        let now = Date()
        let startTime = Calendar.current.date(byAdding: .hour, value: -24, to: now) ?? now
        
        // Create time points every 15 minutes
        var timePoints: [Date] = []
        var currentTime = startTime
        
        while currentTime <= now {
            timePoints.append(currentTime)
            currentTime = currentTime.addingTimeInterval(15 * 60) // 15 minutes
        }
        
        // Calculate absorption rates at each time point
        let request: NSFetchRequest<PouchLog> = PouchLog.fetchRequest()
        let lookbackTime = startTime.addingTimeInterval(-10 * 3600) // 10 hours prior for decay calculations
        request.predicate = NSPredicate(format: "insertionTime >= %@", lookbackTime as NSDate)
        request.sortDescriptors = [NSSortDescriptor(keyPath: \PouchLog.insertionTime, ascending: true)]
        
        var ratesData: [AbsorptionRateData] = []
        
        do {
            let allPouches = try viewContext.fetch(request)
            
            for timePoint in timePoints {
                var pouchRates: [PouchAbsorptionInfo] = []
                var totalRate = 0.0
                
                for pouch in allPouches {
                    guard let insertionTime = pouch.insertionTime, insertionTime <= timePoint else { continue }
                    
                    let removalTime = pouch.removalTime ?? insertionTime.addingTimeInterval(FULL_RELEASE_TIME)
                    
                    // Only consider pouches that are currently in absorption phase
                    if timePoint <= removalTime {
                        let timeInMouth = timePoint.timeIntervalSince(insertionTime)
                        let absorptionRate = calculateInstantAbsorptionRate(
                            nicotineContent: pouch.nicotineAmount,
                            timeInMouth: timeInMouth
                        )
                        let absorptionPercent = min(timeInMouth / FULL_RELEASE_TIME, 1.0)
                        
                        let info = PouchAbsorptionInfo(
                            pouchId: pouch.pouchId ?? UUID(),
                            nicotineAmount: pouch.nicotineAmount,
                            absorptionRate: absorptionRate,
                            absorptionPercent: absorptionPercent
                        )
                        pouchRates.append(info)
                        totalRate += absorptionRate
                    }
                }
                
                let rateData = AbsorptionRateData(
                    time: timePoint,
                    pouches: pouchRates,
                    effectiveRate: totalRate
                )
                ratesData.append(rateData)
            }
        } catch {
            logger.error("Failed to calculate absorption rates: \(error.localizedDescription)")
        }
        
        return ratesData
    }
    
    /// Calculate the instantaneous absorption rate (mg/minute) for a pouch at a specific time
    private func calculateInstantAbsorptionRate(nicotineContent: Double, timeInMouth: TimeInterval) -> Double {
        // Linear absorption model: Rate = (D × A) / FULL_RELEASE_TIME
        // where D = dose, A = 0.30 (absorption fraction)
        // This gives constant absorption rate throughout the absorption phase
        let maxAbsorbed = nicotineContent * ABSORPTION_FRACTION
        let absorptionRate = maxAbsorbed / FULL_RELEASE_TIME // mg per second
        return absorptionRate * 60 // Convert to mg per minute
    }
    
    /// Automatically selects the absorption data for the current time if there's an active pouch
    private func selectCurrentAbsorptionData() {
        let now = Date()
        
        // Find the absorption data closest to the current time
        if let currentAbsorption = absorptionRates.min(by: { a, b in
            abs(a.time.timeIntervalSince(now)) < abs(b.time.timeIntervalSince(now))
        }) {
            // If an active pouch exists, always show the absorption panel
            if hasActivePouch(at: now) {
                selectedAbsorptionData = currentAbsorption
            } else if hasRecentlyDecayingPouch(at: now) {
                // Optionally keep showing shortly after removal (quality-of-life)
                selectedAbsorptionData = currentAbsorption
            } else {
                selectedAbsorptionData = nil
            }
        }
    }
    
    /// Checks if there's currently an active pouch (in absorption phase)
    private func hasActivePouch(at time: Date) -> Bool {
        let request: NSFetchRequest<PouchLog> = PouchLog.fetchRequest()
        request.predicate = NSPredicate(format: "removalTime == nil")
        request.fetchLimit = 1
        
        do {
            let activePouches = try viewContext.fetch(request)
            return !activePouches.isEmpty
        } catch {
            logger.error("Failed to check for active pouches: \(error.localizedDescription)")
            return false
        }
    }
    
    /// Checks if there's a pouch that was recently removed and still decaying
    private func hasRecentlyDecayingPouch(at time: Date) -> Bool {
        let oneHourAgo = time.addingTimeInterval(-3600)
        let request: NSFetchRequest<PouchLog> = PouchLog.fetchRequest()
        request.predicate = NSPredicate(format: "removalTime >= %@", oneHourAgo as NSDate)
        request.fetchLimit = 1
        
        do {
            let recentlyRemoved = try viewContext.fetch(request)
            return !recentlyRemoved.isEmpty
        } catch {
            logger.error("Failed to check for recently removed pouches: \(error.localizedDescription)")
            return false
        }
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
