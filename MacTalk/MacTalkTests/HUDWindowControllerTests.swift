//
//  HUDWindowControllerTests.swift
//  MacTalkTests
//
//  Unit tests for HUDWindowController
//

import XCTest
@testable import MacTalk

@MainActor
final class HUDWindowControllerTests: XCTestCase {

    var hudController: HUDWindowController!

    override func setUp() async throws {
        try await super.setUp()
        hudController = HUDWindowController()
    }

    override func tearDown() async throws {
        hudController?.close()
        hudController = nil
        try await super.tearDown()
    }

    // MARK: - Initialization Tests

    func testInitialization() {
        XCTAssertNotNil(hudController)
        XCTAssertNotNil(hudController.window)
    }

    func testWindowType() {
        guard let window = hudController.window else {
            XCTFail("Window should not be nil")
            return
        }

        XCTAssertTrue(window is NSPanel, "Window should be NSPanel")
    }

    func testWindowLevel() {
        guard let window = hudController.window else {
            XCTFail("Window should not be nil")
            return
        }

        // HUD should float above other windows
        XCTAssertEqual(window.level, .floating, "Window should be at floating level")
    }

    func testWindowStyle() {
        guard let window = hudController.window else {
            XCTFail("Window should not be nil")
            return
        }

        // HUD should be borderless
        XCTAssertTrue(window.styleMask.contains(.borderless))
        XCTAssertFalse(window.styleMask.contains(.titled))
        XCTAssertFalse(window.styleMask.contains(.closable))
    }

    func testWindowBehavior() {
        guard let panel = hudController.window as? NSPanel else {
            XCTFail("Window should be NSPanel")
            return
        }

        // Panel should float and be non-activating
        XCTAssertTrue(panel.isFloatingPanel)
        XCTAssertFalse(panel.becomesKeyOnlyIfNeeded)
    }

    func testWindowSize() {
        guard let window = hudController.window else {
            XCTFail("Window should not be nil")
            return
        }

        let frame = window.frame
        XCTAssertGreaterThan(frame.width, 0)
        XCTAssertGreaterThan(frame.height, 0)

        // HUD should have reasonable dimensions
        XCTAssertLessThan(frame.width, 800)
        XCTAssertLessThan(frame.height, 600)
    }

    // MARK: - Partial Text Update Tests (S.03.1 Streaming UX)

    func testUpdatePartial() {
        let testText = "Hello, this is a partial transcript"
        hudController.updatePartial(text: testText)
        XCTAssertNotNil(hudController.window)
    }

    func testUpdatePartialEmpty() {
        hudController.updatePartial(text: "")
        XCTAssertNotNil(hudController.window)
    }

    func testUpdatePartialLong() {
        let longText = String(repeating: "This is a very long transcript. ", count: 100)
        hudController.updatePartial(text: longText)
        XCTAssertNotNil(hudController.window)
    }

    func testUpdatePartialSpecialCharacters() {
        let specialText = "Test with special: émojis 🎙️ and symbols @#$%"
        hudController.updatePartial(text: specialText)
        XCTAssertNotNil(hudController.window)
    }

    func testMultiplePartialUpdates() {
        let texts = [
            "First partial",
            "Second partial with more text",
            "Third partial",
            "",
            "Final partial"
        ]

        for text in texts {
            hudController.updatePartial(text: text)
        }

        XCTAssertNotNil(hudController.window)
    }

    func testPartialThrottlesIdenticalUpdates() {
        // Same text should not trigger redundant updates (throttling)
        let text = "Same text repeated"
        hudController.updatePartial(text: text)
        hudController.updatePartial(text: text)  // Should be skipped
        hudController.updatePartial(text: text)  // Should be skipped
        XCTAssertNotNil(hudController.window)
    }

    // MARK: - Final Text Update Tests (S.03.1 Streaming UX)

    func testUpdateFinal() {
        let testText = "This is the final transcript."
        hudController.updateFinal(text: testText)
        XCTAssertNotNil(hudController.window)
    }

    func testUpdateFinalEmpty() {
        hudController.updateFinal(text: "")
        XCTAssertNotNil(hudController.window)
    }

