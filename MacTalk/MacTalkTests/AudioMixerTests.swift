//
//  AudioMixerTests.swift
//  MacTalkTests
//
//  Behavioral tests for sample-rate conversion and converter reuse.
//

import XCTest
@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
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

    func test_streaming44kHzUnevenBuffersMatchesOneShotAtBoundaries() throws {
        let sampleRate = 44_100.0
        let totalFrames = 44_100
        var source: [Float] = []
        source.reserveCapacity(totalFrames)
        for frame in 0..<totalFrames {
            let phase = Float(frame) * 2 * Float.pi * 440 / Float(sampleRate)
            source.append(sin(phase))
        }
        let mixer = AudioMixer()
        let oneShot = try XCTUnwrap(mixer.convert(buffer: makePCMBuffer(sampleRate: sampleRate, channels: [source])))
        let stream = mixer.makeStream()
        let splitSizes = [137, 997, 4_096, 12_345, 271, 8_888, 17_366]
        var streamed: [Float] = []
        var sourceOffset = 0

        for splitSize in splitSizes {
            let end = sourceOffset + splitSize
            let chunk = Array(source[sourceOffset..<end])
            streamed += try XCTUnwrap(stream.convert(buffer: makePCMBuffer(sampleRate: sampleRate, channels: [chunk])))
            sourceOffset = end
        }

        streamed += try XCTUnwrap(stream.finish())

        XCTAssertEqual(sourceOffset, totalFrames)
        XCTAssertEqual(streamed.count, oneShot.count, accuracy: 1)
        let comparableCount = min(streamed.count, oneShot.count)
        let maxDifference = zip(streamed.prefix(comparableCount), oneShot.prefix(comparableCount))
            .map { abs($0 - $1) }
            .max() ?? 0
        XCTAssertLessThan(maxDifference, 0.05)
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

    func test_monoFloat32SampleBufferConvertsSamples() throws {
        let sampleBuffer = try makeFloat32SampleBuffer(
            channels: [[0.1, 0.2, 0.3, 0.4]],
            interleaved: false
        )

        let samples = try XCTUnwrap(AudioMixer().convertSampleBuffer(sampleBuffer))

        XCTAssertEqual(samples.count, 4)
        for (actual, expected) in zip(samples, [0.1, 0.2, 0.3, 0.4]) {
            XCTAssertEqual(Double(actual), Double(expected), accuracy: 0.0001)
        }
    }

    func test_interleavedStereoFloat32SampleBufferDownmixesBothChannels() throws {
        let sampleBuffer = try makeFloat32SampleBuffer(
            channels: [[0.1, 0.2, 0.3, 0.4], [0.5, 0.4, 0.3, 0.2]],
            interleaved: true
        )
        let pcmBuffer = try XCTUnwrap(sampleBuffer.makePCMBuffer())
        let channelData = try XCTUnwrap(pcmBuffer.floatChannelData)
        XCTAssertEqual(pcmBuffer.format.channelCount, 2)
        XCTAssertEqual(channelData[0][0], 0.1, accuracy: 0.0001)
        XCTAssertEqual(channelData[1][0], 0.5, accuracy: 0.0001)

        let samples = try XCTUnwrap(AudioMixer().convertSampleBuffer(sampleBuffer))

        XCTAssertEqual(samples.count, 4)
        for (actual, expected) in zip(samples, [0.3, 0.3, 0.3, 0.3]) {
            XCTAssertEqual(Double(actual), Double(expected), accuracy: 0.0001)
        }
    }

    func test_nonInterleavedStereoFloat32SampleBufferDownmixesBothChannels() throws {
        let sampleBuffer = try makeFloat32SampleBuffer(
            channels: [[0.1, 0.2, 0.3, 0.4], [0.9, 0.8, 0.7, 0.6]],
            interleaved: false
        )

        let samples = try XCTUnwrap(AudioMixer().convertSampleBuffer(sampleBuffer))

        XCTAssertEqual(samples.count, 4)
        for (actual, expected) in zip(samples, [0.5, 0.5, 0.5, 0.5]) {
            XCTAssertEqual(Double(actual), Double(expected), accuracy: 0.0001)
        }
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

    private func makeFloat32SampleBuffer(
        channels: [[Float]],
        interleaved: Bool
    ) throws -> CMSampleBuffer {
        precondition(!channels.isEmpty)
        precondition(channels.allSatisfy { $0.count == channels[0].count })

        let channelCount = channels.count
        let frameCount = channels[0].count
        let bytesPerSample = MemoryLayout<Float>.size
        let bytesPerFrame = interleaved ? bytesPerSample * channelCount : bytesPerSample
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 16_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
                | (interleaved ? 0 : kAudioFormatFlagIsNonInterleaved),
            mBytesPerPacket: UInt32(bytesPerFrame),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(bytesPerFrame),
            mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel: 32,
            mReserved: 0
        )

        var formatDescription: CMAudioFormatDescription?
        let formatStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        guard formatStatus == noErr, let formatDescription else {
            throw NSError(domain: "AudioMixerTests", code: Int(formatStatus))
        }

        let byteCount = frameCount * bytesPerFrame
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 16_000),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: frameCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else {
            throw NSError(domain: "AudioMixerTests", code: Int(sampleStatus))
        }

        var encoded = [Float]()
        encoded.reserveCapacity(frameCount * channelCount)
        if interleaved {
            for frame in 0..<frameCount {
                for channel in channels {
                    encoded.append(channel[frame])
                }
            }
        } else {
            encoded = channels.flatMap { $0 }
        }

        let audioBufferList = AudioBufferList.allocate(maximumBuffers: interleaved ? 1 : channelCount)
        audioBufferList.unsafeMutablePointer.pointee.mNumberBuffers = UInt32(interleaved ? 1 : channelCount)
        defer { audioBufferList.unsafeMutablePointer.deallocate() }
        let setStatus = encoded.withUnsafeMutableBufferPointer { encodedBuffer in
            if interleaved {
                audioBufferList[0] = AudioBuffer(
                    mNumberChannels: UInt32(channelCount),
                    mDataByteSize: UInt32(byteCount),
                    mData: encodedBuffer.baseAddress
                )
            } else {
                for channel in 0..<channelCount {
                    audioBufferList[channel] = AudioBuffer(
                        mNumberChannels: 1,
                        mDataByteSize: UInt32(frameCount * bytesPerSample),
                        mData: encodedBuffer.baseAddress!.advanced(by: channel * frameCount)
                    )
                }
            }
            return CMSampleBufferSetDataBufferFromAudioBufferList(
                sampleBuffer,
                blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault,
                flags: 0,
                bufferList: audioBufferList.unsafePointer
            )
        }
        guard setStatus == noErr else {
            throw NSError(domain: "AudioMixerTests", code: Int(setStatus))
        }
        return sampleBuffer
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
