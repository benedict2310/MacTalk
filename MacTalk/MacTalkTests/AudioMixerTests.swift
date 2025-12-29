//
//  AudioMixerTests.swift
//  MacTalkTests
//
//  Unit tests for AudioMixer component
//

import XCTest
import AVFoundation
@testable import MacTalk

final class AudioMixerTests: XCTestCase {

    var mixer: AudioMixer!

    override func setUp() {
        super.setUp()
        mixer = AudioMixer()
    }

    override func tearDown() {
        mixer = nil
        super.tearDown()
    }

    // MARK: - Format Conversion Tests

    func testConvert16kHzMonoToTarget() {
        // Input already in target format (16kHz mono)
        let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!

        let buffer = createTestBuffer(format: inputFormat, frameCount: 1000)

        let samples = mixer.convert(buffer: buffer)

        XCTAssertNotNil(samples)
        XCTAssertEqual(samples?.count, 1000)
    }

    func testConvert48kHzMonoTo16kHz() {
        // Input: 48kHz mono -> Output: 16kHz mono
        let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            channels: 1,
            interleaved: false
        )!

        let buffer = createTestBuffer(format: inputFormat, frameCount: 4800)

        let samples = mixer.convert(buffer: buffer)

        XCTAssertNotNil(samples)
        guard let samples = samples else { return }