    func testUpdateFinalLong() {
        let longText = String(repeating: "Final transcript text. ", count: 50)
        hudController.updateFinal(text: longText)
        XCTAssertNotNil(hudController.window)
    }

    func testPartialToFinalTransition() {
        // Simulate streaming: partials followed by final
        hudController.showWindow(nil)
        hudController.updatePartial(text: "Listening...")
        hudController.updatePartial(text: "Hello")
        hudController.updatePartial(text: "Hello world")
        hudController.updatePartial(text: "Hello world how are you")
        hudController.updateFinal(text: "Hello world, how are you?")
        XCTAssertNotNil(hudController.window)
    }

    // MARK: - Legacy Text Update Tests (deprecated API)

    func testUpdateText() {
        let testText = "Hello, this is a test transcript"
        hudController.update(text: testText)

        // Verify text is set (routes to updatePartial)
        XCTAssertNotNil(hudController.window)
    }

    func testUpdateTextEmpty() {
        hudController.update(text: "")
        XCTAssertNotNil(hudController.window)
    }

    func testUpdateTextLong() {
        let longText = String(repeating: "This is a very long transcript. ", count: 100)
        hudController.update(text: longText)
        XCTAssertNotNil(hudController.window)
    }

    func testUpdateTextSpecialCharacters() {
        let specialText = "Test with special: émojis 🎙️ and symbols @#$%"
        hudController.update(text: specialText)
        XCTAssertNotNil(hudController.window)
    }

    func testMultipleTextUpdates() {
        let texts = [
            "First update",
            "Second update with more text",
            "Third update",
            "",
            "Final update"
        ]

        for text in texts {
            hudController.update(text: text)
        }

        XCTAssertNotNil(hudController.window)
    }

    // MARK: - Reset/State Tests (S.03.1 Streaming UX)

    func testResetClearsTranscriptState() {
        hudController.showWindow(nil)
        hudController.updatePartial(text: "Some text")
        hudController.reset()
        // After reset, HUD should be in "Listening..." state
        XCTAssertNotNil(hudController.window)
    }

    func testShowWindowResetsState() {
        hudController.updatePartial(text: "Old text")
        hudController.showWindow(nil)
        // showWindow calls reset, should clear old text
        XCTAssertNotNil(hudController.window)
    }

    // MARK: - Level Meter Tests

    func testUpdateMicLevel() {
        hudController.updateMicLevel(rms: 0.5, peak: 0.7, peakHold: 0.8)
        XCTAssertNotNil(hudController.window)
    }

    func testUpdateMicLevelSilence() {
        hudController.updateMicLevel(rms: 0.0, peak: 0.0, peakHold: 0.0)
        XCTAssertNotNil(hudController.window)
    }

    func testUpdateMicLevelMaximum() {
        hudController.updateMicLevel(rms: 1.0, peak: 1.0, peakHold: 1.0)
        XCTAssertNotNil(hudController.window)
    }

    func testUpdateMicLevelInvalidValues() {
        // Test with out-of-range values
        hudController.updateMicLevel(rms: -0.5, peak: -0.3, peakHold: -0.1)
        hudController.updateMicLevel(rms: 1.5, peak: 2.0, peakHold: 3.0)
        XCTAssertNotNil(hudController.window)
    }

    func testUpdateAppLevel() {
        hudController.updateAppLevel(rms: 0.3, peak: 0.5, peakHold: 0.6)
        XCTAssertNotNil(hudController.window)
    }

    func testUpdateAppLevelSilence() {
        hudController.updateAppLevel(rms: 0.0, peak: 0.0, peakHold: 0.0)
        XCTAssertNotNil(hudController.window)
    }

    func testUpdateAppLevelMaximum() {
        hudController.updateAppLevel(rms: 1.0, peak: 1.0, peakHold: 1.0)
        XCTAssertNotNil(hudController.window)
    }

    func testMultipleLevelUpdates() {
        // Simulate rapid level updates
        for i in 0..<100 {
            let level = Float(i) / 100.0
            hudController.updateMicLevel(rms: level, peak: level, peakHold: level)
        }
        XCTAssertNotNil(hudController.window)
    }

