//
//  TranscriptionControllerTests.swift
//  MacTalkTests
//
//  Tests for the deterministic transcript-cleaning pipeline. Controller lifecycle
//  coverage requires an injectable fake ASR engine and capture boundaries.
//

import XCTest
import AudioToolbox
import os
@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
@testable import MacTalk

final class TranscriptionControllerTests: XCTestCase {
    private var scheduler: DeterministicManualScheduler!

    override func setUp() {
        super.setUp()
        scheduler = DeterministicManualScheduler(clock: DeterministicManualClock())
    }

    private func advanceStopScheduler() async {
        scheduler.clock.advance(nanoseconds: 100_000_000)
        scheduler.fireDue()
        await Task.yield()
    }

    private func stopAndAdvance(_ controller: TranscriptionController) async {
        let completion = expectation(description: "controller stop completed")
        controller.onFinalizationComplete = { completion.fulfill() }
        controller.stop()
        await advanceStopScheduler()
        await fulfillment(of: [completion], timeout: 1)
    }
    func test_deterministicEngineRecordsPreparationChunkLanguageAndFinalSamples() async throws {
        let isolatedDefaults = makeIsolatedTestDefaults()
        let defaults = isolatedDefaults.defaults
        defer { defaults.removePersistentDomain(forName: isolatedDefaults.suiteName) }
        let settings = AppSettings.makeForTesting(defaults: defaults)
        let capture = DeterministicCaptureSession()
        let partial = ASRPartial(text: "partial result", words: [])
        let final = ASRFinalSegment(text: "final result", words: [])
        let engine = DeterministicASREngine(script: DeterministicASRScript(partials: [partial], finals: [final]))
        let processStarted = expectation(description: "incremental process started")
        engine.onEvent = { event in
            if case .process = event { processStarted.fulfill() }
        }
        let controller = TranscriptionController(engine: engine, captureSession: capture, settings: settings, scheduler: scheduler)
        controller.language = "en"

        let finalExpectation = expectation(description: "final callback")
        let finalText = DeterministicValueBox("")
        controller.onFinal = { text in
            finalText.set(text)
            finalExpectation.fulfill()
        }

        try await controller.start(mode: .micOnly)
        let samples = [Float](repeating: 0.25, count: 16_000)
        capture.emitMicrophone(AudioCaptureFrame(
            samples: samples,
            sampleRate: 16_000,
            firstSampleHostTime: DeterministicAudioFixtures.hostTime(nanoseconds: 1_000_000_000)
        ))
        capture.emitMicrophone(AudioCaptureFrame(
            samples: samples,
            sampleRate: 16_000,
            firstSampleHostTime: DeterministicAudioFixtures.hostTime(nanoseconds: 2_000_000_000)
        ))
        await fulfillment(of: [processStarted], timeout: 1)
        XCTAssertEqual(engine.processCalls.count, 1)
        let processCall = try XCTUnwrap(engine.processCalls.first)
        XCTAssertEqual(processCall.samples.count, 24_000)
        XCTAssertEqual(processCall.language, "en")

        await stopAndAdvance(controller)
        await fulfillment(of: [finalExpectation], timeout: 2)
        XCTAssertEqual(finalText.get(), "Final result.")
        XCTAssertEqual(engine.finalizeCalls.map(\.samples), [samples + samples])
        XCTAssertEqual(engine.events.compactMap { event -> String? in
            switch event {
            case .prepare: return "prepare"
            case .reset: return "reset"
            case .process: return "process"
            case .finalize: return "finalize"
            case .cancelled: return "cancelled"
            }
        }, ["prepare", "reset", "process", "finalize"])
    }

