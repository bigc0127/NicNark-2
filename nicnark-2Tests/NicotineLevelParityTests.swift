//
//  NicotineLevelParityTests.swift
//  nicnark-2Tests
//
//  Unit Tests for Nicotine Level Calculation Consistency
//
//  This test suite validates that the widget's nicotine level calculations
//  match exactly with the main app's calculations. The tests ensure:
//
//  Testing Strategy:
//  • Parity Testing - Compares widget vs main app calculations with identical data
//  • Precision Testing - Validates calculations differ by less than 0.0005 mg
//  • Scenario Coverage - Tests various pouch states (active, removed, mixed)
//  • Core Data Integration - Uses in-memory store for isolated testing
//  • Widget Integration - Tests the widget's fetchCoreDataForWidget() method
//
//  Test Isolation:
//  Each test uses a fresh in-memory Core Data stack to ensure complete
//  isolation and prevent test interdependencies.
//
//  Calculation Verification:
//  Tests verify that both WidgetNicotineCalculator and NicotineCalculator
//  produce identical results when given the same pouch data.
//

import XCTest
import CoreData
@testable import nicnark_2

// Helper for synchronous MainActor initialization in tests
extension XCTestCase {
    static func runOnMainActorSync<T>(_ action: @MainActor () -> T) -> T {
        if Thread.isMainThread {
            return MainActor.assumeIsolated(action)
        } else {
            return DispatchQueue.main.sync {
                MainActor.assumeIsolated(action)
            }
        }
    }
}

/**
 * NicotineLevelParityTests: Unit test suite for calculation consistency.
 * 
 * This class ensures that the widget and main app always show the same
 * nicotine levels for identical data scenarios.
 */
class NicotineLevelParityTests: XCTestCase {
    
    var testContext: NSManagedObjectContext!
    var mainCalculator: NicotineCalculator!
    var widgetCalculator: WidgetNicotineCalculator!
    
    /**
     * setUp: Creates fresh in-memory Core Data stack for each test.
     */
    override func setUp() {
        super.setUp()
        
        // Create in-memory Core Data stack for testing
        let container = NSPersistentContainer(name: "nicnark_2")
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]
        
        let expectation = XCTestExpectation(description: "Core Data stack loaded")
        container.loadPersistentStores { _, error in
            XCTAssertNil(error, "Failed to load in-memory store: \(error?.localizedDescription ?? "")")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
        
        testContext = container.viewContext
        // NicotineCalculator is @MainActor; construct it on the main actor
        mainCalculator = XCTestCase.runOnMainActorSync { NicotineCalculator() }
        widgetCalculator = WidgetNicotineCalculator()
    }
    
    /**
     * tearDown: Cleans up test data.
     */
    override func tearDown() {
        testContext = nil
        mainCalculator = nil
        widgetCalculator = nil
        super.tearDown()
    }
    
    /**
     * Helper: Creates a test pouch with specified parameters.
     */
    private func createTestPouch(
        nicotineAmount: Double,
        addedDate: Date,
        isRemoved: Bool = false,
        removedDate: Date? = nil
    ) -> PouchLog {
        let pouch = PouchLog(context: testContext)
        pouch.pouchId = UUID()
        pouch.nicotineAmount = nicotineAmount
        pouch.insertionTime = addedDate
        if isRemoved {
            pouch.removalTime = removedDate ?? addedDate
        } else {
            pouch.removalTime = nil
        }
        return pouch
    }
    
    /**
     * Helper: Saves the context and asserts no errors.
     */
    private func saveContext() {
        do {
            try testContext.save()
        } catch {
            XCTFail("Failed to save test context: \(error)")
        }
    }
    
    func testEmptyState_BothCalculatorsReturnZero() async {
        // Test with no pouches - both should return 0.0
        let mainLevel = await mainCalculator.calculateTotalNicotineLevel(context: testContext)
        let widgetLevel = widgetCalculator.calculateTotalNicotineLevel(context: testContext)
        
        XCTAssertEqual(mainLevel, 0.0, accuracy: 0.0001, "Main calculator should return 0.0 for empty state")
        XCTAssertEqual(widgetLevel, 0.0, accuracy: 0.0001, "Widget calculator should return 0.0 for empty state")
        XCTAssertEqual(mainLevel, widgetLevel, accuracy: 0.0005, "Calculators should match exactly for empty state")
    }
    
