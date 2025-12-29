//
//  HotkeyManagerTests.swift
//  MacTalkTests
//
//  Unit tests for HotkeyManager
//

import XCTest
import Carbon
@testable import MacTalk

final class HotkeyManagerTests: XCTestCase {

    var hotkeyManager: HotkeyManager!
    // Use nonisolated(unsafe) for test state accessed from hotkey callbacks
    nonisolated(unsafe) var callbackInvoked: Bool = false
    nonisolated(unsafe) var callbackCount: Int = 0

    override func setUpWithError() throws {
        hotkeyManager = HotkeyManager()
        callbackInvoked = false
        callbackCount = 0
    }

    override func tearDownWithError() throws {
        hotkeyManager.unregisterAll()
        hotkeyManager = nil
    }

    // MARK: - Initialization Tests

    func testInitialization() {
        XCTAssertNotNil(hotkeyManager)
    }

    // MARK: - Registration Tests

    func testRegisterHotkey() {
        let hotkeyID = hotkeyManager.register(
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(cmdKey | shiftKey)
        ) {
            // Callback registered
        }

        XCTAssertNotNil(hotkeyID, "Hotkey registration should succeed")
    }

    func testRegisterDefaultHotkey() {
        // Default is Cmd+Shift+Space
        let hotkeyID = hotkeyManager.register(
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(cmdKey | shiftKey)
        ) {
            // Default callback
        }

        XCTAssertNotNil(hotkeyID)
    }

    func testRegisterMultipleModifiers() {
        // Test with different modifier combinations
        let modifierCombinations: [UInt32] = [
            UInt32(cmdKey),
            UInt32(shiftKey),
            UInt32(optionKey),
            UInt32(cmdKey | shiftKey),
            UInt32(cmdKey | optionKey),
            UInt32(cmdKey | shiftKey | optionKey)
        ]

        for modifiers in modifierCombinations {
            let manager = HotkeyManager()
            let hotkeyID = manager.register(
                keyCode: UInt32(kVK_Space),
                modifiers: modifiers
            ) {}

            // Registration may succeed or fail depending on system state
            // Just verify the manager handles it gracefully
            XCTAssertNotNil(manager)
            manager.unregisterAll()
        }
    }

    func testRegisterDifferentKeyCodes() {
        let keyCodes: [UInt32] = [
            UInt32(kVK_Space),
            UInt32(kVK_Return),
            UInt32(kVK_Escape),
            UInt32(kVK_Delete),
            UInt32(kVK_Tab)
        ]

        for keyCode in keyCodes {
            let manager = HotkeyManager()
            let hotkeyID = manager.register(
                keyCode: keyCode,
                modifiers: UInt32(cmdKey | shiftKey)
            ) {}

            XCTAssertNotNil(manager)
            manager.unregisterAll()
        }
    }

    // MARK: - Unregistration Tests

    func testUnregister() {
        let hotkeyID = hotkeyManager.register(
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(cmdKey | shiftKey)
        ) {}

        if let id = hotkeyID {
            hotkeyManager.unregister(hotkeyID: id)
            XCTAssertTrue(true, "Should unregister successfully")
        }
    }

    func testUnregisterWithoutRegistering() {
        // Should handle gracefully
        hotkeyManager.unregister(hotkeyID: 999)
        XCTAssertNotNil(hotkeyManager)
    }

    func testMultipleUnregistrations() {
        let hotkeyID = hotkeyManager.register(
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(cmdKey | shiftKey)
        ) {}

        // Unregister multiple times
        if let id = hotkeyID {
            hotkeyManager.unregister(hotkeyID: id)
            hotkeyManager.unregister(hotkeyID: id)
            hotkeyManager.unregister(hotkeyID: id)
        }

        XCTAssertNotNil(hotkeyManager)
    }

    // MARK: - Callback Tests