    func test_finalTranscriptPreservesEarlierPartialsWithoutDuplicatingOverlap() async throws {
        let capture = DeterministicCaptureSession()
        let engine = DeterministicASREngine(script: DeterministicASRScript(
            partials: [
                ASRPartial(text: "Application audio validation.", words: []),
                ASRPartial(text: "Microphone channel confirmed.", words: [])
            ],
            finals: [ASRFinalSegment(text: "Microphone channel confirmed. Thank you.", words: [])]
        ))
        let processStarted = expectation(description: "both incremental requests started")
        processStarted.expectedFulfillmentCount = 2
        engine.onEvent = { event in
            if case .process = event { processStarted.fulfill() }
        }
        let controller = TranscriptionController(engine: engine, captureSession: capture, scheduler: scheduler)
        let finalExpectation = expectation(description: "reconciled final callback")
        let finalText = DeterministicValueBox("")
        controller.onFinal = { text in
            finalText.set(text)
            finalExpectation.fulfill()
        }

        try await controller.start(mode: .micOnly)
        for frameIndex in 0..<12 {
            capture.emitMicrophone(AudioCaptureFrame(
                samples: [Float](repeating: 0.25, count: 8_000),
                sampleRate: 16_000,
                firstSampleHostTime: DeterministicAudioFixtures.hostTime(
                    nanoseconds: 1_000_000_000 + UInt64(frameIndex) * 500_000_000
                )
            ))
        }
        await fulfillment(of: [processStarted], timeout: 1)

        await stopAndAdvance(controller)
        await fulfillment(of: [finalExpectation], timeout: 2)

        XCTAssertEqual(engine.processCalls.map { $0.samples.count }, [24_000, 48_000])
        XCTAssertEqual(
            finalText.get(),
            "Application audio validation. Microphone channel confirmed. Thank you."
        )
    }

    func test_finalTranscriptPreservesBoundaryPunctuationBeforeNewTail() {
        XCTAssertEqual(
            TranscriptFinalReconciler.reconcile(
                incrementalSegments: ["I agree"],
                finalText: "agree, however this changes."
            ),
            "I agree, however this changes."
        )
    }

    func test_finalTranscriptPreservesBoundaryPunctuationWithoutNewTailWords() {
        XCTAssertEqual(
            TranscriptFinalReconciler.reconcile(
                incrementalSegments: ["I agree"],
                finalText: "agree,"
            ),
            "I agree,"
        )
    }

    func test_microphoneCaptureStartFailureCleansUpBeforeSurfacing() async throws {
        let capture = DeterministicCaptureSession()
        capture.microphoneStartError = DeterministicCaptureSession.Error.microphoneStart
        let engine = DeterministicASREngine()
        let controller = TranscriptionController(engine: engine, captureSession: capture, scheduler: scheduler)

        do {
            try await controller.start(mode: .micOnly)
            XCTFail("Expected microphone capture start failure")
        } catch let error as DeterministicCaptureSession.Error {
            XCTAssertEqual(error, .microphoneStart)
        }
        XCTAssertEqual(capture.stopCount, 2)
        XCTAssertEqual(engine.events, [])
    }

    func test_applicationCaptureStartFailureCleansUpBeforeSurfacing() async throws {
        let capture = DeterministicCaptureSession()
        capture.appStartError = DeterministicCaptureSession.Error.appStart
        let engine = DeterministicASREngine()
        let controller = TranscriptionController(engine: engine, captureSession: capture, scheduler: scheduler)
        let source = AppPickerWindowController.AudioSource(app: nil, display: nil, name: "fake", icon: nil)

        do {
            try await controller.start(mode: .micPlusAppAudio, audioSource: source)
            XCTFail("Expected application capture start failure")
        } catch let error as DeterministicCaptureSession.Error {
            XCTAssertEqual(error, .appStart)
        }
        XCTAssertEqual(capture.stopCount, 2)
        XCTAssertEqual(engine.events, [])
    }

