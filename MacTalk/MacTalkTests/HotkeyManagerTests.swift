//
//  HotkeyManagerTests.swift
//  MacTalkTests
//
//  Focused lifecycle tests for the Carbon registration wrapper.
//

import XCTest
import Carbon
@testable import MacTalk

@MainActor
final class HotkeyManagerTests: XCTestCase {
    func test_registerUnregisterAndReregister() throws {
        let manager = HotkeyManager()
        defer { manager.unregisterAll() }

        let firstID = try XCTUnwrap(manager.register(
            keyCode: UInt32(kVK_F18),
            modifiers: UInt32(cmdKey | optionKey | controlKey)
        ) {})
        manager.unregister(hotkeyID: firstID)

        let secondID = manager.register(
            keyCode: UInt32(kVK_F18),
            modifiers: UInt32(cmdKey | optionKey | controlKey)
        ) {}

        XCTAssertNotNil(secondID)
        XCTAssertNotEqual(firstID, secondID)
    }

    func test_independentManagersRegisterDistinctShortcuts() {
        let first = HotkeyManager()
        let second = HotkeyManager()
        defer {
            first.unregisterAll()
            second.unregisterAll()
        }

        let firstID = first.register(
            keyCode: UInt32(kVK_F18),
            modifiers: UInt32(cmdKey | optionKey | controlKey)
        ) {}
        let secondID = second.register(
            keyCode: UInt32(kVK_F19),
            modifiers: UInt32(cmdKey | optionKey | controlKey)
        ) {}

        XCTAssertNotNil(firstID)
        XCTAssertNotNil(secondID)
    }

    func test_managerDeallocatesAfterUnregisteringCallbacks() {
        weak var weakManager: HotkeyManager?

        autoreleasepool {
            let manager = HotkeyManager()
            weakManager = manager
            _ = manager.register(
                keyCode: UInt32(kVK_F18),
                modifiers: UInt32(cmdKey | optionKey | controlKey)
            ) {}
            manager.unregisterAll()
        }

        XCTAssertNil(weakManager)
    }
}
