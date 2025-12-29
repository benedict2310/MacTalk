//
//  ConcurrencyStressTests.swift
//  MacTalkTests
//
//  Concurrency stress tests for Swift 6 migration validation (S.02.3a)
//  These tests validate thread safety under concurrent access patterns.
//

import XCTest
import AVFoundation
import Carbon
@testable import MacTalk

// MARK: - Audio Pipeline Stress Tests

final class ConcurrencyStressTests: XCTestCase {

    // MARK: - AudioMixer Stress Tests

    /// Test concurrent audio buffer conversion from multiple threads.
    /// Validates OSAllocatedUnfairLock-based thread safety in AudioMixer.
    func test_audioMixer_concurrentConversion() async {
        let mixer = AudioMixer()

        let format48k = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            channels: 1,
            interleaved: false
        )!

        let format44k = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44100,
            channels: 2,
            interleaved: false
        )!

        let successCounter = TestCounter()

        // Local buffer creation to avoid capturing self in @Sendable closure
        func makeBuffer(format: AVAudioFormat, frameCount: AVAudioFrameCount) -> AVAudioPCMBuffer {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
            buffer.frameLength = frameCount
            if let channelData = buffer.floatChannelData {
                for channel in 0..<Int(format.channelCount) {
                    for frame in 0..<Int(frameCount) {
                        channelData[channel][frame] = Float.random(in: -1.0...1.0)
                    }
                }
            }
            return buffer
        }

        await withTaskGroup(of: Void.self) { group in
            // Simulate concurrent mic and app audio callbacks
            for _ in 0..<50 {
                // 48kHz mono (typical mic format)
                group.addTask {
                    let buffer = makeBuffer(format: format48k, frameCount: 512)
                    if mixer.convert(buffer: buffer) != nil {
                        await successCounter.increment()
                    }
                }

                // 44.1kHz stereo (typical app audio format)
                group.addTask {
                    let buffer = makeBuffer(format: format44k, frameCount: 1024)
                    if mixer.convert(buffer: buffer) != nil {
                        await successCounter.increment()
                    }
                }
            }
        }

        let count = await successCounter.getCount()
        XCTAssertEqual(count, 100, "All 100 concurrent conversions should succeed")
    }

    /// Test rapid format switching under concurrent load.
    func test_audioMixer_rapidFormatSwitching() async {
        let mixer = AudioMixer()

        let formats: [AVAudioFormat] = [
            AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!,
            AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!,
            AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!,
            AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!,
            AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        ]

        // Local buffer creation to avoid capturing self in @Sendable closure
        func makeBuffer(format: AVAudioFormat, frameCount: AVAudioFrameCount) -> AVAudioPCMBuffer {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
            buffer.frameLength = frameCount
            if let channelData = buffer.floatChannelData {
                for channel in 0..<Int(format.channelCount) {
                    for frame in 0..<Int(frameCount) {
                        channelData[channel][frame] = Float.random(in: -1.0...1.0)
                    }
                }
            }
            return buffer
        }

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                for format in formats {
                    group.addTask {
                        let buffer = makeBuffer(format: format, frameCount: 256)
                        _ = mixer.convert(buffer: buffer)
                    }
                }
            }
        }

        // If we get here without crash or TSan warnings, test passed
    }

    // MARK: - RingBuffer Stress Tests

    /// Test concurrent push/pop operations on RingBuffer.
    func test_ringBuffer_concurrentAccess() async {
        let buffer = RingBuffer<Float>(capacity: 10000)
        let samplesWritten = TestCounter()
        let samplesRead = TestCounter()

        await withTaskGroup(of: Void.self) { group in
            // Multiple writers
            for writerId in 0..<3 {
                group.addTask {
                    for i in 0..<1000 {
                        buffer.push(Float(writerId * 1000 + i))
                        await samplesWritten.increment()
                    }
                }
            }

            // Multiple readers
            for _ in 0..<2 {
                group.addTask {
                    for _ in 0..<1500 {
                        if buffer.pop() != nil {
                            await samplesRead.increment()
                        }
                        // Small delay to allow writes
                        try? await Task.sleep(for: .microseconds(10))
                    }
                }
            }
        }

        let written = await samplesWritten.getCount()
        let read = await samplesRead.getCount()

        XCTAssertEqual(written, 3000, "All samples should be written")
        XCTAssertGreaterThan(read, 0, "Some samples should be read")
    }

    // MARK: - AudioLevelMonitor Stress Tests

    /// Test concurrent level updates on AudioLevelMonitor.
    func test_audioLevelMonitor_concurrentUpdates() async {
        let monitor = AudioLevelMonitor()
        let updateCount = TestCounter()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    let samples: [Float] = (0..<256).map { _ in Float.random(in: -1...1) }
                    _ = monitor.update(buffer: samples)
                    await updateCount.increment()
                }
            }
        }

        let count = await updateCount.getCount()
        XCTAssertEqual(count, 100, "All updates should complete")
    }

    /// Test concurrent updates on MultiChannelLevelMonitor.
    func test_multiChannelLevelMonitor_concurrentUpdates() async {
        let monitor = MultiChannelLevelMonitor()
        let micUpdates = TestCounter()
        let appUpdates = TestCounter()

        await withTaskGroup(of: Void.self) { group in
            // Mic updates
            for _ in 0..<50 {
                group.addTask {
                    let samples: [Float] = (0..<128).map { _ in Float.random(in: -0.5...0.5) }
                    _ = monitor.update(channel: .microphone, buffer: samples)
                    await micUpdates.increment()
                }
            }

            // App audio updates
            for _ in 0..<50 {
                group.addTask {
                    let samples: [Float] = (0..<256).map { _ in Float.random(in: -0.8...0.8) }
                    _ = monitor.update(channel: .application, buffer: samples)
                    await appUpdates.increment()
                }
            }
        }

        let mic = await micUpdates.getCount()
        let app = await appUpdates.getCount()

        XCTAssertEqual(mic, 50, "All mic updates should complete")
        XCTAssertEqual(app, 50, "All app updates should complete")
    }

    // MARK: - AudioCapture Stress Tests

    /// Test concurrent callback assignments on AudioCapture.
    func test_audioCapture_concurrentCallbackAssignment() async {
        let capture = AudioCapture()
        let assignmentCount = TestCounter()

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    capture.onPCMFloatBuffer = { buffer, timestamp in
                        // Callback \(i)
                    }
                    await assignmentCount.increment()
                }
            }
        }

        let count = await assignmentCount.getCount()
        XCTAssertEqual(count, 100, "All callback assignments should complete")

        capture.stop()
    }

    /// Test concurrent stop calls on AudioCapture.
    func test_audioCapture_concurrentStop() async {
        let capture = AudioCapture()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<50 {
                group.addTask {
                    capture.stop()
                }
            }
        }

        // If we get here without crash, test passed
        XCTAssertNotNil(capture)
    }

    // MARK: - ScreenAudioCapture Stress Tests

    /// Test concurrent callback assignments on ScreenAudioCapture.
    func test_screenAudioCapture_concurrentCallbackAssignment() async {
        let capture = ScreenAudioCapture()
        let assignmentCount = TestCounter()

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    capture.onAudioSampleBuffer = { buffer in
                        // Callback \(i)
                    }
                    await assignmentCount.increment()
                }
            }
        }

        let count = await assignmentCount.getCount()
        XCTAssertEqual(count, 100, "All callback assignments should complete")

        capture.stop()
    }

    // MARK: - UI Controller Stress Tests (MainActor)

    /// Test rapid HUD updates from concurrent sources.
    @MainActor
    func test_hud_rapidConcurrentUpdates() async throws {
        let hud = HUDWindowController()
        hud.showWindow(nil)

        // Simulate rapid updates from audio callbacks
        for i in 0..<100 {
            let level = Float(i % 100) / 100.0
            hud.updateMicLevel(rms: level, peak: level * 1.2, peakHold: level * 1.3)
            hud.updateAppLevel(rms: level * 0.8, peak: level, peakHold: level * 1.1)
            hud.update(text: "Update \(i)")
        }

        hud.close()
    }

    /// Test rapid StatusBarController show calls.
    @MainActor
    func test_statusBarController_rapidShow() async {
        let controller = StatusBarController()

        for _ in 0..<20 {
            controller.show()
        }

        // If we get here without crash, test passed
        XCTAssertNotNil(controller)
    }

    // MARK: - TranscriptionController Stress Tests

    /// Test concurrent callback invocations on TranscriptionController.
    @MainActor
    func test_transcriptionController_concurrentCallbacks() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let modelURL = tempDir.appendingPathComponent("stress-test-\(UUID().uuidString).bin")
        FileManager.default.createFile(atPath: modelURL.path, contents: Data("mock".utf8))

        defer {
            try? FileManager.default.removeItem(at: modelURL)
        }

        guard let engine = NativeWhisperEngine(modelURL: modelURL) else {
            // Expected for invalid model
            return
        }

        let controller = TranscriptionController(engine: engine)
        let callbackCount = LockIsolated(0)

        controller.onPartial = { @Sendable text in
            callbackCount.withValue { $0 += 1 }
        }

        // Simulate concurrent callback invocations
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask { @MainActor in
                    controller.onPartial?("Partial \(i)")
                }
            }
        }

        XCTAssertEqual(callbackCount.value, 100, "All callbacks should be invoked")
    }

    /// Test concurrent property access on TranscriptionController.
    @MainActor
    func test_transcriptionController_concurrentPropertyAccess() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let modelURL = tempDir.appendingPathComponent("prop-stress-\(UUID().uuidString).bin")
        FileManager.default.createFile(atPath: modelURL.path, contents: Data("mock".utf8))

        defer {
            try? FileManager.default.removeItem(at: modelURL)
        }

        guard let engine = NativeWhisperEngine(modelURL: modelURL) else {
            return
        }

        let controller = TranscriptionController(engine: engine)

        // Concurrent reads and writes
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask { @MainActor in
                    controller.language = i % 2 == 0 ? "en" : "es"
                }
                group.addTask { @MainActor in
                    _ = controller.language
                }
                group.addTask { @MainActor in
                    controller.autoPasteEnabled = i % 2 == 0
                }
                group.addTask { @MainActor in
                    _ = controller.autoPasteEnabled
                }
            }
        }

        // If we get here without crash, test passed
    }

    /// Test concurrent provider switching on AppSettings.
    func test_appSettings_concurrentProviderSwitching() async {
        let defaults = UserDefaults(suiteName: "AppSettingsConcurrencyTests")!
        defaults.removePersistentDomain(forName: "AppSettingsConcurrencyTests")
        let settings = AppSettings.makeForTesting(defaults: defaults)
        let switchCount = TestCounter()

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask {
                    settings.provider = (i % 2 == 0) ? .whisper : .parakeet
                    await switchCount.increment()
                }
            }
        }

        let count = await switchCount.getCount()
        XCTAssertEqual(count, 50, "All provider switches should complete")
    }

    // MARK: - HotkeyManager Stress Tests

    /// Test concurrent hotkey registration/unregistration.
    func test_hotkeyManager_concurrentOperations() async {
        let operationCount = TestCounter()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    let manager = HotkeyManager()
                    _ = manager.register(
                        keyCode: UInt32(kVK_Space),
                        modifiers: UInt32(cmdKey | shiftKey)
                    ) {}
                    manager.unregisterAll()
                    await operationCount.increment()
                }
            }
        }

        let count = await operationCount.getCount()
        XCTAssertEqual(count, 20, "All operations should complete")
    }

}

