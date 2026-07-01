//
//  InsightsSupport.swift
//  nicnark-2
//
//  Shared, self-contained foundation for the new "Insights" family of features.
//
//  This file is the SINGLE SOURCE OF TRUTH for the aggregated statistics that power:
//    • InsightsView      — KPI grid, 14-day bar chart, weekday cadence, streaks, cost, share
//    • DailyGoalCard     — today's count vs. the user's daily goal
//    • ShareExportView   — text summary + CSV export
//
//  DESIGN / CONCURRENCY NOTES
//  --------------------------
//  The project builds under Swift 6 with SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor, so
//  every type here is implicitly @MainActor. That's fine: all callers are SwiftUI views
//  running on the main actor.
//
//  CoreData `PouchLog` objects are NON-Sendable and must never cross an isolation
//  boundary. The factories below take an ALREADY-FETCHED `[PouchLog]` array and, as their
//  very first step, reduce each managed object down to plain value types (Date / Double /
//  Int). Everything the views actually render is stored as value types (Int, Double,
//  String, Date, and small value-type structs) so an `InsightsData` / `NicStats` instance
//  can be passed freely to every subview.
//
//  All math is guarded against empty data, divide-by-zero, and NaN. When there's nothing
//  meaningful to show we return 0, [], or a friendly default string.
//
//  IMPORTANT: We never call `Date()` inside a static STORED initializer (that would bake a
//  build-time timestamp into a constant). `now` is always a normal parameter — evaluated at
//  call time — and `InsightsData.empty` / `NicStats.empty` pass an explicit fixed Date.
//

import SwiftUI
import CoreData

// MARK: - Reduced value type
//
// A single pouch flattened to plain, Sendable-friendly scalars. We build these once at the
// top of every factory so the rest of the aggregation never touches a managed object.

private struct PouchPoint {
    let insertion: Date
    let removal: Date?
    let mg: Double
    let timerMin: Int
    /// Brand/flavor are only needed for the detailed CSV export.
    let brand: String
    let flavor: String
}

private extension Array where Element == PouchLog {
    /// Flatten managed objects → value types, dropping any pouch with no insertion time,
    /// and sort ascending by insertion. This is the ONLY place we read PouchLog fields.
    func reducedToPoints() -> [PouchPoint] {
        self.compactMap { log -> PouchPoint? in
            guard let insertion = log.insertionTime else { return nil }
            return PouchPoint(
                insertion: insertion,
                removal: log.removalTime,
                mg: log.nicotineAmount,
                timerMin: Int(log.timerDuration),
                // brand/flavor intentionally blank: nothing in the Insights stats/CSV/summary
                // uses them, and touching the `can` relationship here fired a Core Data fault
                // PER ROW (thousands of tiny fetches over a full history) — a major source of
                // the lag and device heat. Omitting it makes the reduce ~free.
                brand: "",
                flavor: ""
            )
        }
        .sorted { $0.insertion < $1.insertion }
    }
}

// MARK: - Small helpers (NaN / divide-by-zero safe)

private func safeDivide(_ numerator: Double, _ denominator: Double) -> Double {
    guard denominator != 0, numerator.isFinite, denominator.isFinite else { return 0 }
    let result = numerator / denominator
    return result.isFinite ? result : 0
}

/// "4h 12m", "45m", "0m" — always finite, never negative.
private func formatDurationSeconds(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "0m" }
    let total = Int(seconds.rounded())
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    if hours > 0 {
        return "\(hours)h \(minutes)m"
    } else {
        return "\(minutes)m"
    }
}

// MARK: - Settings (UserDefaults-backed)
//
// All Insights preferences live in UserDefaults only (no Core Data changes). `0` means
// "unset" for the goal and price so views can show a friendly onboarding state.

enum InsightsSettings {
    private enum Keys {
        static let dailyPouchGoal = "insights.dailyPouchGoal"
        static let pricePerTin    = "insights.pricePerTin"
        static let pouchesPerTin  = "insights.pouchesPerTin"
    }