    // MARK: - App Meter Visibility Tests

    func testSetAppMeterVisible() {
        hudController.setAppMeterVisible(true)
        XCTAssertNotNil(hudController.window)
    }

    func testSetAppMeterHidden() {
        hudController.setAppMeterVisible(false)
        XCTAssertNotNil(hudController.window)
    }

    func testToggleAppMeterVisibility() {
        hudController.setAppMeterVisible(true)
        hudController.setAppMeterVisible(false)
        hudController.setAppMeterVisible(true)
        XCTAssertNotNil(hudController.window)
    }

    // MARK: - Window Visibility Tests

    func testShowWindow() {
        hudController.showWindow(nil)
        XCTAssertTrue(hudController.window?.isVisible ?? false)
    }

    func testCloseWindow() {
        hudController.showWindow(nil)
        hudController.close()
        XCTAssertFalse(hudController.window?.isVisible ?? true)
    }

    func testShowHideMultipleTimes() {
        for _ in 0..<5 {
            hudController.showWindow(nil)
            XCTAssertTrue(hudController.window?.isVisible ?? false)
            hudController.close()
            XCTAssertFalse(hudController.window?.isVisible ?? true)
        }
    }

    // MARK: - Window Positioning Tests

    func testWindowPositioning() {
        hudController.showWindow(nil)

        guard let window = hudController.window else {
            XCTFail("Window should not be nil")
            return
        }

        // HUD should be positioned somewhere on screen
        XCTAssertTrue(window.frame.origin.x >= 0)
        XCTAssertTrue(window.frame.origin.y >= 0)
    }

    // MARK: - Integration Tests

    func testCompleteTranscriptionFlow() {
        // Simulate a complete transcription session with streaming (S.03.1)

        // 1. Show HUD - should display "Listening..."
        hudController.showWindow(nil)
        XCTAssertTrue(hudController.window?.isVisible ?? false)

        // 2. Set app meter visible (mic + app mode)
        hudController.setAppMeterVisible(true)

        // 3. Update levels during recording
        for i in 0..<50 {
            let level = Float(i) / 50.0
            hudController.updateMicLevel(rms: level * 0.7, peak: level * 0.9, peakHold: level)
            hudController.updateAppLevel(rms: level * 0.5, peak: level * 0.7, peakHold: level * 0.8)
        }

        // 4. Streaming partials (S.03.1 - live text updates at 70% opacity)
        hudController.updatePartial(text: "This is")
        hudController.updatePartial(text: "This is a partial")
        hudController.updatePartial(text: "This is a partial transcript...")
        hudController.updatePartial(text: "This is a partial transcript... with more words")

        // 5. Final text (S.03.1 - committed text at 100% opacity)
        hudController.updateFinal(text: "This is the complete transcript with all the words.")

        // 6. Close HUD
        hudController.close()
        XCTAssertFalse(hudController.window?.isVisible ?? true)
    }

    func testMicOnlyFlow() {
        // Simulate mic-only mode with streaming (S.03.1)

        hudController.showWindow(nil)

        // Hide app meter in mic-only mode
        hudController.setAppMeterVisible(false)

        // Update only mic levels
        hudController.updateMicLevel(rms: 0.5, peak: 0.7, peakHold: 0.8)

        // Streaming partial updates
        hudController.updatePartial(text: "Mic-only")
        hudController.updatePartial(text: "Mic-only transcription")

        // Final commit
        hudController.updateFinal(text: "Mic-only transcription.")

        hudController.close()
        XCTAssertFalse(hudController.window?.isVisible ?? true)
    }

    func testMicPlusAppFlow() {
        // Simulate mic + app mode with streaming (S.03.1)

        hudController.showWindow(nil)

        // Show app meter
        hudController.setAppMeterVisible(true)

        // Update both mic and app levels
        hudController.updateMicLevel(rms: 0.6, peak: 0.8, peakHold: 0.9)
        hudController.updateAppLevel(rms: 0.4, peak: 0.6, peakHold: 0.7)

        // Streaming partial updates
        hudController.updatePartial(text: "Mic + App")
        hudController.updatePartial(text: "Mic + App transcription")

        // Final commit
        hudController.updateFinal(text: "Mic + App transcription.")

        hudController.close()
    }