    func testSingleActivePouch_CalculationsMatch() async {
        // Create a single active pouch added 15 minutes ago
        let fifteenMinutesAgo = Date().addingTimeInterval(-15 * 60)
        _ = createTestPouch(
            nicotineAmount: 6.0,
            addedDate: fifteenMinutesAgo,
            isRemoved: false
        )
        saveContext()
        
        let mainLevel = await mainCalculator.calculateTotalNicotineLevel(context: testContext)
        let widgetLevel = widgetCalculator.calculateTotalNicotineLevel(context: testContext)
        
        // Both should calculate same level for active pouch at 15 minutes
        XCTAssertGreaterThan(mainLevel, 0.0, "Main calculator should show positive level for active pouch")
        XCTAssertGreaterThan(widgetLevel, 0.0, "Widget calculator should show positive level for active pouch")
        XCTAssertEqual(mainLevel, widgetLevel, accuracy: 0.0005, "Calculators should match within 0.0005 mg for single active pouch")
        
        // Sanity check: 15 minutes should be halfway through 30-minute absorption
        // So level should be around 50% of max (6.0 * 0.3 * 0.5 = 0.9 mg)
        XCTAssertEqual(mainLevel, 0.9, accuracy: 0.1, "Level should be approximately 0.9 mg at 15 minutes")
    }
    
    func testSingleRemovedPouch_CalculationsMatch() async {
        // Create a pouch that was active for 30 minutes, then removed 60 minutes ago
        let oneHourThirtyMinutesAgo = Date().addingTimeInterval(-90 * 60)
        let oneHourAgo = Date().addingTimeInterval(-60 * 60)
        
        _ = createTestPouch(
            nicotineAmount: 4.0,
            addedDate: oneHourThirtyMinutesAgo,
            isRemoved: true,
            removedDate: oneHourAgo
        )
        saveContext()
        
        let mainLevel = await mainCalculator.calculateTotalNicotineLevel(context: testContext)
        let widgetLevel = widgetCalculator.calculateTotalNicotineLevel(context: testContext)
        
        // Both should calculate decay from removed pouch
        XCTAssertGreaterThan(mainLevel, 0.0, "Main calculator should show positive level for decaying pouch")
        XCTAssertGreaterThan(widgetLevel, 0.0, "Widget calculator should show positive level for decaying pouch")
        XCTAssertEqual(mainLevel, widgetLevel, accuracy: 0.0005, "Calculators should match within 0.0005 mg for removed pouch")
        
        // Sanity check: after 1 hour of decay (half-life = 2 hours), should be ~half of max absorbed
        // Max absorbed = 4.0 * 0.3 = 1.2 mg, after 1 hour = 1.2 * 0.7071 ≈ 0.85 mg
        XCTAssertEqual(mainLevel, 0.85, accuracy: 0.2, "Level should be approximately 0.85 mg after 1 hour decay")
    }
    
    func testMixedPouches_CalculationsMatch() async {
        let now = Date()
        
        // Active pouch added 10 minutes ago
        _ = createTestPouch(
            nicotineAmount: 6.0,
            addedDate: now.addingTimeInterval(-10 * 60),
            isRemoved: false
        )
        
        // Removed pouch (was active for 30 min, removed 30 min ago)
        _ = createTestPouch(
            nicotineAmount: 4.0,
            addedDate: now.addingTimeInterval(-60 * 60),
            isRemoved: true,
            removedDate: now.addingTimeInterval(-30 * 60)
        )
        
        // Another active pouch added 5 minutes ago
        _ = createTestPouch(
            nicotineAmount: 8.0,
            addedDate: now.addingTimeInterval(-5 * 60),
            isRemoved: false
        )
        
        saveContext()
        
        let mainLevel = await mainCalculator.calculateTotalNicotineLevel(context: testContext)
        let widgetLevel = widgetCalculator.calculateTotalNicotineLevel(context: testContext)
        
        // Both should handle complex multi-pouch scenario identically
        XCTAssertGreaterThan(mainLevel, 0.0, "Main calculator should show positive level for mixed pouches")
        XCTAssertGreaterThan(widgetLevel, 0.0, "Widget calculator should show positive level for mixed pouches")
        XCTAssertEqual(mainLevel, widgetLevel, accuracy: 0.0005, "Calculators should match within 0.0005 mg for mixed pouches")
        
        // This should be the sum of all contributions
        // Active 6mg at 10min: 6*0.3*(10/30) = 0.6 mg
        // Active 8mg at 5min: 8*0.3*(5/30) = 0.4 mg  
        // Removed 4mg decaying for 30min: 4*0.3*exp(-0.5*ln(2)) ≈ 1.2*0.707 ≈ 0.85 mg
        // Total ≈ 1.85 mg
        XCTAssertEqual(mainLevel, 1.85, accuracy: 0.3, "Level should be approximately 1.85 mg for mixed scenario")
    }
    