    func test_partialFinalAndLifecycleCallbacksSerializeAdversarialInferenceCompletion() async throws {
        let capture = DeterministicCaptureSession()
        let processBarrier = DeterministicASRBarrier()
        let finalizeBarrier = DeterministicASRBarrier()
        let engine = DeterministicASREngine(script: DeterministicASRScript(
            partials: [ASRPartial(text: "live words", words: [])],
            finals: [ASRFinalSegment(text: "final words", words: [])],
            processBarrier: processBarrier,
            finalizeBarrier: finalizeBarrier
        ))
        let controller = TranscriptionController(engine: engine, captureSession: capture, scheduler: scheduler)
        let events = DeterministicValueBox<[String]>([])
        let processStarted = expectation(description: "partial inference entered fake engine")
        let finalizeStarted = expectation(description: "final inference entered fake engine")
        let partial = expectation(description: "partial callback")
        let final = expectation(description: "final callback")
        let finalizationComplete = expectation(description: "finalization complete")
        engine.onEvent = { event in
            switch event {
            case .process: processStarted.fulfill()
            case .finalize: finalizeStarted.fulfill()
            default: break
            }
        }
        controller.onPartial = { _ in
            events.set(events.get() + ["partial"])
            partial.fulfill()
        }
        controller.onFinal = { _ in
            events.set(events.get() + ["final"])
            final.fulfill()
        }
        controller.onFinalizationComplete = { finalizationComplete.fulfill() }

        try await controller.start(mode: .micOnly)
        scheduler.clock.advance(nanoseconds: 100_000_000)
        capture.emitMicrophone(AudioCaptureFrame(
            samples: [Float](repeating: 0.25, count: 16_000),
            sampleRate: 16_000,
            firstSampleHostTime: DeterministicAudioFixtures.hostTime(nanoseconds: 1_000_000_000)
        ))
        capture.emitMicrophone(AudioCaptureFrame(
            samples: [Float](repeating: 0.25, count: 16_000),
            sampleRate: 16_000,
            firstSampleHostTime: DeterministicAudioFixtures.hostTime(nanoseconds: 2_000_000_000)
        ))
        await fulfillment(of: [processStarted], timeout: 1)

        // Stop while the independently gated partial inference is still in flight.
        controller.stop()
        await advanceStopScheduler()
        await fulfillment(of: [finalizeStarted], timeout: 1)

        // Deliberately complete final inference first. The controller must hold
        // its observable final callback behind the already-running partial.
        finalizeBarrier.release()
        await Task.yield()
        XCTAssertEqual(events.get(), [])

        processBarrier.release()
        await fulfillment(of: [partial, final, finalizationComplete], timeout: 2)
        XCTAssertEqual(events.get(), ["partial", "final"])
    }

    func test_startPreparationFailureStopsCaptureAndReportsError() async throws {
        let capture = DeterministicCaptureSession()
        let engine = DeterministicASREngine(script: DeterministicASRScript(prepareError: .prepare))
        let controller = TranscriptionController(engine: engine, captureSession: capture, scheduler: scheduler)

        do {
            try await controller.start(mode: .micOnly)
            XCTFail("Expected preparation to fail")
        } catch let error as DeterministicASRError {
            XCTAssertEqual(error, .prepare)
        }
        XCTAssertEqual(capture.stopCount, 2)
        XCTAssertEqual(engine.events, [.prepare])
    }

    func test_deterministicSilenceDoesNotInvokeIncrementalOrFinalInference() async throws {
        let capture = DeterministicCaptureSession()
        let engine = DeterministicASREngine()
        let controller = TranscriptionController(engine: engine, captureSession: capture, scheduler: scheduler)
        try await controller.start(mode: .micOnly)
        capture.emitMicrophone(AudioCaptureFrame(
            samples: DeterministicAudioFixtures.silence(count: 24_000),
            sampleRate: 16_000,
            firstSampleHostTime: DeterministicAudioFixtures.hostTime(nanoseconds: 2_000_000_000)
        ))
        await stopAndAdvance(controller)
        XCTAssertTrue(engine.processCalls.isEmpty)
        XCTAssertTrue(engine.finalizeCalls.isEmpty)
        XCTAssertEqual(engine.events.filter { $0 == .prepare || $0 == .reset }, [.prepare, .reset])
    }

    func test_whisperUsesIncrementalChunkProcessing() {
        XCTAssertTrue(ASRProvider.whisper.usesIncrementalChunkProcessing)
    }