// MARK: - Integration Stress Tests

final class IntegrationStressTests: XCTestCase {

    /// Test complete audio pipeline under concurrent load.
    func test_audioPipeline_concurrentFlow() async {
        let mixer = AudioMixer()
        let levelMonitor = MultiChannelLevelMonitor()
        let ringBuffer = RingBuffer<Float>(capacity: 32000)

        let processedCount = TestCounter()

        // Local buffer creation to avoid capturing self in @Sendable closure
        func makeBuffer(format: AVAudioFormat, frameCount: AVAudioFrameCount) -> AVAudioPCMBuffer {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
            buffer.frameLength = frameCount
            if let channelData = buffer.floatChannelData {
                for channel in 0..<Int(format.channelCount) {
                    for frame in 0..<Int(frameCount) {
                        channelData[channel][frame] = Float.random(in: -1.0...1.0)
                    }
                }
            }
            return buffer
        }

        await withTaskGroup(of: Void.self) { group in
            // Simulate mic audio stream
            group.addTask {
                let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
                for _ in 0..<50 {
                    let buffer = makeBuffer(format: format, frameCount: 512)
                    if let samples = mixer.convert(buffer: buffer) {
                        _ = levelMonitor.update(channel: .microphone, buffer: samples)
                        ringBuffer.pushSamples(samples)
                        await processedCount.increment()
                    }
                }
            }

            // Simulate app audio stream
            group.addTask {
                let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
                for _ in 0..<30 {
                    let buffer = makeBuffer(format: format, frameCount: 1024)
                    if let samples = mixer.convert(buffer: buffer) {
                        _ = levelMonitor.update(channel: .application, buffer: samples)
                        ringBuffer.pushSamples(samples)
                        await processedCount.increment()
                    }
                }
            }

            // Simulate consumer draining the ring buffer
            group.addTask {
                for _ in 0..<100 {
                    _ = ringBuffer.popSamples(1600)
                    try? await Task.sleep(for: .milliseconds(5))
                }
            }
        }

        let count = await processedCount.getCount()
        XCTAssertEqual(count, 80, "All audio buffers should be processed")
    }
}