    /// Target maximum pouches per day. `0` = unset (no goal configured).
    static var dailyPouchGoal: Int {
        get { UserDefaults.standard.integer(forKey: Keys.dailyPouchGoal) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.dailyPouchGoal) }
    }

    /// Price of a single tin/can in the user's currency. `0` = unset.
    static var pricePerTin: Double {
        get { UserDefaults.standard.double(forKey: Keys.pricePerTin) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.pricePerTin) }
    }

    /// Pouches per tin. Defaults to 15 when never configured (0 stored → treat as 15).
    static var pouchesPerTin: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: Keys.pouchesPerTin)
            return stored > 0 ? stored : 15
        }
        set { UserDefaults.standard.set(newValue, forKey: Keys.pouchesPerTin) }
    }
}

// MARK: - Small value types used by InsightsData

struct DayCount: Identifiable, Hashable {
    let date: Date
    let count: Int
    var id: Date { date }
}

struct WeekdayAvg: Identifiable, Hashable {
    /// 1 = Sunday ... 7 = Saturday (matches Calendar's `weekday` component).
    let weekday: Int
    let average: Double
    var id: Int { weekday }
}

struct Milestone: Identifiable, Hashable {
    let key: String
    let title: String
    let symbol: String
    let achieved: Bool
    var id: String { key }
}

/// Direction of a period-over-period trend for arrow rendering.
enum Trend {
    case up
    case down
    case flat

    /// SF Symbol suggestion for convenience (views may ignore this).
    var symbolName: String {
        switch self {
        case .up:   return "arrow.up.right"
        case .down: return "arrow.down.right"
        case .flat: return "minus"
        }
    }
}

// MARK: - InsightsData
//
// The rich aggregate consumed by InsightsView, DailyGoalCard, and ShareExportView. Stores
// ONLY value types. Build it with `InsightsData.build(from:...)`.

struct InsightsData {

    // Rolling-window counts
    let todayCount: Int
    let last7Count: Int
    let last30Count: Int

    // Prior equal windows (for trend arrows)
    let prior7Count: Int
    let prior30Count: Int

    // Absorbed mg (stated mg * ABSORPTION_FRACTION) per window
    let todayAbsorbedMg: Double
    let last7AbsorbedMg: Double
    let last30AbsorbedMg: Double

    // 14-day chart data (zero-filled, oldest → newest, ending today)
    let perDayLast14: [DayCount]
    let dailyAverage14: Double

    // Weekday cadence
    let weekdayAverages: [WeekdayAvg]   // always length 7, weekday 1...7
    let peakWeekday: Int                // 1...7, or 1 when no data

    // Gaps
    let averageGapSeconds: Double       // full history
    let longestGapSeconds: Double       // within last 30 days ("nic-free record")

    // Totals
    let daysTracked: Int
    let totalPouches: Int

    // Goal streaks
    let goalStreak: Int
    let goalBestStreak: Int

    // Milestones
    let milestoneProgress: [Milestone]

    // Cost
    let perPouchCost: Double
    let costToday: Double
    let cost7: Double
    let cost30: Double
    let projectedMonthlyCost: Double
    let tinsConsumed30: Double
    let currencySymbol: String

    // Raw value points retained ONLY for CSV export (all plain value types).
    private let points: [PouchPoint]
    private let now: Date

    // MARK: Computed trend helpers

    var trend7: Trend { Self.trend(current: last7Count, prior: prior7Count) }
    var trend30: Trend { Self.trend(current: last30Count, prior: prior30Count) }

    private static func trend(current: Int, prior: Int) -> Trend {
        guard prior > 0 else { return .flat }   // avoid /0 and misleading "up from nothing"
        if current > prior { return .up }
        if current < prior { return .down }
        return .flat
    }

