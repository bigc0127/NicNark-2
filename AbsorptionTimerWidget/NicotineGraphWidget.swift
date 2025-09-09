import WidgetKit
import SwiftUI
import Charts
import CoreData
import os.log
import AppIntents

// MARK: - Widget Timeline Entry
struct NicotineGraphEntry: TimelineEntry {
    let date: Date
    let chartData: [NicotineChartPoint]
    let timeSinceLastPouch: String
    let currentLevel: Double
    let hasActivePouches: Bool
    let updatedText: String
    
    static let placeholder = NicotineGraphEntry(
        date: Date(),
        chartData: [
            NicotineChartPoint(time: Date().addingTimeInterval(-3600), level: 2.1),
            NicotineChartPoint(time: Date().addingTimeInterval(-1800), level: 4.5),
            NicotineChartPoint(time: Date(), level: 1.8)
        ],
        timeSinceLastPouch: "2 hours 15 mins since last pouch",
        currentLevel: 1.8,
        hasActivePouches: false,
        updatedText: "Updated: just now"
    )
}

// MARK: - Chart Data Point
struct NicotineChartPoint: Identifiable, Hashable {
    let id = UUID()
    let time: Date
    let level: Double
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - Widget Provider
struct NicotineGraphProvider: TimelineProvider {
    private let logger = Logger(subsystem: "com.nicnark.nicnark-2", category: "NicotineWidget")
    private let absorptionConstants = AbsorptionConstants.shared
    
