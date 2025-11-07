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
