//
//  HUDWindowControllerTests.swift
//  MacTalkTests
//
//  Stable AppKit contracts only. Transcript rendering needs an observable view model.
//

import XCTest
@testable import MacTalk

@MainActor
final class HUDWindowControllerTests: XCTestCase {
    func test_windowUsesFloatingBorderlessPresentation() throws {
        let controller = HUDWindowController()
        let window = try XCTUnwrap(controller.window)

        XCTAssertEqual(window.level, .floating)
        XCTAssertTrue(window.styleMask.contains(.borderless))
        XCTAssertFalse(window.styleMask.contains(.titled))
        XCTAssertFalse(window.styleMask.contains(.closable))
    }

    func test_controllerDeallocatesWhenReleased() {
        weak var weakController: HUDWindowController?

        autoreleasepool {
            let controller = HUDWindowController()
            weakController = controller
        }

        XCTAssertNil(weakController)
    }
}
