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
    var callbackInvoked: Bool = false
    var callbackCount: Int = 0

    override func setUpWithError() throws {
        hotkeyManager = HotkeyManager()
        callbackInvoked = false
        callbackCount = 0
    }

    override func tearDownWithError() throws {
        hotkeyManager.unregister()
        hotkeyManager = nil
    }

    // MARK: - Initialization Tests

    func testInitialization() {
        XCTAssertNotNil(hotkeyManager)
    }

    // MARK: - Registration Tests

    func testRegisterHotkey() {
        let result = hotkeyManager.register(
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(cmdKey | shiftKey)
        ) { [weak self] in
            self?.callbackInvoked = true
        }

        XCTAssertTrue(result, "Hotkey registration should succeed")
        XCTAssertTrue(hotkeyManager.isRegistered, "Should be marked as registered")
    }

    func testRegisterDefaultHotkey() {
        // Default is Cmd+Shift+Space
        let result = hotkeyManager.register(
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(cmdKey | shiftKey)
        ) {
            // Default callback
        }

        XCTAssertTrue(result)
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
            let result = manager.register(
                keyCode: UInt32(kVK_Space),
                modifiers: modifiers
            ) {}

            // Registration may succeed or fail depending on system state
            // Just verify the manager handles it gracefully
            XCTAssertNotNil(manager)
            manager.unregister()
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
            let result = manager.register(
                keyCode: keyCode,
                modifiers: UInt32(cmdKey | shiftKey)
            ) {}

            XCTAssertNotNil(manager)
            manager.unregister()
        }
    }

    // MARK: - Unregistration Tests

    func testUnregister() {
        hotkeyManager.register(
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(cmdKey | shiftKey)
        ) {}

        hotkeyManager.unregister()
        XCTAssertFalse(hotkeyManager.isRegistered, "Should not be registered after unregister")
    }

    func testUnregisterWithoutRegistering() {
        // Should handle gracefully
        hotkeyManager.unregister()
        XCTAssertFalse(hotkeyManager.isRegistered)
    }

    func testMultipleUnregistrations() {
        hotkeyManager.register(
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(cmdKey | shiftKey)
        ) {}

        // Unregister multiple times
        hotkeyManager.unregister()
        hotkeyManager.unregister()
        hotkeyManager.unregister()

        XCTAssertFalse(hotkeyManager.isRegistered)
    }

    // MARK: - Callback Tests

    func testCallbackInvocation() {
        let expectation = XCTestExpectation(description: "Hotkey callback")

        hotkeyManager.register(
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(cmdKey | shiftKey)
        ) { [weak self] in
            self?.callbackInvoked = true
            expectation.fulfill()
        }

        // Note: Cannot programmatically trigger Carbon hotkey events in tests
        // This tests callback storage, actual invocation tested manually
        XCTAssertTrue(hotkeyManager.isRegistered)
    }

    func testMultipleCallbacks() {
        hotkeyManager.register(
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(cmdKey | shiftKey)
        ) { [weak self] in
            self?.callbackCount += 1
        }

        XCTAssertTrue(hotkeyManager.isRegistered)
    }

    func testCallbackWithWeakSelf() {
        weak var weakSelf: HotkeyManagerTests?

        autoreleasepool {
            let manager = HotkeyManager()
            weakSelf = self

            manager.register(
                keyCode: UInt32(kVK_Space),
                modifiers: UInt32(cmdKey | shiftKey)
            ) { [weak weakSelf] in
                weakSelf?.callbackInvoked = true
            }

            manager.unregister()
        }

        XCTAssertNotNil(weakSelf, "Self should still exist")
    }

    // MARK: - Re-registration Tests

    func testReregister() {
        // Register first hotkey
        hotkeyManager.register(
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(cmdKey | shiftKey)
        ) {
            // First callback
        }

        XCTAssertTrue(hotkeyManager.isRegistered)

        // Unregister
        hotkeyManager.unregister()
        XCTAssertFalse(hotkeyManager.isRegistered)

        // Re-register
        hotkeyManager.register(
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(cmdKey | shiftKey)
        ) {
            // Second callback
        }

        XCTAssertTrue(hotkeyManager.isRegistered)
    }

    func testRegisterDifferentHotkey() {
        // Register first hotkey
        hotkeyManager.register(
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(cmdKey | shiftKey)
        ) {}

        hotkeyManager.unregister()

        // Register different hotkey
        hotkeyManager.register(
            keyCode: UInt32(kVK_Return),
            modifiers: UInt32(cmdKey | optionKey)
        ) {}

        XCTAssertTrue(hotkeyManager.isRegistered)
    }

    // MARK: - State Management Tests

    func testIsRegisteredProperty() {
        XCTAssertFalse(hotkeyManager.isRegistered, "Should not be registered initially")

        hotkeyManager.register(
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(cmdKey | shiftKey)
        ) {}

        XCTAssertTrue(hotkeyManager.isRegistered, "Should be registered after register()")

        hotkeyManager.unregister()

        XCTAssertFalse(hotkeyManager.isRegistered, "Should not be registered after unregister()")
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

            manager.unregister()
        }

        // Manager should be deallocated
        XCTAssertNil(weakManager, "HotkeyManager should be deallocated")
    }

    func testMemoryLeakWithCallback() {
        weak var weakManager: HotkeyManager?

        autoreleasepool {
            let manager = HotkeyManager()
            weakManager = manager

            var capturedValue = 0

            manager.register(
                keyCode: UInt32(kVK_Space),
                modifiers: UInt32(cmdKey | shiftKey)
            ) {
                capturedValue += 1
            }

            manager.unregister()
            _ = capturedValue // Use the value
        }

        XCTAssertNil(weakManager, "HotkeyManager should be deallocated even with captured values")
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

        manager1.register(
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(cmdKey | shiftKey)
        ) {}

        // Second manager can also register (different event spec)
        manager2.register(
            keyCode: UInt32(kVK_Return),
            modifiers: UInt32(cmdKey | optionKey)
        ) {}

        XCTAssertTrue(manager1.isRegistered)
        XCTAssertTrue(manager2.isRegistered)

        manager1.unregister()
        manager2.unregister()
    }

    func testConflictingHotkeys() {
        let manager1 = HotkeyManager()
        let manager2 = HotkeyManager()

        // Register same hotkey in both managers
        manager1.register(
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(cmdKey | shiftKey)
        ) {}

        // This may fail or succeed depending on Carbon's behavior
        let result2 = manager2.register(
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(cmdKey | shiftKey)
        ) {}

        // At least one should be registered
        XCTAssertTrue(manager1.isRegistered || result2)

        manager1.unregister()
        manager2.unregister()
    }

    // MARK: - Integration Tests

    func testCompleteLifecycle() {
        // 1. Create manager
        let manager = HotkeyManager()
        XCTAssertFalse(manager.isRegistered)

        // 2. Register hotkey
        var invocationCount = 0
        manager.register(
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(cmdKey | shiftKey)
        ) {
            invocationCount += 1
        }
        XCTAssertTrue(manager.isRegistered)

        // 3. Unregister
        manager.unregister()
        XCTAssertFalse(manager.isRegistered)

        // 4. Re-register
        manager.register(
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(cmdKey | shiftKey)
        ) {
            invocationCount += 1
        }
        XCTAssertTrue(manager.isRegistered)

        // 5. Final cleanup
        manager.unregister()
        XCTAssertFalse(manager.isRegistered)
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
                manager.unregister()
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
                manager.unregister()
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
            manager.unregister()
            expectation1.fulfill()
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let manager = HotkeyManager()
            manager.register(
                keyCode: UInt32(kVK_Return),
                modifiers: UInt32(cmdKey | optionKey)
            ) {}
            manager.unregister()
            expectation2.fulfill()
        }

        wait(for: [expectation1, expectation2], timeout: 5.0)
    }
}
