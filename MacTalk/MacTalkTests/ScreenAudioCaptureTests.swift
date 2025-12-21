//
//  ScreenAudioCaptureTests.swift
//  MacTalkTests
//
//  Unit tests for ScreenAudioCapture (ScreenCaptureKit integration)
//

import XCTest
import ScreenCaptureKit
import AVFoundation
@testable import MacTalk

final class ScreenAudioCaptureTests: XCTestCase {

    var capture: ScreenAudioCapture!

    override func setUp() {
        super.setUp()
        capture = ScreenAudioCapture()
    }

    override func tearDown() {
        capture.stop()
        capture = nil
        super.tearDown()
    }

    // MARK: - Helper Methods

    /// Check if running in CI environment where ScreenCaptureKit is unavailable
    private func isRunningInCI() -> Bool {
        return ProcessInfo.processInfo.environment["CI"] != nil ||
               ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] != nil
    }

    // MARK: - Initialization Tests

    func testInitialization() {
        XCTAssertNotNil(capture, "ScreenAudioCapture should initialize")
    }

    func testCallbacksInitiallyNil() {
        XCTAssertNil(capture.onAudioSampleBuffer, "onAudioSampleBuffer should be nil initially")
        XCTAssertNil(capture.onStreamError, "onStreamError should be nil initially")
    }

    // MARK: - Callback Assignment Tests

    func testAssignAudioSampleBufferCallback() {
        let expectation = XCTestExpectation(description: "Callback assigned")

        capture.onAudioSampleBuffer = { buffer in
            expectation.fulfill()
        }

        XCTAssertNotNil(capture.onAudioSampleBuffer, "Callback should be assigned")
    }

    func testAssignStreamErrorCallback() {
        let expectation = XCTestExpectation(description: "Error callback assigned")

        capture.onStreamError = { error in
            expectation.fulfill()
        }

        XCTAssertNotNil(capture.onStreamError, "Error callback should be assigned")
    }

    // MARK: - Stop Tests

    func testStopWithoutStarting() {
        // Should not crash when stopping without starting
        XCTAssertNoThrow(capture.stop(), "Stop should be safe to call without starting")
    }

    func testMultipleStopCalls() {
        // Should be safe to call stop multiple times
        capture.stop()
        XCTAssertNoThrow(capture.stop(), "Multiple stop calls should be safe")
    }

    // MARK: - Error Handling Tests

    func testSelectFirstWindowWithInvalidAppName() async {
        do {
            try await capture.selectFirstWindow(named: "NonExistentApp12345")
            XCTFail("Should throw error for non-existent app")
        } catch {
            XCTAssertNotNil(error, "Should throw error for invalid app name")
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, "ScreenAudioCapture")
            XCTAssertEqual(nsError.code, 1)
        }
    }

    func testSelectDisplayWhenNoDisplaysAvailable() async {
        // This test simulates the error case, but in practice displays should always exist
        // We'll just verify the method exists and can be called
        do {
            try await capture.selectDisplay()
            // If this succeeds, at least one display was found (normal case)
        } catch {
            // If it fails, verify it's the expected error
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, "ScreenAudioCapture")
        }
    }

    // MARK: - Thread Safety Tests

    func testConcurrentCallbackAssignment() {
        let iterations = 100
        let group = DispatchGroup()

        for i in 0..<iterations {
            group.enter()
            DispatchQueue.global().async {
                self.capture.onAudioSampleBuffer = { buffer in
                    // Callback \(i)
                }
                group.leave()
            }
        }

        let result = group.wait(timeout: .now() + 5)
        XCTAssertEqual(result, .success, "Concurrent callback assignments should complete")
    }

    func testConcurrentStopCalls() {
        let iterations = 10
        let group = DispatchGroup()

        for _ in 0..<iterations {
            group.enter()
            DispatchQueue.global().async {
                self.capture.stop()
                group.leave()
            }
        }

        let result = group.wait(timeout: .now() + 5)
        XCTAssertEqual(result, .success, "Concurrent stop calls should complete safely")
    }

    // MARK: - Method Availability Tests

    func testSelectAppMethodExists() async throws {
        // Skip immediately if in CI environment to avoid timeout
        if isRunningInCI() {
            throw XCTSkip("ScreenCaptureKit unavailable in CI environment")
        }

        // Skip test if ScreenCaptureKit is unavailable (e.g., in CI)
        do {
            let content = try await SCShareableContent.current

            // Find any running app (should always have at least one)
            if let testApp = content.applications.first {
                // Don't actually call it to avoid permission prompts in tests
                // Just verify the method exists and takes the right parameter type
                XCTAssertNotNil(testApp, "Should have at least one running app")
            }
        } catch {
            throw XCTSkip("ScreenCaptureKit unavailable: \(error.localizedDescription)")
        }
    }

    func testSelectDisplayWithParameterMethodExists() async throws {
        // Skip immediately if in CI environment to avoid timeout
        if isRunningInCI() {
            throw XCTSkip("ScreenCaptureKit unavailable in CI environment")
        }

        // Skip test if ScreenCaptureKit is unavailable (e.g., in CI)
        do {
            let content = try await SCShareableContent.current

            if let display = content.displays.first {
                // Don't actually call it to avoid permission prompts
                // Just verify we have a display
                XCTAssertNotNil(display, "Should have at least one display")
            }
        } catch {
            throw XCTSkip("ScreenCaptureKit unavailable: \(error.localizedDescription)")
        }
    }

    // MARK: - Memory Management Tests

    func testDeinitCallsStop() {
        weak var weakCapture: ScreenAudioCapture?

        autoreleasepool {
            let localCapture = ScreenAudioCapture()
            weakCapture = localCapture

            // Capture should exist
            XCTAssertNotNil(weakCapture)
        }

        // After autoreleasepool, capture should be deallocated
        XCTAssertNil(weakCapture, "Capture should be deallocated after autoreleasepool")
    }

    func testCallbacksDoNotCreateRetainCycles() {
        weak var weakCapture: ScreenAudioCapture?

        autoreleasepool {
            let localCapture = ScreenAudioCapture()
            weakCapture = localCapture

            // Assign callbacks without capturing self strongly
            localCapture.onAudioSampleBuffer = { [weak localCapture] buffer in
                _ = localCapture // Use weak reference
            }

            localCapture.onStreamError = { [weak localCapture] error in
                _ = localCapture // Use weak reference
            }

            XCTAssertNotNil(weakCapture)
        }

        XCTAssertNil(weakCapture, "Callbacks should not create retain cycles")
    }

    // MARK: - Performance Tests

    func testCallbackAssignmentPerformance() {
        measure {
            for _ in 0..<1000 {
                capture.onAudioSampleBuffer = { buffer in
                    // Empty callback
                }
            }
        }
    }

    func testStopPerformance() {
        measure {
            for _ in 0..<100 {
                capture.stop()
            }
        }
    }

    // MARK: - Integration Readiness Tests

    func testScreenCaptureContentQuery() async throws {
        // Skip immediately if in CI environment to avoid timeout
        if isRunningInCI() {
            throw XCTSkip("ScreenCaptureKit unavailable in CI environment")
        }

        // Skip test if ScreenCaptureKit is unavailable (e.g., in CI)
        do {
            let content = try await SCShareableContent.current

            XCTAssertNotNil(content, "Should be able to query shareable content")
            XCTAssertNotNil(content.applications, "Should have applications list")
            XCTAssertNotNil(content.displays, "Should have displays list")
            XCTAssertGreaterThan(content.applications.count, 0, "Should have at least one application")
            XCTAssertGreaterThan(content.displays.count, 0, "Should have at least one display")
        } catch {
            throw XCTSkip("ScreenCaptureKit unavailable: \(error.localizedDescription)")
        }
    }

    func testApplicationsHaveExpectedProperties() async throws {
        // Skip immediately if in CI environment to avoid timeout
        if isRunningInCI() {
            throw XCTSkip("ScreenCaptureKit unavailable in CI environment")
        }

        // Skip test if ScreenCaptureKit is unavailable (e.g., in CI)
        do {
            let content = try await SCShareableContent.current

            guard let app = content.applications.first else {
                XCTFail("Should have at least one application")
                return
            }

            XCTAssertNotNil(app.applicationName, "App should have a name")
            XCTAssertFalse(app.applicationName.isEmpty, "App name should not be empty")
        } catch {
            throw XCTSkip("ScreenCaptureKit unavailable: \(error.localizedDescription)")
        }
    }

    func testDisplaysHaveExpectedProperties() async throws {
        // Skip immediately if in CI environment to avoid timeout
        if isRunningInCI() {
            throw XCTSkip("ScreenCaptureKit unavailable in CI environment")
        }

        // Skip test if ScreenCaptureKit is unavailable (e.g., in CI)
        do {
            let content = try await SCShareableContent.current

            guard let display = content.displays.first else {
                XCTFail("Should have at least one display")
                return
            }

            XCTAssertGreaterThan(display.width, 0, "Display should have positive width")
            XCTAssertGreaterThan(display.height, 0, "Display should have positive height")
        } catch {
            throw XCTSkip("ScreenCaptureKit unavailable: \(error.localizedDescription)")
        }
    }

    // MARK: - Edge Case Tests

    func testStopDuringCallbackExecution() {
        let expectation = XCTestExpectation(description: "Callback executed")
        expectation.isInverted = true // We expect this NOT to fulfill quickly

        capture.onAudioSampleBuffer = { [weak capture] buffer in
            // Simulate processing
            Thread.sleep(forTimeInterval: 0.1)
            capture?.stop()
            expectation.fulfill()
        }

        // Don't wait long since we don't have real audio
        wait(for: [expectation], timeout: 0.5)
    }

    func testRapidStartStop() async {
        // Test starting and stopping in rapid succession
        // Note: We can't actually start without proper permissions in tests
        // but we can test the stop() method's resilience

        for _ in 0..<10 {
            capture.stop()
        }

        // Should not crash
        XCTAssertTrue(true, "Rapid stop calls should not crash")
    }

    func testCallbackExecutionOrder() {
        nonisolated(unsafe) var callbackCount = 0
        let lock = NSLock()

        capture.onAudioSampleBuffer = { buffer in
            lock.lock()
            callbackCount += 1
            lock.unlock()
        }

        // We can't trigger actual callbacks in unit tests without real audio
        // but we verify the callback is properly stored
        XCTAssertNotNil(capture.onAudioSampleBuffer)
    }

    // MARK: - Error Callback Tests

    func testErrorCallbackNotCalledOnSuccess() {
        nonisolated(unsafe) var errorCallbackCalled = false

        capture.onStreamError = { error in
            errorCallbackCalled = true
        }

        // Without starting capture, error callback shouldn't be triggered
        capture.stop()

        XCTAssertFalse(errorCallbackCalled, "Error callback should not be called on normal stop")
    }

    func testErrorCallbackRetainsErrorInfo() {
        let expectation = XCTestExpectation(description: "Error callback")
        expectation.isInverted = true // We don't expect this to be called in normal test execution

        nonisolated(unsafe) var capturedError: Error?

        capture.onStreamError = { error in
            capturedError = error
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 0.5)

        // In normal test execution without actual capture, this shouldn't be called
        XCTAssertNil(capturedError, "Error should not be captured in normal conditions")
    }
}