    // MARK: Formatted helpers

    var formattedAverageGap: String { formatDurationSeconds(averageGapSeconds) }
    var formattedLongestGap: String { formatDurationSeconds(longestGapSeconds) }

    /// Format a currency amount using the stored symbol. Falls back to a plain symbol prefix
    /// so we never depend on locale currency codes we don't have.
    func formatted(_ amount: Double) -> String {
        let value = amount.isFinite ? amount : 0
        return "\(currencySymbol)\(String(format: "%.2f", value))"
    }

    // MARK: Share text

    /// Human-readable one-liner block for ShareLink.
    func textSummary() -> String {
        guard totalPouches > 0 else {
            return "Start logging pouches to see your stats."
        }
        var lines: [String] = []
        lines.append("My nicnark stats")
        lines.append("Today: \(todayCount) pouches (~\(String(format: "%.1f", todayAbsorbedMg)) mg absorbed)")
        lines.append("Last 7 days: \(last7Count) pouches (~\(String(format: "%.1f", last7AbsorbedMg)) mg absorbed)")
        if goalStreak > 0 {
            lines.append("Goal streak: \(goalStreak) day\(goalStreak == 1 ? "" : "s")")
        }
        lines.append("All-time: \(totalPouches) pouches over \(daysTracked) day\(daysTracked == 1 ? "" : "s")")
        if perPouchCost > 0 {
            lines.append("Est. last-30-day spend: \(formatted(cost30))")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: CSV (mirrors ExportManager columns)

    /// Full-history CSV using the same columns/formatters as `ExportManager`.
    /// Empty history → header only.
    func csvString() -> String {
        let header = "Date,Time,Nicotine Amount (mg),Duration (minutes),Status,Timer Setting\n"
        guard !points.isEmpty else { return header }

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.calendar = Calendar(identifier: .gregorian)
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.timeZone = TimeZone.current

        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.dateFormat = "HH:mm:ss"
        timeFormatter.timeZone = TimeZone.current

        var csv = header
        for p in points {
            let date = dateFormatter.string(from: p.insertion)
            let time = timeFormatter.string(from: p.insertion)
            let amount = String(format: "%.1f", p.mg)

            let end = p.removal ?? now
            let durationMinutes = max(end.timeIntervalSince(p.insertion), 0) / 60.0
            let duration = String(format: "%.1f", durationMinutes)
            let status = p.removal == nil ? "Active" : "Completed"

            // Timer setting in minutes; fall back to the current global for legacy rows.
            let timerMinutes = p.timerMin > 0 ? Double(p.timerMin) : (FULL_RELEASE_TIME / 60.0)
            let timerSetting = String(format: "%.0f", timerMinutes)

            // Escape commas by wrapping fields that could contain them in quotes. These are
            // all numeric/formatted-safe here, but we keep the CSV robust regardless.
            let row = "\(date),\(time),\(amount),\(duration),\(status),\(timerSetting)\n"
            csv += row
        }
        return csv
    }

    // MARK: - Empty / no-data fallback (for previews)

    /// Built from an empty array using an explicit fixed reference Date (NEVER Date()).
    static let empty: InsightsData = InsightsData.build(
        from: [],
        now: Date(timeIntervalSince1970: 0),
        calendar: .current,
        goalLimit: 0,
        pricePerTin: 0,
        pouchesPerTin: 15,
        currencySymbol: "$"
    )

    // MARK: - Factory

    static func build(
        from pouches: [PouchLog],
        now: Date = Date(),
        calendar: Calendar = .current,
        goalLimit: Int,
        pricePerTin: Double,
        pouchesPerTin: Int,
        currencySymbol: String
    ) -> InsightsData {

        // 1) Reduce managed objects to plain value points immediately.
        let points = pouches.reducedToPoints()

        let startOfToday = calendar.startOfDay(for: now)
        let sevenAgo = now.addingTimeInterval(-7 * 86_400)
        let thirtyAgo = now.addingTimeInterval(-30 * 86_400)
        let priorSevenStart = now.addingTimeInterval(-14 * 86_400)
        let priorThirtyStart = now.addingTimeInterval(-60 * 86_400)

        // 2) Window counts.
        let todayCount = points.filter { $0.insertion >= startOfToday && $0.insertion <= now }.count
        let last7Count = points.filter { $0.insertion >= sevenAgo && $0.insertion <= now }.count
        let last30Count = points.filter { $0.insertion >= thirtyAgo && $0.insertion <= now }.count
        let prior7Count = points.filter { $0.insertion >= priorSevenStart && $0.insertion < sevenAgo }.count
        let prior30Count = points.filter { $0.insertion >= priorThirtyStart && $0.insertion < thirtyAgo }.count

        // 3) Absorbed mg per window.
        func absorbed(_ predicate: (PouchPoint) -> Bool) -> Double {
            let sum = points.filter(predicate).reduce(0.0) { $0 + $1.mg }
            let result = sum * ABSORPTION_FRACTION
            return result.isFinite ? result : 0
        }
        let todayAbsorbedMg = absorbed { $0.insertion >= startOfToday && $0.insertion <= now }
        let last7AbsorbedMg = absorbed { $0.insertion >= sevenAgo && $0.insertion <= now }
        let last30AbsorbedMg = absorbed { $0.insertion >= thirtyAgo && $0.insertion <= now }

        // 4) Bucket by calendar day (used repeatedly below).
        var dayBuckets: [Date: Int] = [:]
        for p in points {
            let day = calendar.startOfDay(for: p.insertion)
            dayBuckets[day, default: 0] += 1
        }

        // 5) 14-day zero-filled series ending today (oldest → newest).
        var perDayLast14: [DayCount] = []
        perDayLast14.reserveCapacity(14)
        for offset in stride(from: 13, through: 0, by: -1) {
            if let day = calendar.date(byAdding: .day, value: -offset, to: startOfToday) {
                let key = calendar.startOfDay(for: day)
                perDayLast14.append(DayCount(date: key, count: dayBuckets[key] ?? 0))
            }
        }
        let sum14 = perDayLast14.reduce(0) { $0 + $1.count }
        let dailyAverage14 = safeDivide(Double(sum14), 14.0)

        // 6) Weekday averages: total pouches on weekday / number of tracked calendar days
        //    that fell on that weekday (a "tracked day" = any day with >= 1 pouch).
        var weekdayPouchTotals = [Int](repeating: 0, count: 8)   // index 1...7 used
        var weekdayTrackedDays = [Int](repeating: 0, count: 8)
        for (day, count) in dayBuckets {
            let wd = calendar.component(.weekday, from: day)      // 1...7
            guard wd >= 1, wd <= 7 else { continue }
            weekdayPouchTotals[wd] += count
            if count >= 1 { weekdayTrackedDays[wd] += 1 }
        }
        var weekdayAverages: [WeekdayAvg] = []
        weekdayAverages.reserveCapacity(7)
        for wd in 1...7 {
            let avg = safeDivide(Double(weekdayPouchTotals[wd]), Double(weekdayTrackedDays[wd]))
            weekdayAverages.append(WeekdayAvg(weekday: wd, average: avg))
        }
        let peakWeekday = weekdayAverages.max(by: { $0.average < $1.average })?.weekday ?? 1

        // 7) Average gap between consecutive insertions (full history).
        var averageGapSeconds = 0.0
        if points.count >= 2 {
            var totalGap = 0.0
            for i in 1..<points.count {
                let gap = points[i].insertion.timeIntervalSince(points[i - 1].insertion)
                if gap.isFinite, gap > 0 { totalGap += gap }
            }
            averageGapSeconds = safeDivide(totalGap, Double(points.count - 1))
        }

        // 8) Longest gap within the last 30 days ("nic-free record").
        let recentPoints = points.filter { $0.insertion >= thirtyAgo && $0.insertion <= now }
        var longestGapSeconds = 0.0
        if recentPoints.count >= 2 {
            for i in 1..<recentPoints.count {
                let gap = recentPoints[i].insertion.timeIntervalSince(recentPoints[i - 1].insertion)
                if gap.isFinite, gap > longestGapSeconds { longestGapSeconds = gap }
            }
        }

        // 9) Totals.
        let daysTracked = dayBuckets.keys.count
        let totalPouches = points.count

        // 10) Goal streaks: consecutive calendar days whose count is >= 1 and <= goalLimit.
        //     Current streak ends today OR yesterday (a clean day so far still counts if
        //     yesterday was on-goal). goalLimit < 1 → treat streaks as 0.
        var goalStreak = 0
        var goalBestStreak = 0
        if goalLimit >= 1 {
            // Determine the anchor: today if today already has an on-goal count, else start
            // from yesterday so an as-yet-empty today doesn't break the streak.
            let todayKey = startOfToday
            let todayOnGoal: Bool = {
                let c = dayBuckets[todayKey] ?? 0
                return c >= 1 && c <= goalLimit
            }()
            var cursor = todayOnGoal ? todayKey : calendar.date(byAdding: .day, value: -1, to: todayKey)
            while let day = cursor {
                let c = dayBuckets[day] ?? 0
                if c >= 1 && c <= goalLimit {
                    goalStreak += 1
                    cursor = calendar.date(byAdding: .day, value: -1, to: day)
                } else {
                    break
                }
            }

            // Best streak across all tracked days.
            let sortedDays = dayBuckets.keys.sorted()
            var run = 0
            var previous: Date?
            for day in sortedDays {
                let c = dayBuckets[day] ?? 0
                let onGoal = c >= 1 && c <= goalLimit
                if onGoal {
                    if let prev = previous,
                       let expected = calendar.date(byAdding: .day, value: 1, to: prev),
                       calendar.isDate(expected, inSameDayAs: day) {
                        run += 1
                    } else {
                        run = 1
                    }
                    goalBestStreak = max(goalBestStreak, run)
                    previous = day
                } else {
                    run = 0
                    previous = day
                }
            }
        }

        // 11) Milestones (pouch thresholds + day thresholds).
        let pouchThresholds: [(Int, String)] = [
            // NB: SF Symbols only has numbered "N.circle" up to 50, so 100 uses a themed icon
            // (100.circle.fill does not exist and rendered blank).
            (10, "10.circle"), (50, "50.circle"), (100, "rosette"),
            (500, "star.circle"), (1000, "crown")
        ]
        let dayThresholds: [(Int, String)] = [
            (7, "calendar"), (30, "calendar.circle"),
            (90, "calendar.badge.clock"), (365, "calendar.circle.fill")
        ]
        var milestoneProgress: [Milestone] = []
        for (n, symbol) in pouchThresholds {
            milestoneProgress.append(
                Milestone(key: "pouch\(n)", title: "\(n) pouches logged",
                          symbol: symbol, achieved: totalPouches >= n)
            )
        }
        for (n, symbol) in dayThresholds {
            milestoneProgress.append(
                Milestone(key: "day\(n)", title: "\(n) days tracked",
                          symbol: symbol, achieved: daysTracked >= n)
            )
        }

        // 12) Cost.
        let perPouchCost = safeDivide(pricePerTin, Double(max(pouchesPerTin, 1)))
        let costToday = Double(todayCount) * perPouchCost
        let cost7 = Double(last7Count) * perPouchCost
        let cost30 = Double(last30Count) * perPouchCost
        let projectedMonthlyCost = safeDivide(cost7, 7.0) * 30.0
        let tinsConsumed30 = safeDivide(Double(last30Count), Double(max(pouchesPerTin, 1)))

        return InsightsData(
            todayCount: todayCount,
            last7Count: last7Count,
            last30Count: last30Count,
            prior7Count: prior7Count,
            prior30Count: prior30Count,
            todayAbsorbedMg: todayAbsorbedMg,
            last7AbsorbedMg: last7AbsorbedMg,
            last30AbsorbedMg: last30AbsorbedMg,
            perDayLast14: perDayLast14,
            dailyAverage14: dailyAverage14,
            weekdayAverages: weekdayAverages,
            peakWeekday: peakWeekday,
            averageGapSeconds: averageGapSeconds,
            longestGapSeconds: longestGapSeconds,
            daysTracked: daysTracked,
            totalPouches: totalPouches,
            goalStreak: goalStreak,
            goalBestStreak: goalBestStreak,
            milestoneProgress: milestoneProgress,
            perPouchCost: perPouchCost,
            costToday: costToday,
            cost7: cost7,
            cost30: cost30,
            projectedMonthlyCost: projectedMonthlyCost,
            tinsConsumed30: tinsConsumed30,
            currencySymbol: currencySymbol,
            points: points,
            now: now
        )
    }
}

// MARK: - NicStats
//
// A flatter aggregate with the specific field names / shapes requested by the spec. It
// mirrors much of InsightsData but exposes tuple-based arrays and index-based weekday
// averages that some views prefer. Both share the same reduction/guarding approach.

struct NicStats {
    let pouchesToday: Int
    let pouches7d: Int
    let pouches30d: Int
    let totalPouches: Int

    let estAbsorbedMgToday: Double
    let estAbsorbedMg7d: Double
    let estAbsorbedMg30d: Double

    /// Last 14 calendar days, oldest → newest, zero-filled.
    let dailyCounts: [(day: Date, count: Int)]

    /// Length 7. Index 0 = Sunday ... 6 = Saturday. Average pouches per that-weekday
    /// tracked day.
    let weekdayAverages: [Double]

    let avgGapMinutes: Double
    let longestGapHours: Double

    /// Consecutive days up to & including yesterday where count <= goal (0 if goal unset).
    let goalStreakDays: Int

    /// Seconds since the most recent pouch insertion, or nil if none.
    let timeSinceLastPouch: TimeInterval?

    let spendToday: Double
    let spend7d: Double
    let spend30d: Double
    let projectedMonthlySpend: Double

    // Retained value points for the detailed CSV helper.
    fileprivate let points: [PouchPoint]

    static func compute(
        from pouches: [PouchLog],
        goal: Int,
        pricePerTin: Double,
        pouchesPerTin: Int,
        now: Date
    ) -> NicStats {
        let calendar = Calendar.current
        let points = pouches.reducedToPoints()

        let startOfToday = calendar.startOfDay(for: now)
        let sevenAgo = now.addingTimeInterval(-7 * 86_400)
        let thirtyAgo = now.addingTimeInterval(-30 * 86_400)

        let pouchesToday = points.filter { $0.insertion >= startOfToday && $0.insertion <= now }.count
        let pouches7d = points.filter { $0.insertion >= sevenAgo && $0.insertion <= now }.count
        let pouches30d = points.filter { $0.insertion >= thirtyAgo && $0.insertion <= now }.count
        let totalPouches = points.count

        func absorbed(_ predicate: (PouchPoint) -> Bool) -> Double {
            let sum = points.filter(predicate).reduce(0.0) { $0 + $1.mg }
            let r = sum * ABSORPTION_FRACTION
            return r.isFinite ? r : 0
        }
        let estAbsorbedMgToday = absorbed { $0.insertion >= startOfToday && $0.insertion <= now }
        let estAbsorbedMg7d = absorbed { $0.insertion >= sevenAgo && $0.insertion <= now }
        let estAbsorbedMg30d = absorbed { $0.insertion >= thirtyAgo && $0.insertion <= now }

        // Day buckets.
        var dayBuckets: [Date: Int] = [:]
        for p in points {
            dayBuckets[calendar.startOfDay(for: p.insertion), default: 0] += 1
        }

        // 14-day series.
        var dailyCounts: [(day: Date, count: Int)] = []
        dailyCounts.reserveCapacity(14)
        for offset in stride(from: 13, through: 0, by: -1) {
            if let day = calendar.date(byAdding: .day, value: -offset, to: startOfToday) {
                let key = calendar.startOfDay(for: day)
                dailyCounts.append((day: key, count: dayBuckets[key] ?? 0))
            }
        }

        // Weekday averages, index 0 = Sunday.
        var weekdayPouchTotals = [Int](repeating: 0, count: 7)
        var weekdayTrackedDays = [Int](repeating: 0, count: 7)
        for (day, count) in dayBuckets {
            let wd = calendar.component(.weekday, from: day)   // 1 (Sun) ... 7 (Sat)
            let idx = wd - 1
            guard idx >= 0, idx < 7 else { continue }
            weekdayPouchTotals[idx] += count
            if count >= 1 { weekdayTrackedDays[idx] += 1 }
        }
        var weekdayAverages = [Double](repeating: 0, count: 7)
        for i in 0..<7 {
            weekdayAverages[i] = safeDivide(Double(weekdayPouchTotals[i]), Double(weekdayTrackedDays[i]))
        }

        // Average gap (minutes) over full history.
        var avgGapMinutes = 0.0
        if points.count >= 2 {
            var totalGap = 0.0
            for i in 1..<points.count {
                let gap = points[i].insertion.timeIntervalSince(points[i - 1].insertion)
                if gap.isFinite, gap > 0 { totalGap += gap }
            }
            avgGapMinutes = safeDivide(totalGap, Double(points.count - 1)) / 60.0
        }

        // Longest gap (hours) within last 30 days.
        let recentPoints = points.filter { $0.insertion >= thirtyAgo && $0.insertion <= now }
        var longestGapSeconds = 0.0
        if recentPoints.count >= 2 {
            for i in 1..<recentPoints.count {
                let gap = recentPoints[i].insertion.timeIntervalSince(recentPoints[i - 1].insertion)
                if gap.isFinite, gap > longestGapSeconds { longestGapSeconds = gap }
            }
        }
        let longestGapHours = longestGapSeconds / 3600.0

        // Goal streak: consecutive days up to & including YESTERDAY where count <= goal.
        // goal unset (< 1) → 0.
        var goalStreakDays = 0
        if goal >= 1, let yesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday) {
            var cursor: Date? = yesterday
            while let day = cursor {
                let c = dayBuckets[day] ?? 0
                if c >= 1 && c <= goal {
                    goalStreakDays += 1
                    cursor = calendar.date(byAdding: .day, value: -1, to: day)
                } else {
                    break
                }
            }
        }

        // Time since last pouch.
        let timeSinceLastPouch: TimeInterval? = points.last.map { max(now.timeIntervalSince($0.insertion), 0) }

        // Spend.
        let perPouchCost = safeDivide(pricePerTin, Double(max(pouchesPerTin, 1)))
        let spendToday = Double(pouchesToday) * perPouchCost
        let spend7d = Double(pouches7d) * perPouchCost
        let spend30d = Double(pouches30d) * perPouchCost
        let projectedMonthlySpend = safeDivide(spend7d, 7.0) * 30.0

        return NicStats(
            pouchesToday: pouchesToday,
            pouches7d: pouches7d,
            pouches30d: pouches30d,
            totalPouches: totalPouches,
            estAbsorbedMgToday: estAbsorbedMgToday,
            estAbsorbedMg7d: estAbsorbedMg7d,
            estAbsorbedMg30d: estAbsorbedMg30d,
            dailyCounts: dailyCounts,
            weekdayAverages: weekdayAverages,
            avgGapMinutes: avgGapMinutes,
            longestGapHours: longestGapHours,
            goalStreakDays: goalStreakDays,
            timeSinceLastPouch: timeSinceLastPouch,
            spendToday: spendToday,
            spend7d: spend7d,
            spend30d: spend30d,
            projectedMonthlySpend: projectedMonthlySpend,
            points: points
        )
    }

    /// A fixed-Date empty instance for previews (never uses Date() in a stored initializer).
    static let empty: NicStats = NicStats.compute(
        from: [],
        goal: 0,
        pricePerTin: 0,
        pouchesPerTin: 15,
        now: Date(timeIntervalSince1970: 0)
    )

    // MARK: Share text

    func shareSummaryText() -> String {
        guard totalPouches > 0 else {
            return "Start logging pouches to see your stats."
        }
        var lines: [String] = []
        lines.append("My nicnark stats")
        lines.append("Today: \(pouchesToday) pouches (~\(String(format: "%.1f", estAbsorbedMgToday)) mg absorbed)")
        lines.append("Last 7 days: \(pouches7d) pouches")
        lines.append("Last 30 days: \(pouches30d) pouches")
        if goalStreakDays > 0 {
            lines.append("Goal streak: \(goalStreakDays) day\(goalStreakDays == 1 ? "" : "s")")
        }
        lines.append("All-time: \(totalPouches) pouches")
        return lines.joined(separator: "\n")
    }
}

// MARK: - Detailed CSV (ISO8601 + brand/flavor)
//
// A richer, standalone CSV that includes brand/flavor. Free function so it can be called
// with either a fresh fetch or the same array that produced a NicStats.

func csvOfLogs(_ pouches: [PouchLog]) -> String {
    let header = "Insertion,Removal,Nicotine (mg),Duration (minutes),Brand,Flavor\n"
    let points = pouches.reducedToPoints()
    guard !points.isEmpty else { return header }

    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime]

