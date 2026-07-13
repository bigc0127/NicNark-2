//
//  AbsorptionMathTests.swift
//  nicnark-2Tests
//

import XCTest
@testable import nicnark_2

final class AbsorptionMathTests: XCTestCase {

    private let thirtyMin: TimeInterval = 30 * 60
    private let twoHours: TimeInterval = 2 * 3600

    @MainActor
    func testFullAbsorptionAtTimerEnd() {
        let absorbed = AbsorptionConstants.shared.calculateAbsorbedNicotine(
            nicotineContent: 6,
            useTime: thirtyMin,
            fullReleaseTime: thirtyMin
        )
        XCTAssertEqual(absorbed, 6 * ABSORPTION_FRACTION, accuracy: 1e-9)
    }

    @MainActor
    func testHalfTimeIsHalfAbsorbed() {
        let absorbed = AbsorptionConstants.shared.calculateAbsorbedNicotine(
            nicotineContent: 6,
            useTime: 15 * 60,
            fullReleaseTime: thirtyMin
        )
        XCTAssertEqual(absorbed, 6 * ABSORPTION_FRACTION * 0.5, accuracy: 1e-9)
    }

    @MainActor
    func testEarlyRemovalBelowPeak() {
        let early = AbsorptionConstants.shared.calculateAbsorbedNicotine(
            nicotineContent: 6,
            useTime: 10 * 60,
            fullReleaseTime: thirtyMin
        )
        let peak = 6 * ABSORPTION_FRACTION
        XCTAssertLessThan(early, peak)
        XCTAssertEqual(early, peak * (10.0 / 30.0), accuracy: 1e-9)
    }

    @MainActor
    func testAbsorptionCapsAtFullRelease() {
        let over = AbsorptionConstants.shared.calculateAbsorbedNicotine(
            nicotineContent: 6,
            useTime: 2 * thirtyMin,
            fullReleaseTime: thirtyMin
        )
        XCTAssertEqual(over, 6 * ABSORPTION_FRACTION, accuracy: 1e-9)
    }

    @MainActor
    func testHalfLifeHalvesLevel() {
        let initial = 1.8
        let after = AbsorptionConstants.shared.calculateDecayedNicotine(
            initialLevel: initial,
            timeSinceRemoval: twoHours
        )
        XCTAssertEqual(after, initial * 0.5, accuracy: 1e-9)
    }

    @MainActor
    func testTwoHalfLivesQuarterLevel() {
        let initial = 1.8
        let after = AbsorptionConstants.shared.calculateDecayedNicotine(
            initialLevel: initial,
            timeSinceRemoval: 2 * twoHours
        )
        XCTAssertEqual(after, initial * 0.25, accuracy: 1e-9)
    }

    @MainActor
    func testMinutesFromSecondsRounds() {
        XCTAssertEqual(LogService.minutesFromSeconds(89), 1)
        XCTAssertEqual(LogService.minutesFromSeconds(90), 2)
        XCTAssertEqual(LogService.minutesFromSeconds(1800), 30)
    }

    @MainActor
    func testWeightedDurationByNicotine() {
        let result = LogService.calculateWeightedDuration(pouches: [
            (nicotineAmount: 6, duration: 30 * 60),
            (nicotineAmount: 3, duration: 60 * 60)
        ])
        XCTAssertEqual(result, 2400, accuracy: 1e-6)
    }

    @MainActor
    func testWeightedDurationEmptyFallsBack() {
        let result = LogService.calculateWeightedDuration(pouches: [])
        XCTAssertEqual(result, FULL_RELEASE_TIME, accuracy: 1e-6)
    }
}
