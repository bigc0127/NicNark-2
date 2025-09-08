//
//  InventoryAlertTrackerTests.swift
//  nicnark-2Tests
//
//  Tests for inventory alert 24-hour cooldown functionality
//

import XCTest
@testable import nicnark_2

class InventoryAlertTrackerTests: XCTestCase {
    
    override func setUp() {
        super.setUp()
        // Reset tracker state before each test
        InventoryAlertTracker.reset()
    }
    
    override func tearDown() {
        // Clean up after each test
        InventoryAlertTracker.reset()
        super.tearDown()
    }
    
    func testCanShowAlert_FirstTime() {
        let canId = "test-can-1"
        
        // First time should allow alert
        XCTAssertTrue(InventoryAlertTracker.canShowAlert(for: canId))
    }
    
    func testCanShowAlert_WithinCooldown() {
        let canId = "test-can-1"
        
        // Record an alert just now
        InventoryAlertTracker.recordAlert(for: canId)
        
        // Should not allow another alert immediately
        XCTAssertFalse(InventoryAlertTracker.canShowAlert(for: canId))
    }
    
    func testCanShowAlert_AfterCooldown() {
        let canId = "test-can-1"
        
        // Record an alert 25 hours ago (beyond the 24-hour cooldown)
        let pastDate = Date().addingTimeInterval(-25 * 60 * 60) // 25 hours ago
        InventoryAlertTracker.recordAlert(for: canId, date: pastDate)
        
        // Should allow alert after cooldown period
        XCTAssertTrue(InventoryAlertTracker.canShowAlert(for: canId))
    }
    
    func testLastAlert_ReturnsCorrectDate() {
        let canId = "test-can-1"
        let testDate = Date().addingTimeInterval(-1000) // ~16 minutes ago
        
        // Record alert with specific date
        InventoryAlertTracker.recordAlert(for: canId, date: testDate)
        
        // Should return the recorded date (within a second tolerance)
        let retrievedDate = InventoryAlertTracker.lastAlert(for: canId)
        XCTAssertNotNil(retrievedDate)
        XCTAssertEqual(retrievedDate!.timeIntervalSince1970, testDate.timeIntervalSince1970, accuracy: 1.0)
    }
    
    func testLastAlert_NoRecordReturnsNil() {
        let canId = "test-can-nonexistent"
        
        // Should return nil for non-existent can
        XCTAssertNil(InventoryAlertTracker.lastAlert(for: canId))
    }
    
    func testPurge_RemovesInvalidIds() {
        let validCanId = "valid-can"
        let invalidCanId = "invalid-can"
        
        // Record alerts for both cans
        InventoryAlertTracker.recordAlert(for: validCanId)
        InventoryAlertTracker.recordAlert(for: invalidCanId)
        
        // Verify both exist
        XCTAssertNotNil(InventoryAlertTracker.lastAlert(for: validCanId))
        XCTAssertNotNil(InventoryAlertTracker.lastAlert(for: invalidCanId))
        
        // Purge with only valid ID
        InventoryAlertTracker.purge(matching: Set([validCanId]))
        
        // Valid should remain, invalid should be removed
        XCTAssertNotNil(InventoryAlertTracker.lastAlert(for: validCanId))
        XCTAssertNil(InventoryAlertTracker.lastAlert(for: invalidCanId))
    }
    
    func testGetAllAlertRecords() {
        let canId1 = "test-can-1"
        let canId2 = "test-can-2"
        let date1 = Date().addingTimeInterval(-1000)
        let date2 = Date().addingTimeInterval(-2000)
        
        // Record alerts for multiple cans
        InventoryAlertTracker.recordAlert(for: canId1, date: date1)
        InventoryAlertTracker.recordAlert(for: canId2, date: date2)
        
        // Get all records
        let allRecords = InventoryAlertTracker.getAllAlertRecords()
        
        // Should contain both records
        XCTAssertEqual(allRecords.count, 2)
        XCTAssertEqual(allRecords[canId1]!.timeIntervalSince1970, date1.timeIntervalSince1970, accuracy: 1.0)
        XCTAssertEqual(allRecords[canId2]!.timeIntervalSince1970, date2.timeIntervalSince1970, accuracy: 1.0)
    }
    
    func testReset_ClearsAllRecords() {
        let canId = "test-can-1"
        
        // Record an alert
        InventoryAlertTracker.recordAlert(for: canId)
        XCTAssertNotNil(InventoryAlertTracker.lastAlert(for: canId))
        
        // Reset should clear everything
        InventoryAlertTracker.reset()
        XCTAssertNil(InventoryAlertTracker.lastAlert(for: canId))
        XCTAssertEqual(InventoryAlertTracker.getAllAlertRecords().count, 0)
    }
}
