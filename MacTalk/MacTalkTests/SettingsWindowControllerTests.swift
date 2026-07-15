//
//  SettingsWindowControllerTests.swift
//  MacTalkTests
//
//  Stable window contracts only. Settings behavior needs an injectable typed store.
//

import XCTest
@testable import MacTalk

@MainActor
final class SettingsWindowControllerTests: XCTestCase {
    func test_windowConfiguration() throws {
        let controller = SettingsWindowController()
        let window = try XCTUnwrap(controller.window)

        XCTAssertEqual(window.title, "MacTalk Settings")
        XCTAssertTrue(window.styleMask.contains(.titled))
        XCTAssertTrue(window.styleMask.contains(.closable))
        XCTAssertFalse(window.styleMask.contains(.resizable))
    }

    func test_showAndCloseChangeVisibility() {
        let controller = SettingsWindowController()

        controller.showWindow(nil)
        XCTAssertEqual(controller.window?.isVisible, true)

        controller.close()
        XCTAssertEqual(controller.window?.isVisible, false)
    }

    func test_controllerDeallocatesWhenReleased() {
        weak var weakController: SettingsWindowController?

        autoreleasepool {
            weakController = SettingsWindowController()
        }

        XCTAssertNil(weakController)
    }
}
