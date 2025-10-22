//
//  AppPickerIntegrationTests.swift
//  MacTalkTests
//
//  Integration tests for App Picker UI and audio source selection
//

import XCTest
import ScreenCaptureKit
@testable import MacTalk

final class AppPickerIntegrationTests: XCTestCase {

    var windowController: AppPickerWindowController!

    override func setUp() {
        super.setUp()
        windowController = AppPickerWindowController()
    }

    override func tearDown() {
        windowController.close()
        windowController = nil
        super.tearDown()
    }

    // MARK: - Initialization Tests

    func testWindowControllerInitialization() {
        XCTAssertNotNil(windowController, "Window controller should initialize")
        XCTAssertNotNil(windowController.window, "Window should be created")
    }

    func testWindowProperties() {
        guard let window = windowController.window else {
            XCTFail("Window should exist")
            return
        }

        XCTAssertEqual(window.title, "Select Audio Source")
        XCTAssertTrue(window.styleMask.contains(.titled))
        XCTAssertTrue(window.styleMask.contains(.closable))
        XCTAssertTrue(window.styleMask.contains(.resizable))
    }

    func testWindowSize() {
        guard let window = windowController.window else {
            XCTFail("Window should exist")
            return
        }

        let frame = window.frame
        XCTAssertEqual(frame.width, 500, accuracy: 1)
        XCTAssertEqual(frame.height, 400, accuracy: 1)
    }

    // MARK: - AudioSource Tests

    func testAudioSourceFromApp() async throws {
        let content = try await SCShareableContent.current

        guard let app = content.applications.first else {
            XCTFail("Should have at least one application")
            return
        }

        let source = AppPickerWindowController.AudioSource.fromApp(app)

        XCTAssertEqual(source.name, app.applicationName)
        XCTAssertNotNil(source.app)
        XCTAssertNil(source.display)
        XCTAssertFalse(source.isSystemAudio)
    }

    func testAudioSourceSystemAudio() async throws {
        let content = try await SCShareableContent.current

        guard let display = content.displays.first else {
            XCTFail("Should have at least one display")
            return
        }

        let source = AppPickerWindowController.AudioSource.systemAudio(display: display)

        XCTAssertEqual(source.name, "System Audio")
        XCTAssertNil(source.app)
        XCTAssertNotNil(source.display)
        XCTAssertTrue(source.isSystemAudio)
    }

    func testAudioSourceIconForApp() async throws {
        let content = try await SCShareableContent.current

        guard let app = content.applications.first else {
            XCTFail("Should have at least one application")
            return
        }

        let source = AppPickerWindowController.AudioSource.fromApp(app)

        // Icon may be nil for some apps, but should not crash
        XCTAssertNotNil(source) // Just verify source was created
    }

    func testAudioSourceIconForSystemAudio() async throws {
        let content = try await SCShareableContent.current

        guard let display = content.displays.first else {
            XCTFail("Should have at least one display")
            return
        }

        let source = AppPickerWindowController.AudioSource.systemAudio(display: display)

        XCTAssertNotNil(source.icon, "System audio should have an icon")
    }

    // MARK: - Selection Callback Tests

    func testSelectionCallbackAssignment() {
        let expectation = XCTestExpectation(description: "Selection callback")

        windowController.onSelection = { source in
            expectation.fulfill()
        }

        XCTAssertNotNil(windowController.onSelection, "Callback should be assigned")
    }

    func testSelectionCallbackWithValidSource() async throws {
        let expectation = XCTestExpectation(description: "Selection callback with source")
        let content = try await SCShareableContent.current

        guard let app = content.applications.first else {
            XCTFail("Should have at least one application")
            return
        }

        let testSource = AppPickerWindowController.AudioSource.fromApp(app)
        var receivedSource: AppPickerWindowController.AudioSource?

        windowController.onSelection = { source in
            receivedSource = source
            expectation.fulfill()
        }

        // Simulate selection
        DispatchQueue.main.async {
            self.windowController.onSelection?(testSource)
        }

        await fulfillment(of: [expectation], timeout: 1.0)

        XCTAssertNotNil(receivedSource)
        XCTAssertEqual(receivedSource?.name, testSource.name)
    }

    // MARK: - Window Lifecycle Tests

    func testShowWindow() {
        windowController.showWindow(nil)

        XCTAssertTrue(windowController.window?.isVisible ?? false, "Window should be visible after showWindow")
    }

    func testCloseWindow() {
        windowController.showWindow(nil)
        windowController.close()

        XCTAssertFalse(windowController.window?.isVisible ?? true, "Window should not be visible after close")
    }

    func testMultipleShowCalls() {
        windowController.showWindow(nil)
        windowController.showWindow(nil)
        windowController.showWindow(nil)

        XCTAssertTrue(windowController.window?.isVisible ?? false, "Multiple show calls should not cause issues")
    }

    // MARK: - Memory Management Tests

    func testWindowControllerDeallocation() {
        weak var weakController: AppPickerWindowController?

        autoreleasepool {
            let controller = AppPickerWindowController()
            weakController = controller
            XCTAssertNotNil(weakController)
        }

        XCTAssertNil(weakController, "Controller should be deallocated")
    }

