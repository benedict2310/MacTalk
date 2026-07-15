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

    func test_48kHzMonoConversionPreservesDuration() throws {
        let mixer = AudioMixer()
        let buffer = makeConstantPCMBuffer(
            sampleRate: 48_000,
            channels: 1,
            frameCount: 4_800
        )

        let samples = try XCTUnwrap(mixer.convert(buffer: buffer))

        XCTExpectFailure("AudioMixer does not drain AVAudioConverter priming frames yet.")
        XCTAssertEqual(samples.count, 1_600, accuracy: 1)
    }

    func test_44kHzStereoConversionPreservesDuration() throws {
        let mixer = AudioMixer()
        let buffer = makeConstantPCMBuffer(
            sampleRate: 44_100,
            channels: 2,
            frameCount: 4_410
        )

        let samples = try XCTUnwrap(mixer.convert(buffer: buffer))

        XCTExpectFailure("AudioMixer does not drain AVAudioConverter priming frames yet.")
        XCTAssertEqual(samples.count, 1_600, accuracy: 1)
    }

    func test_largeBufferPreservesDuration() throws {
        let mixer = AudioMixer()
        let buffer = makeConstantPCMBuffer(
            sampleRate: 48_000,
            channels: 2,
            frameCount: 480_000
        )

        let samples = try XCTUnwrap(mixer.convert(buffer: buffer))

        XCTExpectFailure("AudioMixer loses converter priming frames even for large buffers.")
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

        XCTExpectFailure("AudioMixer currently loses frames on every converted buffer.")
        XCTAssertEqual(totalOutputFrames, 16_000, accuracy: 2)
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
}
