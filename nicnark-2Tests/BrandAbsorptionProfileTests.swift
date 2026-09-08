//
//  BrandAbsorptionProfileTests.swift
//  nicnark-2Tests
//

import XCTest
@testable import nicnark_2

final class BrandAbsorptionProfileTests: XCTestCase {

    func testKnownBrands() {
        XCTAssertEqual(BrandAbsorptionProfile.fraction(forBrand: "Zyn"), 0.38)
        XCTAssertEqual(BrandAbsorptionProfile.fraction(forBrand: "ZYN Cool Mint"), 0.38)
        XCTAssertEqual(BrandAbsorptionProfile.fraction(forBrand: "Zyn Ultra"), 0.32)
        XCTAssertEqual(BrandAbsorptionProfile.fraction(forBrand: "Velo"), 0.24)
        XCTAssertEqual(BrandAbsorptionProfile.fraction(forBrand: "Velo Plus"), 0.30)
        XCTAssertEqual(BrandAbsorptionProfile.fraction(forBrand: "FRE"), 0.36)
        XCTAssertEqual(BrandAbsorptionProfile.fraction(forBrand: "ALP"), 0.34)
        XCTAssertEqual(BrandAbsorptionProfile.fraction(forBrand: "CLUE"), 0.33)
        XCTAssertEqual(BrandAbsorptionProfile.fraction(forBrand: "On!"), 0.42)
        XCTAssertEqual(BrandAbsorptionProfile.fraction(forBrand: "On! Plus"), 0.34)
    }

    func testUnknownFallsBackToDefault() {
        XCTAssertEqual(BrandAbsorptionProfile.fraction(forBrand: nil), ABSORPTION_FRACTION)
        XCTAssertEqual(BrandAbsorptionProfile.fraction(forBrand: ""), ABSORPTION_FRACTION)
        XCTAssertEqual(BrandAbsorptionProfile.fraction(forBrand: "Rogue"), ABSORPTION_FRACTION)
    }

    func testBrandCapChangesAbsorbedAmount() {
        let zyn = AbsorptionConstants.shared.calculateAbsorbedNicotine(
            nicotineContent: 6,
            useTime: 30 * 60,
            fullReleaseTime: 30 * 60,
            absorptionFraction: 0.38
        )
        XCTAssertEqual(zyn, 6 * 0.38, accuracy: 1e-9)
    }
}