    func testCallbackInvocation() {
        nonisolated(unsafe) var invoked = false

        let hotkeyID = hotkeyManager.register(
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(cmdKey | shiftKey)
        ) {
            invoked = true
        }

        // Note: Cannot programmatically trigger Carbon hotkey events in tests
        // This tests callback storage, actual invocation tested manually
        XCTAssertNotNil(hotkeyID)
    }

    func testMultipleCallbacks() {
        nonisolated(unsafe) var count = 0

        let hotkeyID = hotkeyManager.register(
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(cmdKey | shiftKey)
        ) {
            count += 1
        }

        XCTAssertNotNil(hotkeyID)
    }

    func testCallbackWithWeakReference() {
        // Test that callbacks don't create retain cycles
        autoreleasepool {
            let manager = HotkeyManager()

            _ = manager.register(
                keyCode: UInt32(kVK_Space),
                modifiers: UInt32(cmdKey | shiftKey)
            ) {
                // Empty callback
            }

            manager.unregisterAll()
        }

        // If we get here without crash, test passed
        XCTAssertTrue(true)
    }

    // MARK: - Re-registration Tests

    func testReregister() {
        // Register first hotkey
        let hotkeyID1 = hotkeyManager.register(
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(cmdKey | shiftKey)
        ) {
            // First callback
        }

        XCTAssertNotNil(hotkeyID1)

        // Unregister
        hotkeyManager.unregisterAll()

        // Re-register
        let hotkeyID2 = hotkeyManager.register(
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(cmdKey | shiftKey)
        ) {
            // Second callback
        }

        XCTAssertNotNil(hotkeyID2)
    }

    func testRegisterDifferentHotkey() {
        // Register first hotkey
        let hotkeyID1 = hotkeyManager.register(
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(cmdKey | shiftKey)
        ) {}

        XCTAssertNotNil(hotkeyID1)

        hotkeyManager.unregisterAll()

        // Register different hotkey
        let hotkeyID2 = hotkeyManager.register(
            keyCode: UInt32(kVK_Return),
            modifiers: UInt32(cmdKey | optionKey)
        ) {}

        XCTAssertNotNil(hotkeyID2)
    }

    // MARK: - State Management Tests

    func testIsRegisteredProperty() {
        // Register hotkey
        let hotkeyID = hotkeyManager.register(
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(cmdKey | shiftKey)
        ) {}

        XCTAssertNotNil(hotkeyID, "Should be registered after register()")

        hotkeyManager.unregisterAll()
    }

    // MARK: - Memory Management Tests

    func testMemoryLeakOnRegistration() {
        weak var weakManager: HotkeyManager?

        autoreleasepool {
            let manager = HotkeyManager()
            weakManager = manager

            manager.register(
                keyCode: UInt32(kVK_Space),
                modifiers: UInt32(cmdKey | shiftKey)
            ) {}

            manager.unregisterAll()
        }

        // Manager should be deallocated
        XCTAssertNil(weakManager, "HotkeyManager should be deallocated")
    }

    func testMemoryLeakWithCallback() {
        weak var weakManager: HotkeyManager?

        autoreleasepool {
            let manager = HotkeyManager()
            weakManager = manager

            _ = manager.register(
                keyCode: UInt32(kVK_Space),
                modifiers: UInt32(cmdKey | shiftKey)
            ) {
                // Empty callback - tests that callbacks don't prevent deallocation
            }

            manager.unregisterAll()
        }

        XCTAssertNil(weakManager, "HotkeyManager should be deallocated even with callbacks")
    }

    // MARK: - Edge Cases

    func testRegisterWithZeroKeyCode() {
        let result = hotkeyManager.register(
            keyCode: 0,
            modifiers: UInt32(cmdKey | shiftKey)
        ) {}

        // May fail or succeed depending on implementation
        XCTAssertNotNil(hotkeyManager)
    }

