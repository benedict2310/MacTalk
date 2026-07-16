//
//  TranscriptionControllerTests.swift
//  MacTalkTests
//
//  Tests for the deterministic transcript-cleaning pipeline. Controller lifecycle
//  coverage requires an injectable fake ASR engine and capture boundaries.
//

import XCTest
@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
@testable import MacTalk

final class TranscriptionControllerTests: XCTestCase {
    func test_stripsLeadingPunctuationArtifacts() {
        XCTAssertEqual(TranscriptCleaner.clean(". this is a test"), "This is a test.")
        XCTAssertEqual(TranscriptCleaner.clean("... okay let's try this"), "Okay let's try this.")
        XCTAssertEqual(TranscriptCleaner.clean(", uh this started with a comma"), "This started with a comma.")
    }

    func test_normalizesPunctuationSpacing() {
        XCTAssertEqual(TranscriptCleaner.clean("hello , world !"), "Hello, world!")
        XCTAssertEqual(TranscriptCleaner.clean("is this working ?"), "Is this working?")
    }

    func test_preservesValidTerminalPunctuation() {
        XCTAssertEqual(TranscriptCleaner.clean("already done!"), "Already done!")
        XCTAssertEqual(TranscriptCleaner.clean("is this done?"), "Is this done?")
    }

    func test_removesStandaloneFillerWords() {
        XCTAssertEqual(
            TranscriptCleaner.clean("Okay, let's give this um a quick test. Uh and I'm specifically putting a lot of um thinking into this."),
            "Okay, let's give this a quick test. And I'm specifically putting a lot of thinking into this."
        )
        XCTAssertEqual(
            TranscriptCleaner.clean("Um, this starts with filler. Hmm, this also has hesitation."),
            "This starts with filler. This also has hesitation."
        )
    }

    func test_doesNotRemoveFillerSubstringsInsideWords() {
        XCTAssertEqual(
            TranscriptCleaner.clean("The summary number, umbrella, and humming are important."),
            "The summary number, umbrella, and humming are important."
        )
    }

    func test_capitalizesSentenceStartsAfterFillerRemoval() {
        XCTAssertEqual(
            TranscriptCleaner.clean("this is first. uh this should be capitalized. um this too"),
            "This is first. This should be capitalized. This too."
        )
    }

    func test_emptyAndWhitespaceOnlyInputProduceEmptyOutput() {
        XCTAssertEqual(TranscriptCleaner.clean(""), "")
        XCTAssertEqual(TranscriptCleaner.clean("   \n\t"), "")
    }

    func test_stoppedSessionRejectsLateAppCallbackBeforeConversion() throws {
        let gate = AudioSessionGate()
        let firstSession = gate.begin()
        let appStream = AudioMixer().makeStream()

        gate.stop()
        let secondSession = gate.begin()
        let lateResult: [Float]? = gate.withAcceptedSession(firstSession) {
            appStream.convert(buffer: makeConstantPCMBuffer(
                sampleRate: 48_000,
                channels: 1,
                frameCount: 4_800
            ))
        } ?? nil

        XCTAssertFalse(gate.accepts(firstSession))
        XCTAssertTrue(gate.accepts(secondSession))
        XCTAssertNil(lateResult)
        XCTAssertTrue(try XCTUnwrap(appStream.finish()).isEmpty)
    }

    func test_controllerRejectsOldAppCallbackAfterStopAndRestart() throws {
        let controller = TranscriptionController(engine: LifecycleTestEngine())
        let firstSession = controller.beginSessionForTesting()
        controller.stopSessionForTesting()
        let secondSession = controller.beginSessionForTesting()
        let sampleBuffer = try makeAppSampleBuffer(frameCount: 4_800)

        let oldResult = controller.deliverAppSampleBufferForTesting(sampleBuffer, sessionID: firstSession)
        let countAfterOldCallback = controller.bufferedAudioSampleCountForTesting
        let newResult = controller.deliverAppSampleBufferForTesting(sampleBuffer, sessionID: secondSession)

        XCTAssertNil(oldResult)
        XCTAssertEqual(countAfterOldCallback, 0)
        XCTAssertNotNil(newResult)
        XCTAssertGreaterThan(newResult ?? 0, 0)
        XCTAssertEqual(controller.bufferedAudioSampleCountForTesting, newResult)
    }

    private func makeAppSampleBuffer(frameCount: Int) throws -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 16_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var formatDescription: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        ) == noErr, let formatDescription else {
            throw NSError(domain: "TranscriptionControllerTests", code: 1)
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 16_000),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreate(
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
        ) == noErr, let sampleBuffer else {
            throw NSError(domain: "TranscriptionControllerTests", code: 2)
        }

        let sampleByteCount = frameCount * MemoryLayout<Float>.size
        var samples = [Float](repeating: 0.25, count: frameCount)
        let audioBufferList = AudioBufferList.allocate(maximumBuffers: 1)
        defer { audioBufferList.unsafeMutablePointer.deallocate() }
        let setStatus = samples.withUnsafeMutableBufferPointer { samplesBuffer in
            audioBufferList.unsafeMutablePointer.pointee.mNumberBuffers = 1
            audioBufferList[0] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(sampleByteCount),
                mData: samplesBuffer.baseAddress
            )
            return CMSampleBufferSetDataBufferFromAudioBufferList(
                sampleBuffer,
                blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault,
                flags: 0,
                bufferList: audioBufferList.unsafePointer
            )
        }
        guard setStatus == noErr else {
            throw NSError(domain: "TranscriptionControllerTests", code: Int(setStatus))
        }
        return sampleBuffer
    }
}

private final class LifecycleTestEngine: @unchecked Sendable, ASREngine {
    let provider: ASRProvider = .whisper

    func prepare() async throws {}
    func reset() async {}
    func process(_ buffer: AVAudioPCMBuffer, language: String?) async throws -> ASRPartial? { nil }
    func finalize(_ buffer: AVAudioPCMBuffer, language: String?) async throws -> ASRFinalSegment? { nil }
    func setPartialHandler(_ handler: (@Sendable (ASRPartial) -> Void)?) {}
}