    func test_parakeetUsesFinalOnlyProcessingToAvoidInferenceOverlap() {
        XCTAssertFalse(ASRProvider.parakeet.usesIncrementalChunkProcessing)
    }

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
        let lateResult: [Float]? = gate.accepts(firstSession) ? appStream.convert(buffer: makeConstantPCMBuffer(
            sampleRate: 48_000,
            channels: 1,
            frameCount: 4_800
        )) : nil

        XCTAssertFalse(gate.accepts(firstSession))
        XCTAssertTrue(gate.accepts(secondSession))
        XCTAssertNil(lateResult)
        XCTAssertTrue(try XCTUnwrap(appStream.finish()).isEmpty)
    }

    func test_controllerUsesOneImmutableSettingsSnapshotForSession() async throws {
        let defaults = UserDefaults(suiteName: "TranscriptionControllerSettingsSnapshotTests")!
        defaults.removePersistentDomain(forName: "TranscriptionControllerSettingsSnapshotTests")
        defer { defaults.removePersistentDomain(forName: "TranscriptionControllerSettingsSnapshotTests") }

        let settings = AppSettings.makeForTesting(defaults: defaults)
        settings.setLanguage(nil)
        let snapshot = settings.snapshotAtRecordingStart().withCaptureMode(.micOnly)
        let captureSession = LifecycleCaptureSession()
        let controller = TranscriptionController(
            engine: LifecycleTestEngine(),
            captureSession: captureSession,
            settings: settings,
            scheduler: scheduler
        )

        try await controller.start(mode: .micPlusAppAudio, settingsSnapshot: snapshot)
        settings.setLanguage("de")
        settings.setCaptureMode(.micPlusAppAudio)

        XCTAssertNil(controller.language)
        XCTAssertEqual(captureSession.microphoneCallbacks.count, 1)
        XCTAssertEqual(captureSession.appCallbacks.count, 0)
        await stopAndAdvance(controller)
    }

    func test_controllerRejectsOldAppCallbackAfterStopAndRestart() async throws {
        let captureSession = LifecycleCaptureSession()
        let engine = LifecycleTestEngine()
        let controller = TranscriptionController(engine: engine, captureSession: captureSession, scheduler: scheduler)
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
        captureSession.appCallbacks[0](captureSession.sessionIDs[1], sampleBuffer)
        captureSession.appCallbacks[1](captureSession.sessionIDs[3], sampleBuffer)
        captureSession.microphoneCallbacks[1](captureSession.microphoneSessionIDs[1], AudioCaptureFrame(
            samples: [Float](repeating: 0.25, count: 24_000),
            sampleRate: 16_000,
            firstSampleHostTime: 1
        ))
        await stopAndAdvance(controller)

        XCTAssertEqual(engine.finalizedFrameCounts, [24_000])
    }

    func test_controllerRejectsOldMicrophoneCallbackAfterStopAndRestart() async throws {
        let captureSession = LifecycleCaptureSession()
        let engine = LifecycleTestEngine()
        let controller = TranscriptionController(engine: engine, captureSession: captureSession, scheduler: scheduler)

        try await controller.start(mode: .micOnly)
        let oldCallback = captureSession.microphoneCallbacks[0]
        let oldSessionID = captureSession.microphoneSessionIDs[0]
        controller.stop()
        try await controller.start(mode: .micOnly)
        let newCallback = captureSession.microphoneCallbacks[1]
        let newSessionID = captureSession.microphoneSessionIDs[1]
        let frame = AudioCaptureFrame(samples: [Float](repeating: 0.2, count: 1_600), sampleRate: 16_000)

        oldCallback(oldSessionID, frame)
        newCallback(newSessionID, frame)
        await stopAndAdvance(controller)

        XCTAssertEqual(engine.finalizedFrameCounts, [1_600])
    }

    func test_controllerRejectsOldScreenAudioErrorAfterStopAndRestart() async throws {
        let captureSession = LifecycleCaptureSession()
        let engine = LifecycleTestEngine()
        let controller = TranscriptionController(engine: engine, captureSession: captureSession, scheduler: scheduler)
        let source = AppPickerWindowController.AudioSource(
            app: nil,
            display: nil,
            name: "deterministic test source",
            icon: nil
        )
        let fallback = expectation(description: "current session falls back")
        fallback.assertForOverFulfill = false
        controller.onFallbackToMicOnly = { fallback.fulfill() }

        try await controller.start(mode: .micPlusAppAudio, audioSource: source)
        let oldError = captureSession.errorCallbacks[0]
        let oldSessionID = captureSession.appSessionIDs[0]
        controller.stop()
        try await controller.start(mode: .micPlusAppAudio, audioSource: source)
        let newError = captureSession.errorCallbacks[1]
        let newSessionID = captureSession.appSessionIDs[1]
        let stopAppCountBeforeStaleError = captureSession.stopAppAudioCount

        oldError(oldSessionID, NSError(domain: "old-screen-session", code: 1))
        await Task.yield()
        XCTAssertEqual(captureSession.stopAppAudioCount, stopAppCountBeforeStaleError)

        newError(newSessionID, NSError(domain: "current-screen-session", code: 2))
        await fulfillment(of: [fallback], timeout: 1)
        XCTAssertEqual(captureSession.stopAppAudioCount, stopAppCountBeforeStaleError + 1)
        await stopAndAdvance(controller)
    }

    func test_controllerRejectsConcurrentOldCallbacksDuringRestart() async throws {
        let captureSession = LifecycleCaptureSession()
        let engine = LifecycleTestEngine()
        let controller = TranscriptionController(engine: engine, captureSession: captureSession, scheduler: scheduler)
        let source = AppPickerWindowController.AudioSource(
            app: nil,
            display: nil,
            name: "deterministic test source",
            icon: nil
        )
        let oldSampleBuffer = try makeAppSampleBuffer(frameCount: 12_000)
        let newSampleBuffer = try makeAppSampleBuffer(frameCount: 24_000)

        try await controller.start(mode: .micPlusAppAudio, audioSource: source)
        let oldCallback = captureSession.appCallbacks[0]
        let oldSessionID = captureSession.sessionIDs[1]
        controller.stop()
        try await controller.start(mode: .micPlusAppAudio, audioSource: source)
        let newCallback = captureSession.appCallbacks[1]
        let newSessionID = captureSession.sessionIDs[3]

        // Simulate queued delivery racing with a new stream. The old callback
        // must be rejected by its session token; every new callback is valid.
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    oldCallback(oldSessionID, oldSampleBuffer)
                }
                group.addTask {
                    newCallback(newSessionID, newSampleBuffer)
                }
            }
        }
        captureSession.microphoneCallbacks[1](captureSession.microphoneSessionIDs[1], AudioCaptureFrame(
            samples: [Float](repeating: 0.25, count: 96_000),
            sampleRate: 16_000,
            firstSampleHostTime: 1
        ))
        await stopAndAdvance(controller)

        // The composer keeps the microphone's contiguous post-watermark
        // coverage instead of advancing the shared cursor to discard it.
        XCTAssertEqual(engine.finalizedFrameCounts, [28_000])
    }

    func test_appCallbackQueuedAfterFallbackIsRejectedBeforeConversion() async throws {
        let captureSession = LifecycleCaptureSession()
        let engine = LifecycleTestEngine()
        let controller = TranscriptionController(engine: engine, captureSession: captureSession, scheduler: scheduler)
        let fallback = expectation(description: "controller falls back to mic-only")
        controller.onFallbackToMicOnly = { fallback.fulfill() }
        let source = AppPickerWindowController.AudioSource(
            app: nil,
            display: nil,
            name: "deterministic test source",
            icon: nil
        )
        let sampleBuffer = try makeAppSampleBuffer(frameCount: 24_000)

        try await controller.start(mode: .micPlusAppAudio, audioSource: source)
        let appCallback = captureSession.appCallbacks[0]
        let appSessionID = captureSession.appSessionIDs[0]
        captureSession.triggerAppAudioError()
        await fulfillment(of: [fallback], timeout: 1)

        // ScreenCaptureKit may deliver this callback after fallback has stopped
        // its stream. The app stream generation must reject it before conversion.
        appCallback(appSessionID, sampleBuffer)
        await stopAndAdvance(controller)

        XCTAssertEqual(engine.processedFrameCounts, [])
        XCTAssertEqual(engine.finalizedFrameCounts, [])
    }

    func test_controllerCountsInvalidMicrophoneAndApplicationTimestamps() async throws {
        let capture = LifecycleCaptureSession()
        let controller = TranscriptionController(engine: WaveformTestEngine(), captureSession: capture, scheduler: scheduler)
        let source = AppPickerWindowController.AudioSource(app: nil, display: nil, name: "fake", icon: nil)
        try await controller.start(mode: .micPlusAppAudio, audioSource: source)
        capture.microphoneCallbacks[0](capture.microphoneSessionIDs[0], AudioCaptureFrame(
            samples: [0.2], sampleRate: 16_000, firstSampleHostTime: 0
        ))
        capture.appCallbacks[0](capture.appSessionIDs[0], try makeAppSampleBuffer(
            frameCount: 1, presentationTimeStamp: .invalid
        ))
        XCTAssertEqual(controller.audioCompositionMetrics.invalidMicrophoneTimestamps, 1)
        XCTAssertEqual(controller.audioCompositionMetrics.invalidApplicationTimestamps, 1)
        await stopAndAdvance(controller)
    }

    func test_controllerComposesSimultaneousSecondWaveformsExactly() async throws {
        let source = AppPickerWindowController.AudioSource(app: nil, display: nil, name: "fake", icon: nil)
        let micSamples = [Float](repeating: 0.2, count: 16_000)
        let appSamples = [Float](repeating: 0.6, count: 16_000)
        var waveforms: [[Float]] = []

        for appFirst in [false, true] {
            let capture = LifecycleCaptureSession()
            let engine = WaveformTestEngine()
            let controller = TranscriptionController(engine: engine, captureSession: capture, scheduler: scheduler)
            try await controller.start(mode: .micPlusAppAudio, audioSource: source)
            let hostTime = AudioConvertNanosToHostTime(1_000_000_000)
            let pts = CMTime(value: Int64(AudioConvertHostTimeToNanos(hostTime)), timescale: 1_000_000_000)
            let mic = AudioCaptureFrame(samples: micSamples, sampleRate: 16_000, firstSampleHostTime: hostTime)
            let app = try makeAppSampleBuffer(
                frameCount: appSamples.count,
                samples: appSamples,
                presentationTimeStamp: pts
            )
            if appFirst {
                capture.appCallbacks[0](capture.appSessionIDs[0], app)
                capture.microphoneCallbacks[0](capture.microphoneSessionIDs[0], mic)
            } else {
                capture.microphoneCallbacks[0](capture.microphoneSessionIDs[0], mic)
                capture.appCallbacks[0](capture.appSessionIDs[0], app)
            }
            await stopAndAdvance(controller)
            waveforms.append(try XCTUnwrap(engine.finalizedSamples))
        }

        XCTAssertEqual(waveforms[0], waveforms[1])
        XCTAssertEqual(waveforms[0].count, 16_000)
        XCTAssertTrue(waveforms[0].allSatisfy { abs($0 - 0.4) < 0.0001 })
    }

    func test_controllerSignalsMicReadinessBeforeApplicationAudioArrives() async throws {
        let capture = LifecycleCaptureSession()
        let controller = TranscriptionController(engine: WaveformTestEngine(), captureSession: capture, scheduler: scheduler)
        let ready = expectation(description: "mic ready")
        controller.onMicrophoneReady = { ready.fulfill() }
        let source = AppPickerWindowController.AudioSource(app: nil, display: nil, name: "fake", icon: nil)
        try await controller.start(mode: .micPlusAppAudio, audioSource: source)
        let hostTime = AudioConvertNanosToHostTime(1_000_000_000)
        capture.microphoneCallbacks[0](
            capture.microphoneSessionIDs[0],
            AudioCaptureFrame(samples: [0.2, 0.2], sampleRate: 16_000, firstSampleHostTime: hostTime)
        )
        await fulfillment(of: [ready], timeout: 1)
        await stopAndAdvance(controller)
    }

    func test_controllerFallbackPreservesMicWaveformContinuity() async throws {
        let capture = LifecycleCaptureSession()
        let engine = WaveformTestEngine()
        let controller = TranscriptionController(engine: engine, captureSession: capture, scheduler: scheduler)
        let fallback = expectation(description: "fallback")
        controller.onFallbackToMicOnly = { fallback.fulfill() }
        let source = AppPickerWindowController.AudioSource(app: nil, display: nil, name: "fake", icon: nil)
        try await controller.start(mode: .micPlusAppAudio, audioSource: source)
        let firstNanos: UInt64 = 1_000_000_000
        let firstHost = AudioConvertNanosToHostTime(firstNanos)
        let firstPTS = CMTime(value: Int64(AudioConvertHostTimeToNanos(firstHost)), timescale: 1_000_000_000)
        capture.microphoneCallbacks[0](capture.microphoneSessionIDs[0], AudioCaptureFrame(
            samples: [Float](repeating: 0.2, count: 16_000), sampleRate: 16_000, firstSampleHostTime: firstHost
        ))
        capture.appCallbacks[0](capture.appSessionIDs[0], try makeAppSampleBuffer(
            frameCount: 16_000,
            samples: [Float](repeating: 0.6, count: 16_000),
            presentationTimeStamp: firstPTS
        ))
        capture.triggerAppAudioError()
        await fulfillment(of: [fallback], timeout: 1)
        let secondHost = AudioConvertNanosToHostTime(firstNanos + 1_000_000_000)
        capture.microphoneCallbacks[0](capture.microphoneSessionIDs[0], AudioCaptureFrame(
            samples: [Float](repeating: 0.2, count: 16_000), sampleRate: 16_000, firstSampleHostTime: secondHost
        ))
        await stopAndAdvance(controller)
        let waveform = try XCTUnwrap(engine.finalizedSamples)

        XCTAssertEqual(waveform.count, 32_000)
        XCTAssertTrue(waveform.prefix(16_000).allSatisfy { abs($0 - 0.4) < 0.0001 })
        XCTAssertTrue(waveform.suffix(16_000).allSatisfy { abs($0 - 0.2) < 0.0001 })
    }

    func test_controllerDrainsConverterTailIntoExactFinalWaveform() async throws {
        let capture = LifecycleCaptureSession()
        let engine = WaveformTestEngine()
        let controller = TranscriptionController(engine: engine, captureSession: capture, scheduler: scheduler)
        try await controller.start(mode: .micOnly)
        let host = AudioConvertNanosToHostTime(1_000_000_000)
        capture.microphoneCallbacks[0](capture.microphoneSessionIDs[0], AudioCaptureFrame(
            samples: [Float](repeating: 0.25, count: 160), sampleRate: 16_000, firstSampleHostTime: host
        ))
        await stopAndAdvance(controller)
        let waveform = try XCTUnwrap(engine.finalizedSamples)
        XCTAssertEqual(waveform.count, 160)
        XCTAssertTrue(waveform.allSatisfy { abs($0 - 0.25) < 0.0001 })
    }

    func test_appAudioFailureFallsBackToMicOnlyWithoutStoppingMicrophone() async throws {
        let captureSession = LifecycleCaptureSession()
        let controller = TranscriptionController(
            engine: LifecycleTestEngine(),
            captureSession: captureSession,
            scheduler: scheduler
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
        XCTAssertEqual(captureSession.microphoneCallbacks.count, 1)
    }

    private func makeAppSampleBuffer(
        frameCount: Int,
        sampleRate: Double = 16_000,
        samples: [Float]? = nil,
        presentationTimeStamp: CMTime = .zero
    ) throws -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
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
            duration: CMTime(value: 1, timescale: Int32(sampleRate)),
            presentationTimeStamp: presentationTimeStamp,
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
        var samples = samples ?? [Float](repeating: 0.25, count: frameCount)
        XCTAssertEqual(samples.count, frameCount)
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
    private(set) var microphoneCallbacks: [(@Sendable (UUID, AudioCaptureFrame) -> Void)] = []
    private(set) var appCallbacks: [(@Sendable (UUID, CMSampleBuffer) -> Void)] = []
    private(set) var errorCallbacks: [(@Sendable (UUID, Error) -> Void)] = []
    private(set) var sessionIDs: [UUID] = []
    private(set) var microphoneSessionIDs: [UUID] = []
    private(set) var appSessionIDs: [UUID] = []
    private(set) var microphoneStartCount = 0
    private(set) var stopCount = 0
    private(set) var stopAppAudioCount = 0

    func startMicrophone(
        sessionID: UUID,
        callback: @escaping @Sendable (UUID, AudioCaptureFrame) -> Void
    ) throws {
        microphoneStartCount += 1
        sessionIDs.append(sessionID)
        microphoneSessionIDs.append(sessionID)
        microphoneCallbacks.append(callback)
    }

    func startAppAudio(
        sessionID: UUID,
        source: AppPickerWindowController.AudioSource,
        callback: @escaping @Sendable (UUID, CMSampleBuffer) -> Void,
        errorCallback: @escaping @Sendable (UUID, Error) -> Void
    ) async throws {
        sessionIDs.append(sessionID)
        appSessionIDs.append(sessionID)
        appCallbacks.append(callback)
        errorCallbacks.append(errorCallback)
    }

    func stop() {
        stopCount += 1
    }

    func stopAppAudio() {
        stopAppAudioCount += 1
    }

    func triggerAppAudioError(at index: Int = -1) {
        let callbackIndex = index >= 0 ? index : errorCallbacks.count - 1
        guard errorCallbacks.indices.contains(callbackIndex) else { return }
        errorCallbacks[callbackIndex](sessionIDs[callbackIndex], NSError(domain: "LifecycleCaptureSession", code: 1))
    }
}