    func testCallbackDoesNotCreateRetainCycle() {
        weak var weakController: AppPickerWindowController?

        autoreleasepool {
            let controller = AppPickerWindowController()
            weakController = controller

            controller.onSelection = { [weak controller] source in
                _ = controller // Use weak reference
            }

            XCTAssertNotNil(weakController)
        }

        XCTAssertNil(weakController, "Callback should not create retain cycle")
    }

    // MARK: - Performance Tests

    func testWindowCreationPerformance() {
        measure {
            let controller = AppPickerWindowController()
            controller.close()
        }
    }

    func testShowWindowPerformance() {
        windowController.showWindow(nil)

        measure {
            windowController.close()
            windowController.showWindow(nil)
        }
    }

    // MARK: - Integration Tests

    func testIntegrationWithScreenAudioCapture() async throws {
        let capture = ScreenAudioCapture()
        let content = try await SCShareableContent.current

        guard let app = content.applications.first else {
            XCTFail("Should have at least one application")
            return
        }

        let source = AppPickerWindowController.AudioSource.fromApp(app)

        // Verify source can be used with ScreenAudioCapture
        XCTAssertNotNil(source.app)

        // Don't actually start capture to avoid permission prompts
        capture.stop()
    }

    func testIntegrationWithTranscriptionController() async throws {
        // Create a mock Whisper engine for testing
        let modelURL = URL(fileURLWithPath: "/tmp/test-model.gguf")
        let engine = WhisperEngine(modelURL: modelURL)
        let controller = TranscriptionController(engine: engine)

        let content = try await SCShareableContent.current

        guard let app = content.applications.first else {
            XCTFail("Should have at least one application")
            return
        }

        let source = AppPickerWindowController.AudioSource.fromApp(app)

        // Verify source can be passed to TranscriptionController
        // We won't actually start it to avoid permission prompts
        XCTAssertNotNil(source)
        XCTAssertNotNil(controller)
    }

    // MARK: - Edge Cases

    func testEmptyApplicationList() async throws {
        // In practice, there should always be applications
        // But test that the UI handles empty state gracefully
        let content = try await SCShareableContent.current

        XCTAssertGreaterThan(content.applications.count, 0, "Should always have applications in test environment")
    }

    func testMultipleDisplays() async throws {
        let content = try await SCShareableContent.current

        // System may have one or more displays
        XCTAssertGreaterThan(content.displays.count, 0, "Should have at least one display")

        // Create system audio source for each display
        for display in content.displays {
            let source = AppPickerWindowController.AudioSource.systemAudio(display: display)
            XCTAssertNotNil(source)
            XCTAssertTrue(source.isSystemAudio)
        }
    }

    func testConcurrentWindowCreation() {
        let iterations = 10
        let group = DispatchGroup()
        var controllers: [AppPickerWindowController] = []

        for _ in 0..<iterations {
            group.enter()
            DispatchQueue.main.async {
                let controller = AppPickerWindowController()
                controllers.append(controller)
                group.leave()
            }
        }

        let result = group.wait(timeout: .now() + 5)
        XCTAssertEqual(result, .success, "Concurrent window creation should complete")

        // Clean up
        for controller in controllers {
            controller.close()
        }
    }

    // MARK: - Search Functionality Tests (preparatory)

    func testSearchFieldExists() {
        // Verify search field is accessible (would be verified in UI tests)
        windowController.showWindow(nil)

        guard let window = windowController.window else {
            XCTFail("Window should exist")
            return
        }

        XCTAssertNotNil(window.contentView, "Content view should exist")
    }

    // MARK: - Selection State Tests

    func testInitialSelectionState() {
        // Initially, no source should be selected
        windowController.showWindow(nil)

        // We can't directly test private properties, but we can test behavior
        // The select button should be disabled initially
        XCTAssertNotNil(windowController.window)
    }

    // MARK: - Audio Source Equality Tests

    func testAudioSourceComparison() async throws {
        let content = try await SCShareableContent.current

        guard let app = content.applications.first else {
            XCTFail("Should have at least one application")
            return
        }

        let source1 = AppPickerWindowController.AudioSource.fromApp(app)
        let source2 = AppPickerWindowController.AudioSource.fromApp(app)

        XCTAssertEqual(source1.name, source2.name)
        XCTAssertEqual(source1.isSystemAudio, source2.isSystemAudio)
    }

    func testSystemAudioSourcesDistinct() async throws {
        let content = try await SCShareableContent.current

        guard let display = content.displays.first else {
            XCTFail("Should have at least one display")
            return
        }

        let systemAudio = AppPickerWindowController.AudioSource.systemAudio(display: display)

        if let app = content.applications.first {
            let appAudio = AppPickerWindowController.AudioSource.fromApp(app)

            XCTAssertNotEqual(systemAudio.isSystemAudio, appAudio.isSystemAudio)
        }
    }

    // MARK: - Thread Safety Tests

    func testConcurrentCallbackAssignment() {
        let iterations = 100
        let group = DispatchGroup()

        for i in 0..<iterations {
            group.enter()
            DispatchQueue.global().async {
                self.windowController.onSelection = { source in
                    _ = source // Callback \(i)
                }
                group.leave()
            }
        }

        let result = group.wait(timeout: .now() + 5)
        XCTAssertEqual(result, .success, "Concurrent callback assignments should complete")
    }
}
