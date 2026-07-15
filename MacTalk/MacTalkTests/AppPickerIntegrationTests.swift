//
//  AppPickerIntegrationTests.swift
//  MacTalkTests
//
//  Stable AppKit and callback contracts that do not require ScreenCaptureKit TCC.
//

import XCTest
@testable import MacTalk

@MainActor
final class AppPickerIntegrationTests: XCTestCase {
    func test_windowConfiguration() throws {
        let controller = AppPickerWindowController(sources: [])
        let window = try XCTUnwrap(controller.window)

        XCTAssertEqual(window.title, "Select Audio Source")
        XCTAssertEqual(window.frame.size.width, 440, accuracy: 1)
        XCTAssertEqual(window.frame.size.height, 380, accuracy: 1)
        XCTAssertTrue(window.styleMask.contains(.titled))
        XCTAssertTrue(window.styleMask.contains(.closable))
        XCTAssertFalse(window.styleMask.contains(.resizable))
    }

    func test_selectionCallbackReceivesSelectedSource() {
        let controller = AppPickerWindowController(sources: [])
        let source = AppPickerWindowController.AudioSource(
            app: nil,
            display: nil,
            name: "Test Source",
            icon: nil
        )
        var receivedName: String?
        controller.onSelection = { receivedName = $0.name }

        controller.onSelection?(source)

        XCTAssertEqual(receivedName, "Test Source")
    }

    func test_showAndCloseChangeWindowVisibility() {
        let controller = AppPickerWindowController(sources: [])

        controller.showWindow(nil)
        XCTAssertEqual(controller.window?.isVisible, true)

        controller.close()
        XCTAssertEqual(controller.window?.isVisible, false)
    }

    func test_controllerDeallocatesWhenReleased() {
        weak var weakController: AppPickerWindowController?

        autoreleasepool {
            weakController = AppPickerWindowController(sources: [])
        }

        XCTAssertNil(weakController)
    }
}