private final class WaveformTestEngine: @unchecked Sendable, ASREngine {
    let provider: ASRProvider = .whisper
    private let lock = OSAllocatedUnfairLock(initialState: Optional<[Float]>.none)

    var finalizedSamples: [Float]? {
        lock.withLock { $0 }
    }

    func prepare() async throws {}
    func reset() async {}
    func process(_ buffer: AVAudioPCMBuffer, language: String?) async throws -> ASRPartial? { nil }
    func finalize(_ buffer: AVAudioPCMBuffer, language: String?) async throws -> ASRFinalSegment? {
        guard let channel = buffer.floatChannelData?[0] else { return nil }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        lock.withLock { $0 = samples }
        return nil
    }
}

private final class LifecycleTestEngine: @unchecked Sendable, ASREngine {
    let provider: ASRProvider = .whisper
    private let finalizedFrameCountsLock = OSAllocatedUnfairLock(initialState: [Int]())
    private let processedFrameCountsLock = OSAllocatedUnfairLock(initialState: [Int]())

    var finalizedFrameCounts: [Int] {
        finalizedFrameCountsLock.withLock { $0 }
    }

    var processedFrameCounts: [Int] {
        processedFrameCountsLock.withLock { $0 }
    }

    func prepare() async throws {}
    func reset() async {}
    func process(_ buffer: AVAudioPCMBuffer, language: String?) async throws -> ASRPartial? {
        processedFrameCountsLock.withLock { counts in
            counts.append(Int(buffer.frameLength))
        }
        return nil
    }
    func finalize(_ buffer: AVAudioPCMBuffer, language: String?) async throws -> ASRFinalSegment? {
        finalizedFrameCountsLock.withLock { counts in
            counts.append(Int(buffer.frameLength))
        }
        return nil
    }
}