    func placeholder(in context: Context) -> NicotineGraphEntry {
        NicotineGraphEntry.placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (NicotineGraphEntry) -> ()) {
        logger.info("📱 Widget snapshot requested")
        Task {
            let entry = await generateEntry()
            completion(entry)
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> ()) {
        logger.info("📱 Widget timeline requested")
        Task {
            let currentEntry = await generateEntry()
            
            // More aggressive update schedule:
            // - Every 1 minute if there are active pouches (for real-time updates)
            // - Every 5 minutes otherwise (to catch new activity)
            let updateInterval = currentEntry.hasActivePouches ? 60.0 : 300.0
            let nextUpdateDate = Date().addingTimeInterval(updateInterval)
            
            // Use after policy with calculated next update date
            let timeline = Timeline(entries: [currentEntry], policy: .after(nextUpdateDate))
            completion(timeline)
        }
    }
    
    private func generateEntry() async -> NicotineGraphEntry {
        let persistenceHelper = WidgetPersistenceHelper()
        let now = Date()
        
        // Default: App Group snapshot (reliable across app and widget)
        var currentLevel = persistenceHelper.getCurrentNicotineLevel()
        var hasActivePouches = persistenceHelper.isActivityRunning()
        var chartData = generateFallbackChartData(currentLevel: currentLevel, now: now)
        var timeSinceText = calculateTimeSinceLastPouchFallback(now: now)
        let lastUpdated = persistenceHelper.getSnapshotLastUpdated()
        var updatedText = formatUpdatedText(since: lastUpdated ?? now, now: now)
        
        // Only attempt Core Data if we explicitly know it's readable in this process
        if persistenceHelper.isCoreDataReadable() {
            let result = await fetchCoreDataForWidget(now: now)
            if result.success {
                currentLevel = result.currentLevel
                chartData = result.chartData
                timeSinceText = result.timeSince
                hasActivePouches = result.hasActive
                updatedText = "Updated: just now"
            }
        }
        
        return NicotineGraphEntry(
            date: now,
            chartData: chartData,
            timeSinceLastPouch: timeSinceText,
            currentLevel: currentLevel,
            hasActivePouches: hasActivePouches,
            updatedText: updatedText
        )
    }
    
    private func generateChartData(from pouches: [PouchLog], now: Date, sixHoursAgo: Date) -> [NicotineChartPoint] {
        var timePoints: [Date] = []
        var currentTime = sixHoursAgo
        
        // Create time points every 30 minutes for widget chart (less dense than main app)
        while currentTime <= now {
            timePoints.append(currentTime)
            currentTime = currentTime.addingTimeInterval(30 * 60) // 30 minutes
        }
        
        return timePoints.compactMap { timePoint in
            let totalLevel = calculateTotalNicotineLevelAt(time: timePoint, pouches: pouches)
            return NicotineChartPoint(time: timePoint, level: max(0, totalLevel))
        }
    }
    
    private func calculateTotalNicotineLevelAt(time: Date, pouches: [PouchLog]) -> Double {
        var totalLevel = 0.0
        
        for pouchLog in pouches {
            guard let insertionTime = pouchLog.insertionTime else { continue }
            
            // Only consider pouches that were inserted before our calculation timestamp
            guard insertionTime <= time else { continue }
            
            let removalTime = pouchLog.removalTime ?? insertionTime.addingTimeInterval(FULL_RELEASE_TIME)
            
            let contribution = calculatePouchContribution(
                pouchLog: pouchLog,
                currentTime: time,
                insertionTime: insertionTime,
                endTime: removalTime
            )
            totalLevel += contribution
        }
        
        return max(0, totalLevel) // Ensure non-negative
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
    
    private func calculateTimeSinceLastPouch(pouches: [PouchLog], now: Date) -> String {
        // Get all pouches to find the most recent activity (either insertion or removal)
        let persistenceHelper = WidgetPersistenceHelper()
        let context = persistenceHelper.backgroundContext()
        
        // First check if there are any active pouches (not removed yet)
        let activePouchRequest = PouchLog.fetchRequest()
        activePouchRequest.predicate = NSPredicate(format: "removalTime == nil")
        activePouchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \PouchLog.insertionTime, ascending: false)]
        activePouchRequest.fetchLimit = 1
        
        if let activePouch = try? context.fetch(activePouchRequest).first,
           let insertionTime = activePouch.insertionTime {
            // If there's an active pouch, use its insertion time
            let timeDiff = now.timeIntervalSince(insertionTime)
            let totalMinutes = Int(ceil(timeDiff / 60.0))
            let hours = totalMinutes / 60
            let minutes = totalMinutes % 60
            
            if hours == 0 {
                return minutes == 1 ? "1 min since last pouch" : "\(minutes) mins since last pouch"
            } else if minutes == 0 {
                return hours == 1 ? "1 hour since last pouch" : "\(hours) hours since last pouch"
            } else {
                let hourText = hours == 1 ? "hour" : "hours"
                let minText = minutes == 1 ? "min" : "mins"
                return "\(hours) \(hourText) \(minutes) \(minText) since last pouch"
            }
        }
        
        // No active pouches, find the most recently removed pouch
        let removedPouchRequest = PouchLog.fetchRequest()
        removedPouchRequest.predicate = NSPredicate(format: "removalTime != nil")
        removedPouchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \PouchLog.removalTime, ascending: false)]
        removedPouchRequest.fetchLimit = 1
        
        if let lastRemovedPouch = try? context.fetch(removedPouchRequest).first,
           let removalTime = lastRemovedPouch.removalTime {
            // Use the removal time of the most recently removed pouch
            let timeDiff = now.timeIntervalSince(removalTime)
            let totalMinutes = Int(ceil(timeDiff / 60.0))
            let hours = totalMinutes / 60
            let minutes = totalMinutes % 60
            
            if hours == 0 {
                return minutes == 1 ? "1 min since last pouch" : "\(minutes) mins since last pouch"
            } else if minutes == 0 {
                return hours == 1 ? "1 hour since last pouch" : "\(hours) hours since last pouch"
            } else {
                let hourText = hours == 1 ? "hour" : "hours"
                let minText = minutes == 1 ? "min" : "mins"
                return "\(hours) \(hourText) \(minutes) \(minText) since last pouch"
            }
        }
        
