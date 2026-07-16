//
//  TranscriptionControllerTests.swift
//  MacTalkTests
//
//  Tests for the deterministic transcript-cleaning pipeline. Controller lifecycle
//  coverage requires an injectable fake ASR engine and capture boundaries.
//

import XCTest
import os
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

    func test_controllerRejectsOldAppCallbackAfterStopAndRestart() async throws {
        let captureSession = LifecycleCaptureSession()
        let engine = LifecycleTestEngine()
        let controller = TranscriptionController(engine: engine, captureSession: captureSession)
        let source = AppPickerWindowController.AudioSource(
            app: nil,
            display: nil,
            name: "deterministic test source",
            icon: nil
        )
        let sampleBuffer = try makeAppSampleBuffer(frameCount: 24_000)

        try await controller.start(mode: .micPlusAppAudio, audioSource: source)
        controller.stop()
        try await controller.start(mode: .micPlusAppAudio, audioSource: source)

        XCTAssertEqual(captureSession.appCallbacks.count, 2)
        captureSession.appCallbacks[0](sampleBuffer)
        captureSession.appCallbacks[1](sampleBuffer)
        controller.stop()

        for _ in 0..<100 where engine.finalizedFrameCounts.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(engine.finalizedFrameCounts, [24_000])
    }

    func test_appAudioFailureFallsBackToMicOnlyWithoutStoppingMicrophone() async throws {
        let captureSession = LifecycleCaptureSession()
        let controller = TranscriptionController(
            engine: LifecycleTestEngine(),
            captureSession: captureSession
        )
        let fallback = expectation(description: "controller falls back to mic-only")
        controller.onFallbackToMicOnly = { fallback.fulfill() }
        let source = AppPickerWindowController.AudioSource(
            app: nil,
            display: nil,
            name: "deterministic test source",
            icon: nil
        )

        try await controller.start(mode: .micPlusAppAudio, audioSource: source)
        let stopCountBeforeFailure = captureSession.stopCount
        captureSession.triggerAppAudioError()
        await fulfillment(of: [fallback], timeout: 1)

        XCTAssertEqual(captureSession.microphoneStartCount, 1)
        XCTAssertEqual(captureSession.stopCount, stopCountBeforeFailure)
        XCTAssertEqual(captureSession.stopAppAudioCount, 1)
        XCTAssertNotNil(captureSession.onMicrophoneBuffer)
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

private final class LifecycleCaptureSession: @unchecked Sendable, TranscriptionCaptureSession {
    var onMicrophoneBuffer: (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)?
    var onAppAudioSampleBuffer: (@Sendable (CMSampleBuffer) -> Void)?
    var onStreamError: (@Sendable (Error) -> Void)?
    private(set) var appCallbacks: [(@Sendable (CMSampleBuffer) -> Void)] = []
    private(set) var microphoneStartCount = 0
    private(set) var stopCount = 0
    private(set) var stopAppAudioCount = 0

    func startMicrophone() throws {
        microphoneStartCount += 1
    }

    func startAppAudio(source: AppPickerWindowController.AudioSource) async throws {
        guard let onAppAudioSampleBuffer else {
            XCTFail("Controller must install the app-audio callback before starting capture")
            return
        }
        appCallbacks.append(onAppAudioSampleBuffer)
    }

    func stop() {
        stopCount += 1
    }

    func stopAppAudio() {
        stopAppAudioCount += 1
    }

    func triggerAppAudioError() {
        onStreamError?(NSError(domain: "LifecycleCaptureSession", code: 1))
    }
}

private final class LifecycleTestEngine: @unchecked Sendable, ASREngine {
    let provider: ASRProvider = .whisper
    private let finalizedFrameCountsLock = OSAllocatedUnfairLock(initialState: [Int]())

    var finalizedFrameCounts: [Int] {
        finalizedFrameCountsLock.withLock { $0 }
    }

    func prepare() async throws {}
    func reset() async {}
    func process(_ buffer: AVAudioPCMBuffer, language: String?) async throws -> ASRPartial? { nil }
    func finalize(_ buffer: AVAudioPCMBuffer, language: String?) async throws -> ASRFinalSegment? {
        finalizedFrameCountsLock.withLock { counts in
            counts.append(Int(buffer.frameLength))
        }
        return nil
    }
    func setPartialHandler(_ handler: (@Sendable (ASRPartial) -> Void)?) {}
}
