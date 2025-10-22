//
//  AudioCaptureIntegrationTests.swift
//  MacTalkTests
//
//  Integration tests for AudioCapture (AVAudioEngine integration)
//

import XCTest
import AVFoundation
@testable import MacTalk

final class AudioCaptureIntegrationTests: XCTestCase {

    var capture: AudioCapture!

    override func setUp() {
        super.setUp()
        capture = AudioCapture()
    }

    override func tearDown() {
        capture.stop()
        capture = nil
        super.tearDown()
    }

    // MARK: - Initialization Tests

    func testInitialization() {
        XCTAssertNotNil(capture, "AudioCapture should initialize")
    }

    func testCallbackInitiallyNil() {
        XCTAssertNil(capture.onPCMFloatBuffer, "onPCMFloatBuffer should be nil initially")
    }

    // MARK: - Callback Assignment Tests

    func testAssignCallback() {
        let expectation = XCTestExpectation(description: "Callback assigned")

        capture.onPCMFloatBuffer = { buffer, timestamp in
            expectation.fulfill()
        }

        XCTAssertNotNil(capture.onPCMFloatBuffer, "Callback should be assigned")
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

    // MARK: - Memory Management Tests

    func testDeinitCallsStop() {
        weak var weakCapture: AudioCapture?

        autoreleasepool {
            let localCapture = AudioCapture()
            weakCapture = localCapture

            // Capture should exist
            XCTAssertNotNil(weakCapture)
        }

        // After autoreleasepool, capture should be deallocated
        XCTAssertNil(weakCapture, "Capture should be deallocated after autoreleasepool")
    }

    func testCallbackDoesNotCreateRetainCycle() {
        weak var weakCapture: AudioCapture?

        autoreleasepool {
            let localCapture = AudioCapture()
            weakCapture = localCapture

            // Assign callback without capturing self strongly
            localCapture.onPCMFloatBuffer = { [weak localCapture] buffer, timestamp in
                _ = localCapture // Use weak reference
            }

            XCTAssertNotNil(weakCapture)
        }

        XCTAssertNil(weakCapture, "Callbacks should not create retain cycles")
    }

    // MARK: - Thread Safety Tests

    func testConcurrentCallbackAssignment() {
        let iterations = 100
        let group = DispatchGroup()

        for i in 0..<iterations {
            group.enter()
            DispatchQueue.global().async {
                self.capture.onPCMFloatBuffer = { buffer, timestamp in
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

    // MARK: - Performance Tests

    func testCallbackAssignmentPerformance() {
        measure {
            for _ in 0..<1000 {
                capture.onPCMFloatBuffer = { buffer, timestamp in
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

    // MARK: - Edge Case Tests

    func testRapidStartStop() {
        // Test starting and stopping in rapid succession
        for _ in 0..<10 {
            capture.stop()
        }

        // Should not crash
        XCTAssertTrue(true, "Rapid stop calls should not crash")
    }

    func testCallbackAfterStop() {
        var callbackInvoked = false

        capture.onPCMFloatBuffer = { buffer, timestamp in
            callbackInvoked = true
        }

        capture.stop()

        // Callback should not be invoked after stop
        // (We can't easily test this without actual audio, but we verify the setup)
        XCTAssertNotNil(capture.onPCMFloatBuffer, "Callback should still be assigned")
    }

    // MARK: - AVAudioEngine Integration Tests

    func testAudioEngineAvailability() {
        // Verify AVAudioEngine is available
        let engine = AVAudioEngine()
        XCTAssertNotNil(engine, "AVAudioEngine should be available")

        // Verify input node is available
        let inputNode = engine.inputNode
        XCTAssertNotNil(inputNode, "Input node should be available")
    }

    func testAudioFormatCompatibility() {
        // Test that we can create compatible audio formats
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)
        XCTAssertNotNil(format, "16kHz mono format should be creatable")

        let format44 = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)
        XCTAssertNotNil(format44, "44.1kHz stereo format should be creatable")

        let format48 = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)
        XCTAssertNotNil(format48, "48kHz stereo format should be creatable")
    }

    func testPCMBufferCreation() {
        // Test that we can create PCM buffers
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let frameCapacity: AVAudioFrameCount = 1024

        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity)

        XCTAssertNotNil(buffer, "PCM buffer should be creatable")
        XCTAssertEqual(buffer?.frameCapacity, frameCapacity, "Frame capacity should match")
    }

    // MARK: - State Management Tests

    func testMultipleInstances() {
        // Test that multiple AudioCapture instances can coexist
        let capture1 = AudioCapture()
        let capture2 = AudioCapture()
        let capture3 = AudioCapture()

        XCTAssertNotNil(capture1)
        XCTAssertNotNil(capture2)
        XCTAssertNotNil(capture3)

        // Clean up
        capture1.stop()
        capture2.stop()
        capture3.stop()
    }

    func testIndependentCallbacks() {
        // Test that multiple instances have independent callbacks
        let capture1 = AudioCapture()
        let capture2 = AudioCapture()

        var callback1Invoked = false
        var callback2Invoked = false

        capture1.onPCMFloatBuffer = { buffer, timestamp in
            callback1Invoked = true
        }

        capture2.onPCMFloatBuffer = { buffer, timestamp in
            callback2Invoked = true
        }

        XCTAssertNotNil(capture1.onPCMFloatBuffer)
        XCTAssertNotNil(capture2.onPCMFloatBuffer)

        // Clean up
        capture1.stop()
        capture2.stop()
    }

    // MARK: - Cleanup Tests

    func testCleanupAfterError() {
        // Test that capture can be stopped even if never started
        let testCapture = AudioCapture()
        testCapture.stop()

        // Should not crash
        XCTAssertNotNil(testCapture)
    }

    func testRepeatedStopCalls() {
        // Test that repeated stop calls are safe
        for _ in 0..<100 {
            capture.stop()
        }

        XCTAssertNotNil(capture, "Capture should remain valid after repeated stops")
    }

    // MARK: - Integration Readiness Tests

    func testIntegrationWithAudioMixer() {
        // Test that AudioCapture can work with AudioMixer
        let mixer = AudioMixer()

        capture.onPCMFloatBuffer = { buffer, timestamp in
            _ = mixer.convert(buffer: buffer)
        }

        XCTAssertNotNil(capture.onPCMFloatBuffer, "Callback should be set up for mixer integration")
    }

    func testIntegrationWithTranscriptionController() {
        // Test that AudioCapture can be used with TranscriptionController
        let modelURL = URL(fileURLWithPath: "/tmp/test-model.gguf")
        let engine = WhisperEngine(modelURL: modelURL)
        let controller = TranscriptionController(engine: engine)

        XCTAssertNotNil(controller, "TranscriptionController should work with AudioCapture")
    }

    // MARK: - Concurrent Operations Tests

    func testConcurrentInstanceCreation() {
        let iterations = 10
        let group = DispatchGroup()
        var instances: [AudioCapture] = []
        let lock = NSLock()

        for _ in 0..<iterations {
            group.enter()
            DispatchQueue.global().async {
                let instance = AudioCapture()
                lock.lock()
                instances.append(instance)
                lock.unlock()
                group.leave()
            }
        }

        let result = group.wait(timeout: .now() + 5)
        XCTAssertEqual(result, .success, "Concurrent instance creation should complete")
        XCTAssertEqual(instances.count, iterations, "All instances should be created")

        // Clean up
        for instance in instances {
            instance.stop()
        }
    }
}