        return "No pouches logged yet"
    }
    
    // MARK: - Fallback Methods for Widget
    private func generateFallbackChartData(currentLevel: Double, now: Date) -> [NicotineChartPoint] {
        let sixHoursAgo = Calendar.current.date(byAdding: .hour, value: -6, to: now) ?? now
        var timePoints: [Date] = []
        var currentTime = sixHoursAgo
        
        // Create time points every 30 minutes
        while currentTime <= now {
            timePoints.append(currentTime)
            currentTime = currentTime.addingTimeInterval(30 * 60) // 30 minutes
        }
        
        // Generate a simple decay curve if there's a current level
        return timePoints.enumerated().map { index, timePoint in
            let progress = Double(index) / Double(timePoints.count - 1)
            let level = currentLevel > 0 ? currentLevel * (0.3 + 0.7 * progress) : 0.0
            return NicotineChartPoint(time: timePoint, level: max(0, level))
        }
    }
    
    private func calculateTimeSinceLastPouchFallback(now: Date) -> String {
        let persistenceHelper = WidgetPersistenceHelper()
        
        // Try to get last updated time as a proxy
        if let lastUpdated = persistenceHelper.getSnapshotLastUpdated() {
            let timeDiff = now.timeIntervalSince(lastUpdated)
            
            // Round seconds up to next minute
            let totalMinutes = Int(ceil(timeDiff / 60.0))
            let hours = totalMinutes / 60
            let minutes = totalMinutes % 60
            
            if hours == 0 {
                return minutes == 1 ? "1 min since last pouch" : "\(minutes) mins since last pouch"
            } else if minutes == 0 {
                return hours == 1 ? "1 hour since last pouch" : "\(hours) hours since last pouch"
            } else {
                let hourText = hours == 1 ? "hour" : "hours"
                let minText = minutes == 1 ? "min" : "mins"
                return "\(hours) \(hourText) \(minutes) \(minText) since last pouch"
            }
        }
        
        return "No recent data available"
    }
    
    private func formatUpdatedText(since: Date, now: Date) -> String {
        let timeDiff = now.timeIntervalSince(since)
        
        if timeDiff < 60 {
            return "Updated: just now"
        } else if timeDiff < 3600 {
            let minutes = Int(timeDiff / 60)
            return "Updated: \(minutes) min\(minutes == 1 ? "" : "s") ago"
        } else if timeDiff < 86400 {
            let hours = Int(timeDiff / 3600)
            return "Updated: \(hours) hour\(hours == 1 ? "" : "s") ago"
        } else {
            return "Updated: over a day ago"
        }
    }
    
    // MARK: - Core Data Access for Widget
    private func fetchCoreDataForWidget(now: Date) async -> (success: Bool, currentLevel: Double, chartData: [NicotineChartPoint], timeSince: String, hasActive: Bool) {
        let persistenceHelper = WidgetPersistenceHelper()
        let context = persistenceHelper.backgroundContext()
        
        do {
            // Fetch recent pouches (last 6 hours for chart)
            let sixHoursAgo = Calendar.current.date(byAdding: .hour, value: -6, to: now) ?? now
            let recentPouchesRequest = PouchLog.fetchRequest()
            recentPouchesRequest.predicate = NSPredicate(format: "insertionTime >= %@", sixHoursAgo as NSDate)
            recentPouchesRequest.sortDescriptors = [NSSortDescriptor(keyPath: \PouchLog.insertionTime, ascending: true)]
            
            let recentPouches = try context.fetch(recentPouchesRequest)
            
            // Fetch ALL pouches from last 10 hours for comprehensive level calculation (including decay)
            let tenHoursAgo = now.addingTimeInterval(-10 * 3600)
            let allPouchesRequest = PouchLog.fetchRequest()
            allPouchesRequest.predicate = NSPredicate(format: "insertionTime >= %@", tenHoursAgo as NSDate)
            let allPouches = try context.fetch(allPouchesRequest)
            
            // Generate chart data from recent pouches (6 hours for display)
            let chartData = generateChartData(from: recentPouches, now: now, sixHoursAgo: sixHoursAgo)
            
            // Calculate current total nicotine level using ALL pouches (for decay calculation)
            let currentLevel = calculateTotalNicotineLevelAt(time: now, pouches: allPouches)
            
            // Check for active pouches
            let activePouchesRequest = PouchLog.fetchRequest()
            activePouchesRequest.predicate = NSPredicate(format: "removalTime == nil")
            let activePouches = try context.fetch(activePouchesRequest)
            let hasActive = !activePouches.isEmpty
            
            // Calculate time since last pouch
            let timeSince = calculateTimeSinceLastPouch(pouches: recentPouches, now: now)
            
            logger.info("📱 Widget successfully fetched Core Data: level=\(currentLevel), points=\(chartData.count), hasActive=\(hasActive)")
            
            return (success: true, currentLevel: currentLevel, chartData: chartData, timeSince: timeSince, hasActive: hasActive)
            
        } catch {
            logger.error("📱 Widget Core Data fetch failed: \(error.localizedDescription)")
            return (success: false, currentLevel: 0, chartData: [], timeSince: "No data available", hasActive: false)
        }
    }
}