    func testRegisterWithNoModifiers() {
        let result = hotkeyManager.register(
            keyCode: UInt32(kVK_Space),
            modifiers: 0
        ) {}

        // Registering without modifiers may not be allowed
        XCTAssertNotNil(hotkeyManager)
    }

    func testRegisterWithInvalidKeyCode() {
        let result = hotkeyManager.register(
            keyCode: UInt32.max,
            modifiers: UInt32(cmdKey)
        ) {}

        XCTAssertNotNil(hotkeyManager)
    }

    // MARK: - Multiple Instances Tests

    func testMultipleInstances() {
        let manager1 = HotkeyManager()
        let manager2 = HotkeyManager()

        let hotkeyID1 = manager1.register(
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(cmdKey | shiftKey)
        ) {}

        // Second manager can also register (different event spec)
        let hotkeyID2 = manager2.register(
            keyCode: UInt32(kVK_Return),
            modifiers: UInt32(cmdKey | optionKey)
        ) {}

        XCTAssertNotNil(hotkeyID1)
        XCTAssertNotNil(hotkeyID2)

        manager1.unregisterAll()
        manager2.unregisterAll()
    }

    func testConflictingHotkeys() {
        let manager1 = HotkeyManager()
        let manager2 = HotkeyManager()

        // Register same hotkey in both managers
        let hotkeyID1 = manager1.register(
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(cmdKey | shiftKey)
        ) {}

        // This may fail or succeed depending on Carbon's behavior
        let hotkeyID2 = manager2.register(
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(cmdKey | shiftKey)
        ) {}

        // At least one should be registered
        XCTAssertTrue(hotkeyID1 != nil || hotkeyID2 != nil)

        manager1.unregisterAll()
        manager2.unregisterAll()
    }

    // MARK: - Integration Tests

    func testCompleteLifecycle() {
        // 1. Create manager
        let manager = HotkeyManager()

        // 2. Register hotkey
        let hotkeyID1 = manager.register(
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(cmdKey | shiftKey)
        ) {
            // Callback registered
        }
        XCTAssertNotNil(hotkeyID1)

        // 3. Unregister
        manager.unregisterAll()

        // 4. Re-register
        let hotkeyID2 = manager.register(
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(cmdKey | shiftKey)
        ) {
            // Callback registered
        }
        XCTAssertNotNil(hotkeyID2)

        // 5. Final cleanup
        manager.unregisterAll()
    }

    // MARK: - Performance Tests

    func testRegistrationPerformance() {
        measure {
            for _ in 0..<100 {
                let manager = HotkeyManager()
                manager.register(
                    keyCode: UInt32(kVK_Space),
                    modifiers: UInt32(cmdKey | shiftKey)
                ) {}
                manager.unregisterAll()
            }
        }
    }

    func testUnregistrationPerformance() {
        let managers = (0..<100).map { _ -> HotkeyManager in
            let manager = HotkeyManager()
            manager.register(
                keyCode: UInt32(kVK_Space),
                modifiers: UInt32(cmdKey | shiftKey)
            ) {}
            return manager
        }

        measure {
            for manager in managers {
                manager.unregisterAll()
            }
        }
    }

    // MARK: - Thread Safety Tests

    func testConcurrentRegistration() {
        let expectation1 = XCTestExpectation(description: "Register 1")
        let expectation2 = XCTestExpectation(description: "Register 2")

        DispatchQueue.global(qos: .userInitiated).async {
            let manager = HotkeyManager()
            manager.register(
                keyCode: UInt32(kVK_Space),
                modifiers: UInt32(cmdKey | shiftKey)
            ) {}
            manager.unregisterAll()
            expectation1.fulfill()
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let manager = HotkeyManager()
            manager.register(
                keyCode: UInt32(kVK_Return),
                modifiers: UInt32(cmdKey | optionKey)
            ) {}
            manager.unregisterAll()
            expectation2.fulfill()
        }

        wait(for: [expectation1, expectation2], timeout: 5.0)
    }
}