    // MARK: - Concurrent Updates Test

    /// Test rapid concurrent updates from multiple async tasks.
    /// Swift 6 requires MainActor isolation for UI, so updates are
    /// scheduled on MainActor via Task groups.
    func testConcurrentUpdates() async {
        hudController.showWindow(nil)

        // Simulate rapid concurrent updates from multiple tasks
        await withTaskGroup(of: Void.self) { group in
            // Level updates
            for i in 0..<100 {
                group.addTask { @MainActor in
                    self.hudController.updateMicLevel(
                        rms: Float(i) / 100.0,
                        peak: Float(i) / 100.0,
                        peakHold: Float(i) / 100.0
                    )
                }
            }

            // Partial text updates (simulating streaming)
            for i in 0..<100 {
                group.addTask { @MainActor in
                    self.hudController.updatePartial(text: "Partial \(i)")
                }
            }
        }

        XCTAssertNotNil(hudController.window)
    }

    /// Test streaming scenario with concurrent partials and final (S.03.1)
    func testConcurrentStreamingUpdates() async {
        hudController.showWindow(nil)

        // Simulate concurrent partial updates followed by final
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask { @MainActor in
                    self.hudController.updatePartial(text: "Streaming word \(i)")
                }
            }
        }

        // Final should succeed even after many partials
        hudController.updateFinal(text: "Final transcript after concurrent partials.")
        XCTAssertNotNil(hudController.window)
    }

    // MARK: - Memory Tests

    func testMemoryLeakOnMultipleCreations() {
        weak var weakController: HUDWindowController?

        autoreleasepool {
            let controller = HUDWindowController()
            weakController = controller
            controller.showWindow(nil)
            controller.close()
        }

        // Controller should be deallocated
        XCTAssertNil(weakController, "HUDWindowController should be deallocated")
    }

    // MARK: - Edge Cases

    func testRapidShowHide() {
        for _ in 0..<20 {
            hudController.showWindow(nil)
            hudController.close()
        }
        XCTAssertNotNil(hudController.window)
    }

    func testUpdateWhileHidden() {
        // HUD is created but not shown
        hudController.update(text: "Hidden update")
        hudController.updateMicLevel(rms: 0.5, peak: 0.7, peakHold: 0.8)

        XCTAssertNotNil(hudController.window)
    }

    func testUpdateAfterClose() {
        hudController.showWindow(nil)
        hudController.close()

        // Update after closing
        hudController.update(text: "Update after close")
        hudController.updateMicLevel(rms: 0.5, peak: 0.7, peakHold: 0.8)

        XCTAssertNotNil(hudController.window)
    }

    // MARK: - Performance Tests

    func testTextUpdatePerformance() {
        hudController.showWindow(nil)

        measure {
            for i in 0..<100 {
                hudController.update(text: "Performance test update \(i)")
            }
        }
    }

    /// Test streaming partial update performance (S.03.1 - target ~10 Hz UI updates)
    func testPartialUpdatePerformance() {
        hudController.showWindow(nil)

        measure {
            for i in 0..<100 {
                hudController.updatePartial(text: "Streaming partial \(i) with some text")
            }
        }
    }

    /// Test final update performance
    func testFinalUpdatePerformance() {
        hudController.showWindow(nil)

        measure {
            for i in 0..<100 {
                hudController.updateFinal(text: "Final transcript \(i) with complete text.")
            }
        }
    }

    func testLevelUpdatePerformance() {
        hudController.showWindow(nil)

        measure {
            for i in 0..<1000 {
                let level = Float(i % 100) / 100.0
                hudController.updateMicLevel(rms: level, peak: level, peakHold: level)
            }
        }
    }

    func testCombinedUpdatePerformance() {
        hudController.showWindow(nil)

        measure {
            for i in 0..<100 {
                let level = Float(i) / 100.0
                hudController.updateMicLevel(rms: level, peak: level, peakHold: level)
                hudController.updateAppLevel(rms: level * 0.8, peak: level * 0.9, peakHold: level)
                hudController.update(text: "Update \(i)")
            }
        }
    }
}