// MARK: - Widget Views
struct NicotineGraphWidgetEntryView: View {
    var entry: NicotineGraphProvider.Entry
    @Environment(\.widgetFamily) var family
    
    var body: some View {
        switch family {
        case .systemSmall:
            SmallWidgetView(entry: entry)
        case .systemMedium:
            MediumWidgetView(entry: entry)
        case .systemLarge:
            LargeWidgetView(entry: entry)
        default:
            SmallWidgetView(entry: entry)
        }
    }
}

// MARK: - Small Widget (Text Only)
struct SmallWidgetView: View {
    let entry: NicotineGraphEntry
    
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "pills.fill")
                    .foregroundColor(.blue)
                    .font(.title2)
                Text("NicNark")
                    .font(.headline)
                    .fontWeight(.bold)
                Spacer()
            }
            
            Spacer()
            
            VStack(spacing: 4) {
                Text(entry.timeSinceLastPouch)
                    .font(.caption)
                    .fontWeight(.medium)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.7)
                
                if entry.currentLevel > 0 {
                    Text("Current: \(entry.currentLevel, specifier: "%.2f") mg")
                        .font(.caption2)
                        .foregroundColor(levelColor(for: entry.currentLevel))
                        .fontWeight(.semibold)
                }
                Text(entry.updatedText)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            // Add refresh button when no active pouches
            if !entry.hasActivePouches {
                if #available(iOS 17.0, *) {
                    Button(intent: RefreshWidgetIntent()) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption2)
                            Text("Sync")
                                .font(.caption2)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                }
            }
        }
        .padding()
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

// MARK: - Medium Widget (Text + Compact Chart)
struct MediumWidgetView: View {
    let entry: NicotineGraphEntry
    
    var body: some View {
        HStack(spacing: 12) {
            // Left side: Text info
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "pills.fill")
                        .foregroundColor(.blue)
                    Text("NicNark")
                        .font(.headline)
                        .fontWeight(.bold)
                }
                
