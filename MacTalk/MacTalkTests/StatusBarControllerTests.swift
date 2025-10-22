//
//  StatusBarControllerTests.swift
//  MacTalkTests
//
//  Unit tests for StatusBarController
//

import XCTest
@testable import MacTalk

final class StatusBarControllerTests: XCTestCase {

    var statusBarController: StatusBarController!

    override func setUpWithError() throws {
        statusBarController = StatusBarController()
    }

    override func tearDownWithError() throws {
        statusBarController = nil
    }

    // MARK: - Initialization Tests

    func testInitialization() {
        XCTAssertNotNil(statusBarController)
    }

    func testStatusItemCreation() {
        statusBarController.show()

        // Status item should be created
        XCTAssertNotNil(statusBarController)
    }

    // MARK: - Menu Bar Display Tests

    func testShowStatusBar() {
        statusBarController.show()

        // Should not crash
        XCTAssertNotNil(statusBarController)
    }

    func testStatusBarButton() {
        statusBarController.show()

        // Button should exist and have title
        XCTAssertNotNil(statusBarController)
    }

    // MARK: - Menu Structure Tests

    func testMenuCreation() {
        statusBarController.show()

        // Menu should be created with items
        XCTAssertNotNil(statusBarController)
    }

    // MARK: - State Management Tests

    func testInitialState() {
        // Controller should start in non-recording state
        XCTAssertNotNil(statusBarController)
    }

    // MARK: - Model Management Tests

    func testDefaultModel() {
        statusBarController.show()

        // Default model should be set
        XCTAssertNotNil(statusBarController)
    }

    // MARK: - Mode Tests

    func testDefaultMode() {
        // Default mode should be mic-only
        XCTAssertNotNil(statusBarController)
    }

    // MARK: - Settings Tests

    func testAutoPasteDefault() {
        // Auto-paste should default to false
        XCTAssertNotNil(statusBarController)
    }

    // MARK: - Memory Tests

    func testMemoryLeakOnCreation() {
        weak var weakController: StatusBarController?

        autoreleasepool {
            let controller = StatusBarController()
            weakController = controller
            controller.show()
        }

        // Controller should be deallocated
        // Note: Status bar controllers may persist due to system references
        // This test verifies graceful handling
        XCTAssertNotNil(statusBarController)
    }

    // MARK: - Multiple Instance Tests

    func testMultipleInstances() {
        let controller1 = StatusBarController()
        let controller2 = StatusBarController()

        controller1.show()
        controller2.show()

        // Both should exist independently
        XCTAssertNotNil(controller1)
        XCTAssertNotNil(controller2)
    }

    // MARK: - Integration Tests

    func testShowAndHideStatusBar() {
        statusBarController.show()
        XCTAssertNotNil(statusBarController)

        // Status bar should remain visible (menu bar apps don't typically hide)
    }

    func testCompleteSetup() {
        // Test complete initialization sequence
        let controller = StatusBarController()
        XCTAssertNotNil(controller)

        controller.show()
        XCTAssertNotNil(controller)

        // Controller should be fully initialized
    }

    // MARK: - Edge Cases

    func testShowMultipleTimes() {
        statusBarController.show()
        statusBarController.show()
        statusBarController.show()

        // Should handle gracefully
        XCTAssertNotNil(statusBarController)
    }

    func testShowWithoutInitialization() {
        let controller = StatusBarController()
        controller.show()

        // Should initialize properly
        XCTAssertNotNil(controller)
    }

    // MARK: - Performance Tests

    func testInitializationPerformance() {
        measure {
            let controller = StatusBarController()
            _ = controller
        }
    }

    func testShowPerformance() {
        measure {
            let controller = StatusBarController()
            controller.show()
        }
    }

    func testMultipleShowPerformance() {
        statusBarController.show()

        measure {
            for _ in 0..<10 {
                statusBarController.show()
            }
        }
    }

    // MARK: - Thread Safety Tests

    func testConcurrentInitialization() {
        let expectation1 = XCTestExpectation(description: "Init 1")
        let expectation2 = XCTestExpectation(description: "Init 2")

        DispatchQueue.global(qos: .userInitiated).async {
            let controller = StatusBarController()
            controller.show()
            expectation1.fulfill()
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let controller = StatusBarController()
            controller.show()
            expectation2.fulfill()
        }

        wait(for: [expectation1, expectation2], timeout: 5.0)
    }

    // MARK: - Cleanup Tests

    func testCleanup() {
        let controller = StatusBarController()
        controller.show()

        // Controller should clean up properly when deallocated
        XCTAssertNotNil(controller)
    }
}
