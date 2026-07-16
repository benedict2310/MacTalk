//
//  AudioMixerTests.swift
//  MacTalkTests
//
//  Behavioral tests for sample-rate conversion and converter reuse.
//

import XCTest
@preconcurrency import AVFoundation
@testable import MacTalk

final class AudioMixerTests: XCTestCase {
    func test_identityConversionPreservesFramesAndSamples() throws {
        let mixer = AudioMixer()
        let buffer = makeConstantPCMBuffer(
            sampleRate: 16_000,
            channels: 1,
            frameCount: 1_000,
            value: 0.25
        )

        let samples = try XCTUnwrap(mixer.convert(buffer: buffer))

        XCTAssertEqual(samples.count, 1_000)
        XCTAssertTrue(samples.allSatisfy { abs($0 - 0.25) < 0.001 })
    }

    func test_emptyInputReturnsEmptyArray() throws {
        let mixer = AudioMixer()
        let buffer = makeConstantPCMBuffer(
            sampleRate: 48_000,
            channels: 1,
            frameCount: 0
        )

        let samples = try XCTUnwrap(mixer.convert(buffer: buffer))

        XCTAssertTrue(samples.isEmpty)
    }

    func test_48kHzMonoConversionPreservesDuration() throws {
        let mixer = AudioMixer()
        let buffer = makeConstantPCMBuffer(
            sampleRate: 48_000,
            channels: 1,
            frameCount: 4_800
        )

        let samples = try XCTUnwrap(mixer.convert(buffer: buffer))

        XCTAssertEqual(samples.count, 1_600, accuracy: 1)
    }

    func test_48kHzStereoConversionDownmixesChannels() throws {
        let mixer = AudioMixer()
        let buffer = makePCMBuffer(
            sampleRate: 48_000,
            channels: [[Float](repeating: 0.8, count: 4_800), [Float](repeating: 0.2, count: 4_800)]
        )

        let samples = try XCTUnwrap(mixer.convert(buffer: buffer))

        XCTAssertEqual(samples.count, 1_600, accuracy: 1)
        XCTAssertEqual(samples[samples.count / 2], 0.5, accuracy: 0.01)
        XCTAssertEqual(samples.dropFirst(100).dropLast(100).reduce(0, +) / Float(samples.count - 200), 0.5, accuracy: 0.01)
    }

    func test_44kHzStereoConversionPreservesDuration() throws {
        let mixer = AudioMixer()
        let buffer = makePCMBuffer(
            sampleRate: 44_100,
            channels: [[Float](repeating: 0.25, count: 4_410), [Float](repeating: 0.25, count: 4_410)]
        )

        let samples = try XCTUnwrap(mixer.convert(buffer: buffer))

        XCTAssertEqual(samples.count, 1_600, accuracy: 1)
    }

    func test_smallBufferHasExplicitNonNilResult() throws {
        let mixer = AudioMixer()
        let buffer = makeConstantPCMBuffer(
            sampleRate: 48_000,
            channels: 1,
            frameCount: 1
        )

        let samples = try XCTUnwrap(mixer.convert(buffer: buffer))

        XCTAssertLessThanOrEqual(samples.count, 1)
    }

    func test_largeBufferPreservesDuration() throws {
        let mixer = AudioMixer()
        let buffer = makeConstantPCMBuffer(
            sampleRate: 48_000,
            channels: 2,
            frameCount: 480_000
        )

        let samples = try XCTUnwrap(mixer.convert(buffer: buffer))

        XCTAssertEqual(samples.count, 160_000, accuracy: 1)
    }

    func test_repeatedBuffersPreserveTotalDuration() throws {
        let mixer = AudioMixer()
        var totalOutputFrames = 0

        for _ in 0..<10 {
            let buffer = makeConstantPCMBuffer(
                sampleRate: 48_000,
                channels: 1,
                frameCount: 4_800
            )
            totalOutputFrames += try XCTUnwrap(mixer.convert(buffer: buffer)).count
        }

        XCTAssertEqual(totalOutputFrames, 16_000, accuracy: 2)
    }

    func test_sequentialBuffersPreserveContinuityWithoutSystematicLoss() throws {
        let mixer = AudioMixer()
        let first = makeConstantPCMBuffer(
            sampleRate: 48_000,
            channels: 1,
            frameCount: 4_800,
            value: 0.1
        )
        let second = makeConstantPCMBuffer(
            sampleRate: 48_000,
            channels: 1,
            frameCount: 4_800,
            value: 0.9
        )

        let firstSamples = try XCTUnwrap(mixer.convert(buffer: first))
        let secondSamples = try XCTUnwrap(mixer.convert(buffer: second))

        XCTAssertEqual(firstSamples.count, 1_600, accuracy: 1)
        XCTAssertEqual(secondSamples.count, 1_600, accuracy: 1)
        let firstMean = firstSamples.dropFirst(100).dropLast(100).reduce(0, +) / Float(firstSamples.count - 200)
        let secondMean = secondSamples.dropFirst(100).dropLast(100).reduce(0, +) / Float(secondSamples.count - 200)
        XCTAssertEqual(firstMean, 0.1, accuracy: 0.01)
        XCTAssertEqual(secondMean, 0.9, accuracy: 0.01)
    }

    func test_concurrentSameFormatConversionsAllSucceed() async {
        let mixer = AudioMixer()
        let successes = TestCounter()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<40 {
                group.addTask {
                    let buffer = makeConstantPCMBuffer(
                        sampleRate: 48_000,
                        channels: 1,
                        frameCount: 4_800
                    )
                    if mixer.convert(buffer: buffer) != nil {
                        await successes.increment()
                    }
                }
            }
        }

        let successCount = await successes.getCount()
        XCTAssertEqual(successCount, 40)
    }

    func test_concurrentMicAndAppFormatsAllSucceed() async {
        let mixer = AudioMixer()
        let successes = TestCounter()

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<40 {
                group.addTask {
                    let buffer = index.isMultiple(of: 2)
                        ? makeConstantPCMBuffer(sampleRate: 48_000, channels: 1, frameCount: 4_800)
                        : makeConstantPCMBuffer(sampleRate: 44_100, channels: 2, frameCount: 4_410)
                    if mixer.convert(buffer: buffer) != nil {
                        await successes.increment()
                    }
                }
            }
        }

        let successCount = await successes.getCount()
        XCTAssertEqual(successCount, 40)
    }

    private func makePCMBuffer(sampleRate: Double, channels: [[Float]]) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels.count),
            interleaved: false
        )!
        let frameCount = AVAudioFrameCount(channels.first?.count ?? 0)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount

        for (channel, samples) in channels.enumerated() {
            samples.withUnsafeBufferPointer { source in
                buffer.floatChannelData![channel].update(from: source.baseAddress!, count: samples.count)
            }
        }
        return buffer
    }
}