        // 48kHz -> 16kHz is 3:1 ratio
        // 4800 samples should become ~1600 samples
        XCTAssertEqual(samples.count, 1600, accuracy: 10)
    }

    func testConvert48kHzStereoTo16kHzMono() {
        // Input: 48kHz stereo -> Output: 16kHz mono
        let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            channels: 2,
            interleaved: false
        )!

        let buffer = createTestBuffer(format: inputFormat, frameCount: 4800)

        let samples = mixer.convert(buffer: buffer)

        XCTAssertNotNil(samples)
        guard let samples = samples else { return }

        // Should downmix to mono and resample
        XCTAssertEqual(samples.count, 1600, accuracy: 10)
    }

    func testConvert44_1kHzTo16kHz() {
        // Common CD quality: 44.1kHz -> 16kHz
        let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44100,
            channels: 2,
            interleaved: false
        )!

        let buffer = createTestBuffer(format: inputFormat, frameCount: 4410)

        let samples = mixer.convert(buffer: buffer)

        XCTAssertNotNil(samples)
        guard let samples = samples else { return }

        // 44.1kHz -> 16kHz is approximately 2.76:1
        // 4410 samples should become ~1600 samples
        XCTAssertEqual(samples.count, 1600, accuracy: 50)
    }

    // MARK: - Multiple Conversion Tests

    func testMultipleConversionsWithSameFormat() {
        let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            channels: 2,
            interleaved: false
        )!

        // First conversion
        let buffer1 = createTestBuffer(format: inputFormat, frameCount: 480)
        let samples1 = mixer.convert(buffer: buffer1)
        XCTAssertNotNil(samples1)

        // Second conversion (should reuse converter)
        let buffer2 = createTestBuffer(format: inputFormat, frameCount: 480)
        let samples2 = mixer.convert(buffer: buffer2)
        XCTAssertNotNil(samples2)

        XCTAssertEqual(samples1?.count, samples2?.count)
    }

    func testConversionsWithDifferentFormats() {
        // First format: 48kHz mono
        let format1 = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            channels: 1,
            interleaved: false
        )!

        let buffer1 = createTestBuffer(format: format1, frameCount: 480)
        let samples1 = mixer.convert(buffer: buffer1)
        XCTAssertNotNil(samples1)

        // Second format: 44.1kHz stereo (different!)
        let format2 = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44100,
            channels: 2,
            interleaved: false
        )!

        let buffer2 = createTestBuffer(format: format2, frameCount: 441)
        let samples2 = mixer.convert(buffer: buffer2)
        XCTAssertNotNil(samples2)

        // Should handle format change
        XCTAssertNotNil(samples2)
    }

    // MARK: - Sample Value Tests

    func testSampleValuesPreserved() {
        let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!

        let buffer = createTestBufferWithValue(
            format: inputFormat,
            frameCount: 100,
            value: 0.5
        )

        let samples = mixer.convert(buffer: buffer)

        XCTAssertNotNil(samples)

        // When no conversion needed, values should be preserved
        for sample in samples! {
            XCTAssertEqual(sample, 0.5, accuracy: 0.01)
        }
    }

    func testSampleRangePreserved() {
        let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            channels: 1,
            interleaved: false
        )!

        var testValues: [Float] = []
        for i in 0..<100 {
            testValues.append(sin(Float(i) * 0.1))
        }

        let buffer = createTestBufferWithValues(
            format: inputFormat,
            values: testValues
        )

        let samples = mixer.convert(buffer: buffer)

        XCTAssertNotNil(samples)

        // Values should stay in -1 to 1 range
        for sample in samples! {
            XCTAssertGreaterThanOrEqual(sample, -1.0)
            XCTAssertLessThanOrEqual(sample, 1.0)
        }
    }

    // MARK: - Edge Cases

    func testEmptyBuffer() {
        let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            channels: 1,
            interleaved: false
        )!

        let buffer = createTestBuffer(format: inputFormat, frameCount: 0)

        let samples = mixer.convert(buffer: buffer)

        // Should handle gracefully
        XCTAssertNotNil(samples)
        XCTAssertEqual(samples?.count, 0)
    }

    func testVerySmallBuffer() {
        let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            channels: 1,
            interleaved: false
        )!

        let buffer = createTestBuffer(format: inputFormat, frameCount: 1)

        let samples = mixer.convert(buffer: buffer)

        XCTAssertNotNil(samples)
    }

    func testVeryLargeBuffer() {
        let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            channels: 2,
            interleaved: false
        )!

        // 10 seconds of audio at 48kHz
        let buffer = createTestBuffer(format: inputFormat, frameCount: 480000)

        let samples = mixer.convert(buffer: buffer)

        XCTAssertNotNil(samples)
        guard let samples = samples else { return }

        // Should be approximately 160,000 samples at 16kHz
        XCTAssertEqual(samples.count, 160000, accuracy: 1000)
    }

    // MARK: - Thread Safety Tests (S.02.2a)

    /// Tests concurrent conversion from multiple threads with different formats.
    /// This validates the OSAllocatedUnfairLock-based thread safety implementation.
    func test_concurrentConversionDifferentFormats() async {
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
            channels: 1,
            interleaved: false
        )!

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
            // 100 concurrent conversions from each format
            for _ in 0..<100 {
                group.addTask {
                    let buffer48k = makeBuffer(format: format48k, frameCount: 1024)
                    _ = mixer.convert(buffer: buffer48k)
                }
                group.addTask {
                    let buffer44k = makeBuffer(format: format44k, frameCount: 1024)
                    _ = mixer.convert(buffer: buffer44k)
                }
            }
        }

        // If we get here without crash or TSan warnings, test passed
    }

    /// Tests concurrent conversion with same format from multiple threads.
    /// Validates that converter cache reuse is thread-safe.
    func test_concurrentConversionSameFormat() async {
        let mixer = AudioMixer()

        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            channels: 2,
            interleaved: false
        )!

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
            // 200 concurrent conversions all using same format
            for _ in 0..<200 {
                group.addTask {
                    let buffer = makeBuffer(format: format, frameCount: 512)
                    let result = mixer.convert(buffer: buffer)
                    // Verify conversion succeeded
                    XCTAssertNotNil(result)
                }
            }
        }
    }

    /// Simulates real-world scenario: mic + app audio callbacks running concurrently.
    func test_concurrentMicAndAppAudioSimulation() async {
        let mixer = AudioMixer()

        // Mic typically runs at 48kHz mono
        let micFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            channels: 1,
            interleaved: false
        )!

        // App audio typically runs at 44.1kHz or 48kHz stereo
        let appFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44100,
            channels: 2,
            interleaved: false
        )!

        // Use actor to collect results safely
        let resultsCollector = ResultsCollector()

        // Local buffer creation function to avoid capturing self in @Sendable closure
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
            // Simulate mic callbacks (high frequency, small buffers)
            group.addTask {
                for _ in 0..<50 {
                    let buffer = makeBuffer(format: micFormat, frameCount: 256)
                    let success = mixer.convert(buffer: buffer) != nil
                    await resultsCollector.addMicResult(success)
                }
            }

            // Simulate app audio callbacks (lower frequency, larger buffers)
            group.addTask {
                for _ in 0..<30 {
                    let buffer = makeBuffer(format: appFormat, frameCount: 1024)
                    let success = mixer.convert(buffer: buffer) != nil
                    await resultsCollector.addAppResult(success)
                }
            }
        }

        // Verify all conversions succeeded
        let (micSuccesses, appSuccesses) = await resultsCollector.getResults()
        XCTAssertEqual(micSuccesses.filter { $0 }.count, 50, "All mic conversions should succeed")
        XCTAssertEqual(appSuccesses.filter { $0 }.count, 30, "All app audio conversions should succeed")
    }

    // MARK: - Performance Tests

    func testPerformanceConversion48kHzTo16kHz() {
        let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            channels: 2,
            interleaved: false
        )!

        let buffer = createTestBuffer(format: inputFormat, frameCount: 2048)

        measure {
            for _ in 0..<100 {
                _ = mixer.convert(buffer: buffer)
            }
        }
    }

    func testPerformanceMultipleSmallConversions() {
        let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            channels: 2,
            interleaved: false
        )!

        measure {
            for _ in 0..<1000 {
                let buffer = createTestBuffer(format: inputFormat, frameCount: 256)
                _ = mixer.convert(buffer: buffer)
            }
        }
    }

    // MARK: - Helper Methods

    private func createTestBuffer(format: AVAudioFormat, frameCount: AVAudioFrameCount) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount

        // Fill with random test data
        if let channelData = buffer.floatChannelData {
            for channel in 0..<Int(format.channelCount) {
                for frame in 0..<Int(frameCount) {
                    channelData[channel][frame] = Float.random(in: -1.0...1.0)
                }
            }
        }

        return buffer
    }

    private func createTestBufferWithValue(format: AVAudioFormat, frameCount: AVAudioFrameCount, value: Float) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount

        if let channelData = buffer.floatChannelData {
            for channel in 0..<Int(format.channelCount) {
                for frame in 0..<Int(frameCount) {
                    channelData[channel][frame] = value
                }
            }
        }

        return buffer
    }

    private func createTestBufferWithValues(format: AVAudioFormat, values: [Float]) -> AVAudioPCMBuffer {
        let frameCount = AVAudioFrameCount(values.count)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount

        if let channelData = buffer.floatChannelData {
            for channel in 0..<Int(format.channelCount) {
                for frame in 0..<Int(frameCount) {
                    channelData[channel][frame] = values[frame]
                }
            }
        }

        return buffer
    }
}

// MARK: - Helper Actor for Thread-Safe Result Collection

/// Actor to safely collect results from concurrent test tasks.
private actor ResultsCollector {
    private var micResults: [Bool] = []
    private var appResults: [Bool] = []

    func addMicResult(_ success: Bool) {
        micResults.append(success)
    }

    func addAppResult(_ success: Bool) {
        appResults.append(success)
    }

    func getResults() -> (mic: [Bool], app: [Bool]) {
        return (micResults, appResults)
    }
}