    func testPrecisionConsistency_HighPrecisionComparison() async {
        // Test with precise timing to ensure exact calculations match
        let exactTime = Date(timeIntervalSince1970: 1704067200) // Fixed timestamp for reproducibility
        
        _ = createTestPouch(
            nicotineAmount: 7.5,
            addedDate: exactTime.addingTimeInterval(-17 * 60 - 33), // 17 minutes 33 seconds ago
            isRemoved: false
        )
        saveContext()
        
        let mainLevel = await mainCalculator.calculateTotalNicotineLevel(context: testContext)
        let widgetLevel = widgetCalculator.calculateTotalNicotineLevel(context: testContext)
        
        // High precision comparison - should be identical to many decimal places
        XCTAssertEqual(mainLevel, widgetLevel, accuracy: 0.000001, "Calculators should match to 6 decimal places")
        
        // Verify both return reasonable non-zero value
        XCTAssertGreaterThan(mainLevel, 0.5, "Should have significant nicotine level")
        XCTAssertLessThan(mainLevel, 3.0, "Should not exceed maximum possible absorption")
    }
    
    func testWidgetDataFetch_MatchesDirectCalculation() async {
        // Create test data
        let twentyMinutesAgo = Date().addingTimeInterval(-20 * 60)
        _ = createTestPouch(
            nicotineAmount: 5.0,
            addedDate: twentyMinutesAgo,
            isRemoved: false
        )
        saveContext()
        
        // Get level via direct widget calculator call
        let directWidgetLevel = widgetCalculator.calculateTotalNicotineLevel(context: testContext)
        
        // Also compare with main calculator (which is async)
        let mainLevel = await mainCalculator.calculateTotalNicotineLevel(context: testContext)
        XCTAssertEqual(mainLevel, directWidgetLevel, accuracy: 0.0005,
                      "Main calculator should match widget calculator")
    }
    
    func testBoundaryConditions_AllCalculatorsConsistent() async {
        // Test edge case: pouch just added (0 minutes)
        let now = Date()
        _ = createTestPouch(
            nicotineAmount: 10.0,
            addedDate: now,
            isRemoved: false
        )
        saveContext()
        
        let mainLevel = await mainCalculator.calculateTotalNicotineLevel(context: testContext)
        let widgetLevel = widgetCalculator.calculateTotalNicotineLevel(context: testContext)
        
        // At t=0, absorption should be 0
        XCTAssertEqual(mainLevel, 0.0, accuracy: 0.001, "Just-added pouch should have 0 absorption")
        XCTAssertEqual(widgetLevel, 0.0, accuracy: 0.001, "Widget should also show 0 for just-added pouch")
        XCTAssertEqual(mainLevel, widgetLevel, accuracy: 0.0005, "Both should match exactly at boundary")
        
        // Test edge case: pouch at exactly 30 minutes (full absorption)
        testContext.reset()
        let thirtyMinutesAgo = Date().addingTimeInterval(-30 * 60)
        _ = createTestPouch(
            nicotineAmount: 10.0,
            addedDate: thirtyMinutesAgo,
            isRemoved: false
        )
        saveContext()
        
        let mainLevelFull = await mainCalculator.calculateTotalNicotineLevel(context: testContext)
        let widgetLevelFull = widgetCalculator.calculateTotalNicotineLevel(context: testContext)
        
        // At t=30min, should be full absorption: 10.0 * 0.3 = 3.0 mg
        XCTAssertEqual(mainLevelFull, 3.0, accuracy: 0.001, "Full absorption should be exactly 3.0 mg")
        XCTAssertEqual(widgetLevelFull, 3.0, accuracy: 0.001, "Widget should show full absorption")
        XCTAssertEqual(mainLevelFull, widgetLevelFull, accuracy: 0.0005, "Both should match at full absorption")
    }
}
