//
//  InsightsDataTests.swift
//  nicnark-2Tests
//

import XCTest
import CoreData
@testable import nicnark_2

final class InsightsDataTests: XCTestCase {

    /// Fixed UTC calendar — never Calendar.current (timezone-dependent day buckets).
    private var utcCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }

    /// Midday UTC so "today" windows are stable across local TZ.
    private var fixedNow: Date {
        var parts = DateComponents()
        parts.year = 2024
        parts.month = 6
        parts.day = 15
        parts.hour = 12
        parts.minute = 0
        parts.second = 0
        return utcCalendar.date(from: parts)!
    }

    @MainActor
    func testEmptyInsights() {
        let data = InsightsData.build(
            from: [],
            now: fixedNow,
            calendar: utcCalendar,
            goalLimit: 0,
            pricePerTin: 0,
            pouchesPerTin: 15,
            currencySymbol: "$"
        )
        XCTAssertEqual(data.todayCount, 0)
        XCTAssertEqual(data.todayAbsorbedMg, 0, accuracy: 1e-9)
        XCTAssertEqual(data.totalPouches, 0)
    }

    @MainActor
    func testAbsorbedUsesUseTimeNotStatedPeak() throws {
        let controller = PersistenceController(inMemory: true)
        let ctx = controller.container.viewContext
        let now = fixedNow

        let pouch = PouchLog(context: ctx)
        pouch.pouchId = UUID()
        // In mouth 15 of 30 min → half peak absorption
        pouch.insertionTime = now.addingTimeInterval(-20 * 60)
        pouch.removalTime = now.addingTimeInterval(-5 * 60)
        pouch.nicotineAmount = 6
        pouch.timerDuration = 30
        try ctx.save()

        let data = InsightsData.build(
            from: [pouch],
            now: now,
            calendar: utcCalendar,
            goalLimit: 10,
            pricePerTin: 5,
            pouchesPerTin: 15,
            currencySymbol: "$"
        )

        let expected = 6 * ABSORPTION_FRACTION * 0.5
        XCTAssertEqual(data.todayAbsorbedMg, expected, accuracy: 1e-6)
        XCTAssertNotEqual(data.todayAbsorbedMg, 6 * ABSORPTION_FRACTION, accuracy: 1e-6)
        XCTAssertEqual(data.todayCount, 1)
    }

    @MainActor
    func testFullSessionAbsorbsPeak() throws {
        let controller = PersistenceController(inMemory: true)
        let ctx = controller.container.viewContext
        let now = fixedNow

        let pouch = PouchLog(context: ctx)
        pouch.pouchId = UUID()
        pouch.insertionTime = now.addingTimeInterval(-40 * 60)
        pouch.removalTime = now.addingTimeInterval(-10 * 60)
        pouch.nicotineAmount = 6
        pouch.timerDuration = 30
        try ctx.save()

        let data = InsightsData.build(
            from: [pouch],
            now: now,
            calendar: utcCalendar,
            goalLimit: 10,
            pricePerTin: 0,
            pouchesPerTin: 15,
            currencySymbol: "$"
        )
        XCTAssertEqual(data.todayAbsorbedMg, 6 * ABSORPTION_FRACTION, accuracy: 1e-6)
    }
}