                Spacer()
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.timeSinceLastPouch)
                        .font(.caption)
                        .fontWeight(.medium)
                        .minimumScaleFactor(0.8)
                    
                    if entry.currentLevel > 0 {
                        Text("Current: \(entry.currentLevel, specifier: "%.2f") mg")
                            .font(.caption2)
                            .foregroundColor(levelColor(for: entry.currentLevel))
                            .fontWeight(.semibold)
                    }
                    
                    Text("Last 6 Hours")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(entry.updatedText)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                // Add refresh button when no active pouches
                if !entry.hasActivePouches {
                    if #available(iOS 17.0, *) {
                        Button(intent: RefreshWidgetIntent()) {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.caption)
                                Text("Sync Data")
                                    .font(.caption)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
            }
            
            // Right side: Compact chart
            if !entry.chartData.isEmpty {
                Chart(entry.chartData) { point in
                    LineMark(
                        x: .value("Time", point.time),
                        y: .value("Level", point.level)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(.blue)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    
                    AreaMark(
                        x: .value("Time", point.time),
                        y: .value("Level", point.level)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(.blue.opacity(0.2))
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(width: 120, height: 80)
            }
        }
        .padding()
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

// MARK: - Large Widget (Text + Full Chart)
struct LargeWidgetView: View {
    let entry: NicotineGraphEntry
    
    var body: some View {
        VStack(spacing: 12) {
            // Header
            HStack {
                Image(systemName: "pills.fill")
                    .foregroundColor(.blue)
                    .font(.title2)
                Text("NicNark - Nicotine Levels")
                    .font(.headline)
                    .fontWeight(.bold)
                Spacer()
                
                if entry.currentLevel > 0 {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Current")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text("\(entry.currentLevel, specifier: "%.2f") mg")
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundColor(levelColor(for: entry.currentLevel))
                    }
                }
            }
            
            // Chart
            if !entry.chartData.isEmpty {
                Chart(entry.chartData) { point in
                    LineMark(
                        x: .value("Time", point.time),
                        y: .value("Level", point.level)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(
                        .linearGradient(
                            colors: [.blue.opacity(0.8), .blue],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .lineStyle(StrokeStyle(lineWidth: 2.5))
                    
                    AreaMark(
                        x: .value("Time", point.time),
                        y: .value("Level", point.level)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(
                        .linearGradient(
                            colors: [.blue.opacity(0.3), .blue.opacity(0.05)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .hour, count: 2)) { value in
                        AxisValueLabel(format: .dateTime.hour())
                    }
                }
                .chartYAxis {
                    AxisMarks { value in
                        AxisValueLabel()
                    }
                }
                .frame(height: 120)
            }
            
            // Footer with time since last pouch
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.timeSinceLastPouch)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                    Text(entry.updatedText)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer()
                
                // Add refresh button when no active pouches
                if !entry.hasActivePouches {
                    if #available(iOS 17.0, *) {
                        Button(intent: RefreshWidgetIntent()) {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.caption)
                                Text("Sync")
                                    .font(.caption)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    } else {
                        Text("Last 6 Hours")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                } else {
                    Text("Last 6 Hours")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

// MARK: - Helper Functions
private func formatUpdatedText(since lastUpdated: Date?, now: Date) -> String {
    guard let last = lastUpdated else { return "Updated: just now" }
    let seconds = max(0, Int(now.timeIntervalSince(last)))
    let minutes = seconds / 60
    let hours = minutes / 60
    if hours > 0 {
        return hours == 1 ? "Updated: 1h ago" : "Updated: \(hours)h ago"
    } else if minutes > 0 {
        return minutes == 1 ? "Updated: 1m ago" : "Updated: \(minutes)m ago"
    } else {
        return "Updated: just now"
    }
}

private func levelColor(for level: Double) -> Color {
    switch level {
    case 0..<1: return .green
    case 1..<3: return .yellow
    case 3..<6: return .orange
    case 6..<10: return .red
    default: return .purple
    }
}

// MARK: - Widget Refresh Intent
@available(iOS 17.0, *)
struct RefreshWidgetIntent: AppIntent {
    static var title: LocalizedStringResource = "Refresh Widget"
    static var description = IntentDescription("Force refresh the widget data")
    
    func perform() async throws -> some IntentResult {
        // Force Core Data to refresh and reload widget timelines
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

// MARK: - Widget Configuration
struct NicotineGraphWidget: Widget {
    let kind: String = "NicotineGraphWidget"

    var body: some WidgetConfiguration {
        // Always use StaticConfiguration for this widget
        // The refresh button uses Button(intent:) which works with StaticConfiguration
        StaticConfiguration(kind: kind, provider: NicotineGraphProvider()) { entry in
            NicotineGraphWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Nicotine Levels")
        .description("Track your nicotine levels over time and see when you last used a pouch.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