    // Escape a field for CSV: wrap in quotes and double internal quotes if it contains a
    // comma, quote, or newline.
    func escape(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") {
            let doubled = field.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(doubled)\""
        }
        return field
    }

    let now = Date()
    var csv = header
    for p in points {
        let insertion = iso.string(from: p.insertion)
        let removal = p.removal.map { iso.string(from: $0) } ?? ""
        let mg = String(format: "%.1f", p.mg)
        let end = p.removal ?? now
        let durationMin = String(format: "%.1f", max(end.timeIntervalSince(p.insertion), 0) / 60.0)
        let row = [
            escape(insertion),
            escape(removal),
            mg,
            durationMin,
            escape(p.brand),
            escape(p.flavor)
        ].joined(separator: ",")
        csv += row + "\n"
    }
    return csv
}

// MARK: - KPICard
//
// A reusable card matching the app's visual language: a Color(.secondarySystemBackground)
// fill with ~16pt rounded corners. Used across the KPI grid in InsightsView.

struct KPICard: View {
    let title: String
    let value: String
    let subtitle: String?
    let systemImage: String
    let tint: Color

    init(
        title: String,
        value: String,
        subtitle: String? = nil,
        systemImage: String,
        tint: Color = .blue
    ) {
        self.title = title
        self.value = value
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.tint = tint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.subheadline)
                    .foregroundColor(tint)
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Text(value)
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(16)
    }
}

#Preview {
    ScrollView {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            KPICard(title: "Today", value: "3", subtitle: "~1.8 mg absorbed",
                    systemImage: "calendar", tint: .blue)
            KPICard(title: "Last 7 days", value: "21", subtitle: "trend up",
                    systemImage: "chart.bar", tint: .green)
            KPICard(title: "Goal streak", value: "5 days", systemImage: "flame", tint: .orange)
            KPICard(title: "All-time", value: "142", systemImage: "sum", tint: .purple)
        }
        .padding()
    }
}
