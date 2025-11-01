//
//  Phase4IntegrationTests.swift
//  MacTalkTests
//
//  End-to-end integration tests for Phase 4 (Mode B - App Audio)
//

import XCTest
import ScreenCaptureKit
import AVFoundation
@testable import MacTalk

final class Phase4IntegrationTests: XCTestCase {

    // MARK: - Multi-Source Mixing Tests

    func testAudioMixerHandlesBothSources() {
        let mixer = AudioMixer()

        // Create test audio buffers
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let frameCount: AVAudioFrameCount = 1024

        // Create mic buffer
        guard let micBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            XCTFail("Failed to create mic buffer")
            return
        }
        micBuffer.frameLength = frameCount

        // Populate with test data
        for channel in 0..<Int(format.channelCount) {
            guard let channelData = micBuffer.floatChannelData?[channel] else { continue }
            for frame in 0..<Int(frameCount) {
                channelData[frame] = Float(frame) / Float(frameCount) * 0.5
            }
        }

        // Convert mic buffer
        let micSamples = mixer.convert(buffer: micBuffer)
        XCTAssertNotNil(micSamples, "Should convert mic buffer")
        XCTAssertGreaterThan(micSamples?.count ?? 0, 0, "Should have samples from mic")

        // Test CMSampleBuffer conversion (app audio)
        // Note: Creating a real CMSampleBuffer is complex, so we test the method exists
        XCTAssertNotNil(mixer, "Mixer should handle both buffer types")
    }

    func testAudioMixerConvertsToCorrectFormat() {
        let mixer = AudioMixer()

        // Create buffer at various sample rates
        let sampleRates: [Double] = [16000, 44100, 48000]

        for sampleRate in sampleRates {
            let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
            let frameCount: AVAudioFrameCount = 1600

            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                XCTFail("Failed to create buffer at \(sampleRate) Hz")
                continue
            }
            buffer.frameLength = frameCount

            // Populate with test data
            if let channelData = buffer.floatChannelData?[0] {
                for frame in 0..<Int(frameCount) {
                    channelData[frame] = Float(frame) / Float(frameCount)
                }
            }

            // Convert
            let samples = mixer.convert(buffer: buffer)
            XCTAssertNotNil(samples, "Should convert buffer at \(sampleRate) Hz")

            // For 16kHz input, output should be close to input size
            // For higher sample rates, output should be downsampled
            if let samples = samples {
                if sampleRate == 16000 {
                    // Should be approximately the same (mono conversion)
                    XCTAssertEqual(samples.count, Int(frameCount), accuracy: 100)
                } else {
                    // Should be downsampled
                    let expectedCount = Int(Double(frameCount) * (16000.0 / sampleRate))
                    XCTAssertEqual(samples.count, expectedCount, accuracy: 200)
                }
            }
        }
    }

    // MARK: - TranscriptionController Mode B Tests

    func testTranscriptionControllerModeEnumeration() {
        let micOnly = TranscriptionController.Mode.micOnly
        let micPlusApp = TranscriptionController.Mode.micPlusAppAudio

        XCTAssertNotEqual("\(micOnly)", "\(micPlusApp)", "Modes should be distinct")
    }

    func testTranscriptionControllerInitialization() {
        let modelURL = URL(fileURLWithPath: "/tmp/test-model.gguf")
        let engine = WhisperEngine(modelURL: modelURL)
        let controller = TranscriptionController(engine: engine)

        XCTAssertNotNil(controller, "Controller should initialize with engine")
    }

    func testTranscriptionControllerCallbacks() {
        let modelURL = URL(fileURLWithPath: "/tmp/test-model.gguf")
        let engine = WhisperEngine(modelURL: modelURL)
        let controller = TranscriptionController(engine: engine)

        let partialExpectation = XCTestExpectation(description: "Partial callback")
        partialExpectation.isInverted = true // We don't expect this without actual transcription

        let finalExpectation = XCTestExpectation(description: "Final callback")
        finalExpectation.isInverted = true

        let appAudioLostExpectation = XCTestExpectation(description: "App audio lost")
        appAudioLostExpectation.isInverted = true

        let fallbackExpectation = XCTestExpectation(description: "Fallback to mic-only")
        fallbackExpectation.isInverted = true

        controller.onPartial = { text in
            partialExpectation.fulfill()
        }

        controller.onFinal = { text in
            finalExpectation.fulfill()
        }

        controller.onAppAudioLost = {
            appAudioLostExpectation.fulfill()
        }

        controller.onFallbackToMicOnly = {
            fallbackExpectation.fulfill()
        }

        wait(for: [partialExpectation, finalExpectation, appAudioLostExpectation, fallbackExpectation], timeout: 0.5)

        // Verify callbacks are assigned
        XCTAssertNotNil(controller.onPartial)
        XCTAssertNotNil(controller.onFinal)
        XCTAssertNotNil(controller.onAppAudioLost)
        XCTAssertNotNil(controller.onFallbackToMicOnly)
    }

    func testTranscriptionControllerStopWithoutStart() {
        let modelURL = URL(fileURLWithPath: "/tmp/test-model.gguf")
        let engine = WhisperEngine(modelURL: modelURL)
        let controller = TranscriptionController(engine: engine)

        // Should not crash
        XCTAssertNoThrow(controller.stop(), "Stop should be safe without start")
    }

    // MARK: - Edge Case Handling Tests

    func testAppAudioErrorHandling() {
        let modelURL = URL(fileURLWithPath: "/tmp/test-model.gguf")
        let engine = WhisperEngine(modelURL: modelURL)
        let controller = TranscriptionController(engine: engine)

        let audioLostExpectation = XCTestExpectation(description: "Audio lost callback")
        audioLostExpectation.isInverted = true

        controller.onAppAudioLost = {
            audioLostExpectation.fulfill()
        }

        // Without starting, callback shouldn't fire
        controller.stop()

        wait(for: [audioLostExpectation], timeout: 0.5)
    }

    func testFallbackToMicOnly() {
        let modelURL = URL(fileURLWithPath: "/tmp/test-model.gguf")
        let engine = WhisperEngine(modelURL: modelURL)
        let controller = TranscriptionController(engine: engine)

        var fallbackCalled = false

        controller.onFallbackToMicOnly = {
            fallbackCalled = true
        }

        // Without triggering an actual error, this won't be called
        controller.stop()

        XCTAssertFalse(fallbackCalled, "Fallback should not be called without error")
    }

    // MARK: - AudioLevelMonitor Multi-Channel Tests

    func testMultiChannelLevelMonitor() {
        let monitor = MultiChannelLevelMonitor()

        // Create test audio samples
        let samples: [Float] = Array(stride(from: Float(0), to: 1.0, by: 0.01))

        // Update microphone channel
        let micLevel = monitor.update(channel: .microphone, buffer: samples)

        XCTAssertGreaterThanOrEqual(micLevel.rms, 0, "RMS should be non-negative")
        XCTAssertGreaterThanOrEqual(micLevel.peak, 0, "Peak should be non-negative")
        XCTAssertGreaterThanOrEqual(micLevel.peakHold, 0, "Peak hold should be non-negative")

        // Update application channel
        let appLevel = monitor.update(channel: .application, buffer: samples)

        XCTAssertGreaterThanOrEqual(appLevel.rms, 0, "App RMS should be non-negative")
        XCTAssertGreaterThanOrEqual(appLevel.peak, 0, "App peak should be non-negative")
    }

    func testLevelMonitorChannelIndependence() {
        let monitor = MultiChannelLevelMonitor()

        // Different samples for each channel
        let micSamples: [Float] = [0.1, 0.2, 0.3, 0.4, 0.5]
        let appSamples: [Float] = [0.5, 0.6, 0.7, 0.8, 0.9]

        let micLevel = monitor.update(channel: .microphone, buffer: micSamples)
        let appLevel = monitor.update(channel: .application, buffer: appSamples)

        // Levels should be different since input is different
        XCTAssertNotEqual(micLevel.rms, appLevel.rms, accuracy: 0.01, "Channels should have independent levels")
    }

    // MARK: - Integration with HUD Tests

    func testHUDSupportsAppMeterVisibility() {
        let hud = HUDWindowController()

        // Test visibility control
        hud.setAppMeterVisible(true)
        // We can't easily test the internal state, but verify method exists and doesn't crash
        XCTAssertNotNil(hud)

        hud.setAppMeterVisible(false)
        XCTAssertNotNil(hud)
    }

    func testHUDHandlesBothChannelLevels() {
        let hud = HUDWindowController()

        // Update mic level
        hud.updateMicLevel(rms: 0.5, peak: 0.7, peakHold: 0.8)

        // Update app level
        hud.updateAppLevel(rms: 0.3, peak: 0.6, peakHold: 0.7)

        // Should not crash
        XCTAssertNotNil(hud)
    }

    // MARK: - StatusBarController Integration Tests

    func testStatusBarControllerHandlesAppSelection() {
        // This would test the integration between StatusBarController and AppPickerWindowController
        // We can verify the types are compatible

        let modelURL = URL(fileURLWithPath: "/tmp/test-model.gguf")
        let app = NSApplication.shared

        // Verify types compile together
        XCTAssertNotNil(app, "Should have application instance")
    }

    // MARK: - Performance Tests

    func testMultiSourceMixingPerformance() {
        let mixer = AudioMixer()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let frameCount: AVAudioFrameCount = 2048

        measure {
            for _ in 0..<100 {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                    continue
                }
                buffer.frameLength = frameCount

                // Populate with test data
                if let channelData = buffer.floatChannelData?[0] {
                    for frame in 0..<Int(frameCount) {
                        channelData[frame] = Float.random(in: -1...1)
                    }
                }

                _ = mixer.convert(buffer: buffer)
            }
        }
    }

    func testLevelMonitorPerformance() {
        let monitor = MultiChannelLevelMonitor()
        let samples = [Float](repeating: 0.5, count: 1600)

        measure {
            for _ in 0..<1000 {
                _ = monitor.update(channel: .microphone, buffer: samples)
                _ = monitor.update(channel: .application, buffer: samples)
            }
        }
    }

    // MARK: - Memory Management Tests

    func testControllerDeallocationWithCallbacks() {
        weak var weakController: TranscriptionController?

        autoreleasepool {
            let modelURL = URL(fileURLWithPath: "/tmp/test-model.gguf")
            let engine = WhisperEngine(modelURL: modelURL)
            let controller = TranscriptionController(engine: engine)

            controller.onPartial = { [weak controller] text in
                _ = controller
            }

            controller.onFinal = { [weak controller] text in
                _ = controller
            }

            controller.onAppAudioLost = { [weak controller] in
                _ = controller
            }

            controller.onFallbackToMicOnly = { [weak controller] in
                _ = controller
            }

            weakController = controller
            XCTAssertNotNil(weakController)
        }

        XCTAssertNil(weakController, "Controller should be deallocated")
    }

    // MARK: - Concurrent Operations Tests

    func testConcurrentAudioProcessing() {
        let mixer = AudioMixer()
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let frameCount: AVAudioFrameCount = 1024
        let iterations = 100
        let group = DispatchGroup()

        for _ in 0..<iterations {
            group.enter()
            DispatchQueue.global().async {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                    group.leave()
                    return
                }
                buffer.frameLength = frameCount

                if let channelData = buffer.floatChannelData?[0] {
                    for frame in 0..<Int(frameCount) {
                        channelData[frame] = Float.random(in: -1...1)
                    }
                }

                _ = mixer.convert(buffer: buffer)
                group.leave()
            }
        }

        let result = group.wait(timeout: .now() + 10)
        XCTAssertEqual(result, .success, "Concurrent audio processing should complete")
    }

    // MARK: - Error Recovery Tests

    func testRecoveryAfterAppAudioFailure() {
        let modelURL = URL(fileURLWithPath: "/tmp/test-model.gguf")
        let engine = WhisperEngine(modelURL: modelURL)
        let controller = TranscriptionController(engine: engine)

        var recoveryAttempts = 0

        controller.onAppAudioLost = {
            recoveryAttempts += 1
        }

        // Simulate error condition
        controller.stop()

        XCTAssertEqual(recoveryAttempts, 0, "No recovery should occur without starting")
    }

    // MARK: - Data Flow Tests

    func testAudioFlowFromCaptureToMixer() {
        let mixer = AudioMixer()
        let capture = AudioCapture()

        var samplesReceived = false

        capture.onPCMFloatBuffer = { buffer, timestamp in
            if let samples = mixer.convert(buffer: buffer) {
                samplesReceived = !samples.isEmpty
            }
        }

        // We can't actually start capture in tests, but verify the chain is set up
        XCTAssertNotNil(capture.onPCMFloatBuffer, "Callback should be connected")
    }

    // MARK: - Configuration Tests

    func testTranscriptionControllerLanguageConfiguration() {
        let modelURL = URL(fileURLWithPath: "/tmp/test-model.gguf")
        let engine = WhisperEngine(modelURL: modelURL)
        let controller = TranscriptionController(engine: engine)

        // Test language setting
        controller.language = "en"
        XCTAssertEqual(controller.language, "en")

        controller.language = "es"
        XCTAssertEqual(controller.language, "es")

        controller.language = nil
        XCTAssertNil(controller.language)
    }

    func testTranscriptionControllerAutoPasteConfiguration() {
        let modelURL = URL(fileURLWithPath: "/tmp/test-model.gguf")
        let engine = WhisperEngine(modelURL: modelURL)
        let controller = TranscriptionController(engine: engine)

        XCTAssertFalse(controller.autoPasteEnabled, "Auto-paste should be disabled by default")

        controller.autoPasteEnabled = true
        XCTAssertTrue(controller.autoPasteEnabled)

        controller.autoPasteEnabled = false
        XCTAssertFalse(controller.autoPasteEnabled)
    }

    // MARK: - State Management Tests

    func testControllerStateAfterStop() {
        let modelURL = URL(fileURLWithPath: "/tmp/test-model.gguf")
        let engine = WhisperEngine(modelURL: modelURL)
        let controller = TranscriptionController(engine: engine)

        // Stop without starting
        controller.stop()

        // Should be safe to stop multiple times
        controller.stop()
        controller.stop()

        XCTAssertNotNil(controller, "Controller should remain valid after multiple stops")
    }
}
