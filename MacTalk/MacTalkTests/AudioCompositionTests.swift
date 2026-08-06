import XCTest
@preconcurrency import CoreMedia
@testable import MacTalk

final class AudioCompositionTests: XCTestCase {
    private let epoch = AudioHostTimestamp(nanoseconds: 10_000_000_000)

    private func chunk(_ source: AudioCompositionSource, frame: Int, values: [Float]) -> TimedAudioChunk {
        TimedAudioChunk(
            source: source,
            start: AudioHostTimestamp(nanoseconds: epoch.nanoseconds + Int64(frame) * 62_500),
            samples: values
        )
    }

    private func compose(
        _ chunks: [TimedAudioChunk],
        mode: AudioCompositionMode = .microphoneAndApplication
    ) -> [Float] {
        let session = UUID()
        var composer = AudioTimelineComposer()
        composer.reset(sessionID: session, mode: mode)
        var result: [Float] = []
        for item in chunks { result += composer.ingest(sessionID: session, chunk: item) }
        result += composer.finish(sessionID: session)
        return result
    }

    func test_simultaneousOneSecondProducesExactly16000Frames() {
        let mic = chunk(.microphone, frame: 0, values: [Float](repeating: 0.2, count: 16_000))
        let app = chunk(.application, frame: 0, values: [Float](repeating: 0.6, count: 16_000))
        XCTAssertEqual(compose([mic, app]).count, 16_000)
    }

    func test_crossSourceOrderWithinLatenessWindowDoesNotChangeWaveform() {
        var first: [TimedAudioChunk] = []
        var second: [TimedAudioChunk] = []
        for frame in stride(from: 0, to: 16_000, by: 1_000) {
            let mic = chunk(.microphone, frame: frame, values: [Float](repeating: 0.2, count: 1_000))
            let app = chunk(.application, frame: frame, values: [Float](repeating: 0.6, count: 1_000))
            first += [mic, app]
            second += [app, mic]
        }
        XCTAssertEqual(compose(first), compose(second))
    }

    func test_arbitraryFiveThousandFrameCallbacksAreOrderIndependent() {
        let mic = chunk(.microphone, frame: 0, values: [Float](repeating: 0.2, count: 5_000))
        let app = chunk(.application, frame: 0, values: [Float](repeating: 0.6, count: 5_000))
        let micFirst = compose([mic, app])
        let appFirst = compose([app, mic])
        XCTAssertEqual(micFirst, appFirst)
        XCTAssertEqual(micFirst.count, 5_000)
        XCTAssertEqual(micFirst[2_500], 0.4, accuracy: 0.0001)
    }

    func test_appBeforeFirstMicIsBufferedAndMicDefinesFrameZero() {
        let session = UUID()
        var composer = AudioTimelineComposer()
        composer.reset(sessionID: session, mode: .microphoneAndApplication)
        XCTAssertTrue(composer.ingest(sessionID: session, chunk: chunk(.application, frame: 0, values: [0.5, 0.5])).isEmpty)
        XCTAssertFalse(composer.hasMicrophoneAnchor)
        _ = composer.ingest(sessionID: session, chunk: chunk(.microphone, frame: 0, values: [0.2, 0.2]))
        XCTAssertTrue(composer.hasMicrophoneAnchor)
    }

    func test_knownTimestampOffsetPlacesImpulsesAtExpectedFrames() {
        var microphone = [Float](repeating: 0, count: 201)
        microphone[100] = 1
        let output = compose([
            chunk(.microphone, frame: 0, values: microphone),
            chunk(.application, frame: 800, values: [1])
        ])
        XCTAssertEqual(output.count, 801)
        XCTAssertEqual(output[100], 1, accuracy: 0.0001)
        XCTAssertEqual(output[800], 1, accuracy: 0.0001)
    }

    func test_twoFullScaleSourcesPeakAtOneWithoutClipping() {
        let output = compose([
            chunk(.microphone, frame: 0, values: [Float](repeating: 1, count: 100)),
            chunk(.application, frame: 0, values: [Float](repeating: 1, count: 100))
        ])
        XCTAssertEqual(output.max(), 1)
        XCTAssertEqual(output.min(), 1)
        XCTAssertTrue(output.allSatisfy(\.isFinite))
    }

    func test_twoNegativeFullScaleSourcesReachNegativeMinimumWithoutClipping() {
        let output = compose([
            chunk(.microphone, frame: 0, values: [Float](repeating: -1, count: 100)),
            chunk(.application, frame: 0, values: [Float](repeating: -1, count: 100))
        ])
        XCTAssertEqual(output.min(), -1)
        XCTAssertEqual(output.max(), -1)
        XCTAssertTrue(output.allSatisfy(\.isFinite))
    }

    func test_singlePresentSourceUsesUnityGainAndMissingSourceZeroFills() {
        let output = compose([chunk(.microphone, frame: 0, values: [0.8, 0.8, 0.8])])
        XCTAssertEqual(output, [0.8, 0.8, 0.8])
    }

    func test_missingAppAdvancesAfter250msBound() {
        let output = compose([chunk(.microphone, frame: 0, values: [Float](repeating: 0.4, count: 8_000))])
        XCTAssertEqual(output.count, 8_000)
        XCTAssertEqual(output[0], 0.4, accuracy: 0.001)
    }

    func test_farFutureApplicationDoesNotAdvancePastBufferedMicrophoneOnExpiry() {
        let session = UUID()
        var composer = AudioTimelineComposer()
        composer.reset(sessionID: session, mode: .microphoneAndApplication)
        _ = composer.ingest(sessionID: session, chunk: chunk(
            .microphone,
            frame: 0,
            values: [Float](repeating: 0.25, count: 500)
        ))
        _ = composer.ingest(sessionID: session, chunk: chunk(
            .application,
            frame: 100_000,
            values: [0.75]
        ))

        let output = composer.expire(sessionID: session)
        XCTAssertEqual(output.count, 4_501)
        XCTAssertEqual(Array(output.prefix(500)), [Float](repeating: 0.25, count: 500))
        XCTAssertTrue(output[500..<4_500].allSatisfy { abs($0) < 0.0001 })
        XCTAssertEqual(output[4_500], 0.75, accuracy: 0.0001)
        XCTAssertGreaterThan(composer.metrics.discontinuitiesElided, 90_000)
        XCTAssertLessThanOrEqual(composer.bufferedFrameCount, 16_000)
    }

    func test_farFutureMicrophoneDoesNotAdvancePastBufferedApplicationOnExpiry() {
        let session = UUID()
        var composer = AudioTimelineComposer()
        composer.reset(sessionID: session, mode: .microphoneAndApplication)
        _ = composer.ingest(sessionID: session, chunk: chunk(
            .microphone,
            frame: 0,
            values: [0.25]
        ))
        _ = composer.ingest(sessionID: session, chunk: chunk(
            .application,
            frame: 0,
            values: [Float](repeating: 0.75, count: 500)
        ))
        _ = composer.ingest(sessionID: session, chunk: chunk(
            .microphone,
            frame: 100_000,
            values: [0.25]
        ))

        let output = composer.expire(sessionID: session)
        XCTAssertEqual(output.count, 4_501)
        XCTAssertEqual(output[0], 0.5, accuracy: 0.0001)
        XCTAssertEqual(Array(output[1..<500]), [Float](repeating: 0.75, count: 499))
        XCTAssertTrue(output[500..<4_500].allSatisfy { abs($0) < 0.0001 })
        XCTAssertEqual(output[4_500], 0.25, accuracy: 0.0001)
        XCTAssertGreaterThan(composer.metrics.discontinuitiesElided, 90_000)
        XCTAssertLessThanOrEqual(composer.bufferedFrameCount, 16_000)
    }

    func test_farFutureApplicationFinishPreservesBufferedMicrophoneCoverage() {
        let session = UUID()
        var composer = AudioTimelineComposer()
        composer.reset(sessionID: session, mode: .microphoneAndApplication)
        _ = composer.ingest(sessionID: session, chunk: chunk(
            .microphone,
            frame: 0,
            values: [Float](repeating: 0.25, count: 500)
        ))
        _ = composer.ingest(sessionID: session, chunk: chunk(
            .application,
            frame: 100_000,
            values: [0.75]
        ))

        let output = composer.finish(sessionID: session)
        XCTAssertEqual(output.count, 4_501)
        XCTAssertEqual(Array(output.prefix(500)), [Float](repeating: 0.25, count: 500))
        XCTAssertTrue(output[500..<4_500].allSatisfy { abs($0) < 0.0001 })
        XCTAssertEqual(output[4_500], 0.75, accuracy: 0.0001)
    }

    func test_farFutureApplicationFallbackFlushPreservesBufferedMicrophoneCoverage() {
        let session = UUID()
        var composer = AudioTimelineComposer()
        composer.reset(sessionID: session, mode: .microphoneAndApplication)
        _ = composer.ingest(sessionID: session, chunk: chunk(
            .microphone,
            frame: 0,
            values: [Float](repeating: 0.25, count: 500)
        ))
        _ = composer.ingest(sessionID: session, chunk: chunk(
            .application,
            frame: 100_000,
            values: [0.75]
        ))

        let output = composer.deactivateApplication(sessionID: session)
        XCTAssertEqual(output.count, 4_501)
        XCTAssertEqual(Array(output.prefix(500)), [Float](repeating: 0.25, count: 500))
        XCTAssertEqual(output[4_500], 0.75, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(composer.bufferedFrameCount, 16_000)
    }

    func test_lateChunkOlderThanOutputCursorIsDropped() {
        let session = UUID()
        var composer = AudioTimelineComposer(configuration: .init(maximumLatenessFrames: 0))
        composer.reset(sessionID: session, mode: .microphoneOnly)
        _ = composer.ingest(sessionID: session, chunk: chunk(.microphone, frame: 0, values: [0.2, 0.2]))
        _ = composer.ingest(sessionID: session, chunk: chunk(.microphone, frame: 0, values: [0.9, 0.9]))
        XCTAssertGreaterThan(composer.metrics.lateFramesDropped, 0)
    }

    func test_oneFrameTimestampJitterSnapsWithoutGapOrDuplicate() {
        let session = UUID()
        var composer = AudioTimelineComposer()
        composer.reset(sessionID: session, mode: .microphoneOnly)
        var result = composer.ingest(sessionID: session, chunk: chunk(.microphone, frame: 0, values: [0.1]))
        result += composer.ingest(sessionID: session, chunk: TimedAudioChunk(
            source: .microphone,
            start: AudioHostTimestamp(nanoseconds: epoch.nanoseconds + 62_501),
            samples: [0.2]
        ))
        result += composer.finish(sessionID: session)
        XCTAssertEqual(result.count, 2)
    }

    func test_clockDriftCreatesBoundedFrameCorrections() {
        let session = UUID()
        var composer = AudioTimelineComposer()
        composer.reset(sessionID: session, mode: .microphoneOnly)
        var output: [Float] = []
        for index in 0..<20 {
            let frame = index * 800
            let driftedNanos = epoch.nanoseconds + Int64(frame) * 62_503
            output += composer.ingest(sessionID: session, chunk: TimedAudioChunk(
                source: .microphone,
                start: AudioHostTimestamp(nanoseconds: driftedNanos),
                samples: [Float](repeating: 0.2, count: 800)
            ))
        }
        output += composer.finish(sessionID: session)
        XCTAssertLessThanOrEqual(abs(output.count - 16_000), 2)
        XCTAssertLessThanOrEqual(composer.bufferedFrameCount, 16_000)
    }

    func test_largeDiscontinuityIsElidedWithoutUnboundedSilence() {
        let session = UUID()
        var composer = AudioTimelineComposer()
        composer.reset(sessionID: session, mode: .microphoneOnly)
        _ = composer.ingest(sessionID: session, chunk: chunk(.microphone, frame: 0, values: [0.1]))
        _ = composer.ingest(sessionID: session, chunk: chunk(.microphone, frame: 100_000, values: [0.2]))
        XCTAssertGreaterThan(composer.metrics.discontinuitiesElided, 0)
        XCTAssertLessThanOrEqual(composer.bufferedFrameCount, 16_000)
    }

    func test_fallbackFlushesDualTimelineThenContinuesMicOnlyWithoutGapOrDuplicate() {
        let session = UUID()
        var composer = AudioTimelineComposer()
        composer.reset(sessionID: session, mode: .microphoneAndApplication)
        var output = composer.ingest(sessionID: session, chunk: chunk(.microphone, frame: 0, values: [Float](repeating: 0.2, count: 8_000)))
        output += composer.ingest(sessionID: session, chunk: chunk(.application, frame: 0, values: [Float](repeating: 0.6, count: 8_000)))
        output += composer.deactivateApplication(sessionID: session)
        output += composer.ingest(sessionID: session, chunk: chunk(.microphone, frame: 8_000, values: [Float](repeating: 0.2, count: 8_000)))
        output += composer.finish(sessionID: session)
        XCTAssertEqual(output.count, 16_000)
        XCTAssertEqual(output.last ?? -1, 0.2, accuracy: 0.001)
    }

    func test_cancelAndResetRejectOldSessionChunks() {
        let oldSession = UUID()
        let newSession = UUID()
        var composer = AudioTimelineComposer()
        composer.reset(sessionID: oldSession, mode: .microphoneOnly)
        composer.cancel(sessionID: oldSession)
        composer.reset(sessionID: newSession, mode: .microphoneOnly)
        XCTAssertTrue(composer.ingest(
            sessionID: oldSession,
            chunk: chunk(.microphone, frame: 0, values: [1])
        ).isEmpty)
        XCTAssertFalse(composer.ingest(
            sessionID: newSession,
            chunk: chunk(.microphone, frame: 0, values: [0.2])
        ).isEmpty)
    }

    func test_finishDrainsLastLatenessWindowExactlyOnce() {
        let session = UUID()
        var composer = AudioTimelineComposer()
        composer.reset(sessionID: session, mode: .microphoneOnly)
        var output = composer.ingest(sessionID: session, chunk: chunk(.microphone, frame: 0, values: [0.2, 0.3]))
        output += composer.ingestTail(sessionID: session, source: .microphone, samples: [0.4])
        output += composer.finish(sessionID: session)
        XCTAssertEqual(output, [0.2, 0.3, 0.4])
        XCTAssertTrue(composer.finish(sessionID: session).isEmpty)
    }

    func test_microphoneTailFollowsElidedDiscontinuityExactlyOnce() {
        let session = UUID()
        var composer = AudioTimelineComposer()
        composer.reset(sessionID: session, mode: .microphoneOnly)
        var output = composer.ingest(sessionID: session, chunk: chunk(
            .microphone,
            frame: 0,
            values: [0.1, 0.1]
        ))
        output += composer.ingest(sessionID: session, chunk: chunk(
            .microphone,
            frame: 100_000,
            values: [0.2]
        ))
        output += composer.ingestTail(sessionID: session, source: .microphone, samples: [0.3])
        output += composer.finish(sessionID: session)

        XCTAssertEqual(output.count, 4_004)
        XCTAssertEqual(output[0..<2], [0.1, 0.1])
        XCTAssertTrue(output[2..<4_002].allSatisfy { abs($0) < 0.0001 })
        XCTAssertEqual(output[4_002], 0.2, accuracy: 0.0001)
        XCTAssertEqual(output[4_003], 0.3, accuracy: 0.0001)
    }

    func test_applicationTailFollowsElidedDiscontinuityThroughFallbackExactlyOnce() {
        let session = UUID()
        var composer = AudioTimelineComposer()
        composer.reset(sessionID: session, mode: .microphoneAndApplication)
        var output = composer.ingest(sessionID: session, chunk: chunk(
            .microphone,
            frame: 0,
            values: [0.1, 0.1]
        ))
        output += composer.ingest(sessionID: session, chunk: chunk(
            .application,
            frame: 0,
            values: [0.2, 0.2]
        ))
        _ = composer.ingest(sessionID: session, chunk: chunk(
            .application,
            frame: 100_000,
            values: [0.4]
        ))
        _ = composer.ingestTail(sessionID: session, source: .application, samples: [0.5])
        output += composer.deactivateApplication(sessionID: session)

        XCTAssertEqual(output.count, 4_004)
        XCTAssertEqual(output[0..<2], [0.15, 0.15])
        XCTAssertTrue(output[2..<4_002].allSatisfy { abs($0) < 0.0001 })
        XCTAssertEqual(output[4_002], 0.4, accuracy: 0.0001)
        XCTAssertEqual(output[4_003], 0.5, accuracy: 0.0001)
    }

    func test_finishIsExactlyOnceAndResetRejectsOldSession() {
        let first = UUID()
        let second = UUID()
        var composer = AudioTimelineComposer()
        composer.reset(sessionID: first, mode: .microphoneOnly)
        var output = composer.ingest(sessionID: first, chunk: chunk(.microphone, frame: 0, values: [0.4]))
        output += composer.finish(sessionID: first)
        XCTAssertEqual(output.count, 1)
        XCTAssertTrue(composer.finish(sessionID: first).isEmpty)
        composer.reset(sessionID: second, mode: .microphoneOnly)
        XCTAssertTrue(composer.ingest(sessionID: first, chunk: chunk(.microphone, frame: 0, values: [1])).isEmpty)
    }

    func test_serialPipelineEmitsInCallbackOrderAndRejectsOldSession() {
        let first = UUID()
        let second = UUID()
        let emissions = CompositionEmissionBox()
        let pipeline = SerializedAudioCompositionPipeline(emit: { session, samples in
            emissions.append(session: session, samples: samples)
        })
        pipeline.reset(sessionID: first, mode: .microphoneOnly)
        pipeline.ingest(sessionID: first, chunk: chunk(.microphone, frame: 0, values: [0.1]))
        emissions.removeAll()
        pipeline.reset(sessionID: second, mode: .microphoneOnly)
        pipeline.ingest(sessionID: first, chunk: chunk(.microphone, frame: 0, values: [0.9]))
        pipeline.ingest(sessionID: second, chunk: chunk(.microphone, frame: 0, values: [0.2]))
        pipeline.finish(sessionID: second)
        XCTAssertTrue(emissions.value.allSatisfy { $0.0 == second })
        XCTAssertEqual(emissions.value.flatMap(\.1), [0.2])
    }

    func test_nonFiniteSamplesBecomeZeroAndOutOfRangeSamplesClamp() {
        let session = UUID()
        var composer = AudioTimelineComposer()
        composer.reset(sessionID: session, mode: .microphoneOnly)
        let output = composer.ingest(sessionID: session, chunk: chunk(.microphone, frame: 0, values: [.nan, 2, -2])) + composer.finish(sessionID: session)
        XCTAssertEqual(output, [0, 1, -1])
        XCTAssertEqual(composer.metrics.nonFiniteSamplesReplaced, 1)
        XCTAssertEqual(composer.metrics.clippedSamples, 2)
    }

    func test_screenAudioPTSConvertsToExpectedHostNanoseconds() {
        XCTAssertEqual(
            AudioHostTimestamp(presentationTimeStamp: CMTime(value: 123, timescale: 1_000)).map(\.nanoseconds),
            123_000_000
        )
    }

    func test_invalidOrIndefiniteScreenAudioPTSIsRejected() {
        XCTAssertNil(AudioHostTimestamp(presentationTimeStamp: .invalid))
        XCTAssertNil(AudioHostTimestamp(presentationTimeStamp: .indefinite))
    }

    func test_preAnchorAppBufferIsBounded() {
        let session = UUID()
        var composer = AudioTimelineComposer()
        composer.reset(sessionID: session, mode: .microphoneAndApplication)
        _ = composer.ingest(sessionID: session, chunk: chunk(.application, frame: 0, values: [Float](repeating: 0.1, count: 20_000)))
        XCTAssertEqual(composer.metrics.preAnchorFramesDropped, 4_000)
    }

    func test_bufferedOverlapKeepsFirstAcceptedSamplesAndDoesNotRewindExpectedStart() {
        let session = UUID()
        var composer = AudioTimelineComposer()
        composer.reset(sessionID: session, mode: .microphoneAndApplication)
        var output = composer.ingest(sessionID: session, chunk: chunk(.microphone, frame: 0, values: [Float](repeating: 0.2, count: 8_000)))
        output += composer.ingest(sessionID: session, chunk: chunk(.application, frame: 0, values: [Float](repeating: 0.4, count: 8_000)))
        output += composer.ingest(sessionID: session, chunk: chunk(.microphone, frame: 5_000, values: [Float](repeating: 0.8, count: 1_000)))
        output += composer.finish(sessionID: session)
        XCTAssertEqual(output.count, 8_000)
        XCTAssertEqual(output[5_500], 0.3, accuracy: 0.0001)
        XCTAssertGreaterThan(composer.metrics.bufferedOverlapFramesDropped, 0)
    }

    func test_oversizedChunkNeverExceedsInsertionOrEmissionBound() {
        let session = UUID()
        let configuration = AudioCompositionConfiguration(
            maximumLatenessFrames: 64,
            maximumBufferedFrames: 256,
            maximumZeroFillFrames: 64
        )
        var composer = AudioTimelineComposer(configuration: configuration)
        composer.reset(sessionID: session, mode: .microphoneOnly)
        let output = composer.ingest(
            sessionID: session,
            chunk: chunk(.microphone, frame: 0, values: [Float](repeating: 0.25, count: 100_000))
        )
        XCTAssertLessThanOrEqual(output.count, 256)
        XCTAssertLessThanOrEqual(composer.bufferedFrameCount, 256)
    }

    func test_invalidTimestampMetricsAreExplicitPerSource() {
        let session = UUID()
        var composer = AudioTimelineComposer()
        composer.reset(sessionID: session, mode: .microphoneAndApplication)
        composer.recordInvalidTimestamp(sessionID: session, source: .microphone)
        composer.recordInvalidTimestamp(sessionID: session, source: .application)
        XCTAssertEqual(composer.metrics.invalidMicrophoneTimestamps, 1)
        XCTAssertEqual(composer.metrics.invalidApplicationTimestamps, 1)
    }

    func test_composerTickExpiresMissingCounterpartWithoutChangingMediaMapping() {
        let session = UUID()
        var composer = AudioTimelineComposer()
        composer.reset(sessionID: session, mode: .microphoneAndApplication)
        _ = composer.ingest(
            sessionID: session,
            chunk: TimedAudioChunk(
                source: .microphone,
                start: epoch,
                samples: [Float](repeating: 0.25, count: 500)
            )
        )
        XCTAssertTrue(composer.ingest(
            sessionID: session,
            chunk: TimedAudioChunk(
                source: .application,
                start: AudioHostTimestamp(nanoseconds: epoch.nanoseconds + 31_250_000),
                samples: [0.75]
            )
        ).isEmpty)
        let output = composer.tick(sessionID: session)
        XCTAssertEqual(output.count, 501)
        XCTAssertEqual(output[0], 0.25, accuracy: 0.0001)
        XCTAssertEqual(output[500], 0.75, accuracy: 0.0001)
    }

    func test_pipelineCounterpartBackToBackEitherOrderCancelsExpiryAndPreservesWaveform() {
        let clock = ManualArrivalClock()
        let scheduler = ManualCompositionScheduler(clock: clock)
        let firstEmissions = CompositionEmissionBox()
        let secondEmissions = CompositionEmissionBox()
        let first = UUID()
        let second = UUID()
        let firstPipeline = makePipeline(clock: clock, scheduler: scheduler, emissions: firstEmissions)
        firstPipeline.reset(sessionID: first, mode: .microphoneAndApplication)
        firstPipeline.ingest(sessionID: first, chunk: chunk(.microphone, frame: 0, values: [Float](repeating: 0.2, count: 5_000)))
        firstPipeline.ingest(sessionID: first, chunk: chunk(.application, frame: 0, values: [Float](repeating: 0.6, count: 5_000)))
        firstPipeline.finish(sessionID: first)

        let secondScheduler = ManualCompositionScheduler(clock: clock)
        let secondPipeline = makePipeline(clock: clock, scheduler: secondScheduler, emissions: secondEmissions)
        secondPipeline.reset(sessionID: second, mode: .microphoneAndApplication)
        secondPipeline.ingest(sessionID: second, chunk: chunk(.application, frame: 0, values: [Float](repeating: 0.6, count: 5_000)))
        secondPipeline.ingest(sessionID: second, chunk: chunk(.microphone, frame: 0, values: [Float](repeating: 0.2, count: 5_000)))
        secondPipeline.finish(sessionID: second)

        XCTAssertEqual(scheduler.activeCount, 0)
        XCTAssertEqual(secondScheduler.activeCount, 0)
        XCTAssertEqual(firstEmissions.value.flatMap(\.1), secondEmissions.value.flatMap(\.1))
        XCTAssertEqual(firstEmissions.value.flatMap(\.1).count, 5_000)
        XCTAssertEqual(firstEmissions.value.flatMap(\.1)[2_500], 0.4, accuracy: 0.0001)
    }

    func test_pipelineMissingApplicationWaitsUntil249MillisecondsAndExpiresAt250() {
        let clock = ManualArrivalClock()
        let scheduler = ManualCompositionScheduler(clock: clock)
        let emissions = CompositionEmissionBox()
        let pipeline = makePipeline(clock: clock, scheduler: scheduler, emissions: emissions)
        let session = UUID()
        pipeline.reset(sessionID: session, mode: .microphoneAndApplication)
        pipeline.ingest(sessionID: session, chunk: chunk(.microphone, frame: 0, values: [Float](repeating: 0.4, count: 5_000)))

        clock.advance(nanoseconds: 249_000_000)
        scheduler.fireDue()
        XCTAssertTrue(emissions.value.isEmpty)
        clock.advance(nanoseconds: 1_000_000)
        scheduler.fireDue()
        XCTAssertEqual(emissions.value.flatMap(\.1).count, 5_000)
        XCTAssertTrue(emissions.value.flatMap(\.1).allSatisfy { abs($0 - 0.4) < 0.0001 })
    }

    func test_pipelineKeepsAtMostOneExpiryQueuedAndStalledApplicationDoesNotStopMic() {
        let clock = ManualArrivalClock()
        let scheduler = ManualCompositionScheduler(clock: clock)
        let emissions = CompositionEmissionBox()
        let pipeline = makePipeline(clock: clock, scheduler: scheduler, emissions: emissions)
        let session = UUID()
        pipeline.reset(sessionID: session, mode: .microphoneAndApplication)
        pipeline.ingest(sessionID: session, chunk: chunk(.microphone, frame: 0, values: [Float](repeating: 0.2, count: 1_000)))
        XCTAssertEqual(scheduler.activeCount, 1)
        pipeline.ingest(sessionID: session, chunk: chunk(.microphone, frame: 1_000, values: [Float](repeating: 0.2, count: 1_000)))
        XCTAssertEqual(scheduler.activeCount, 1)

        clock.advance(nanoseconds: 250_000_000)
        scheduler.fireDue()
        XCTAssertEqual(emissions.value.flatMap(\.1).count, 2_000)
        XCTAssertLessThanOrEqual(scheduler.activeCount, 1)

        pipeline.ingest(sessionID: session, chunk: chunk(.microphone, frame: 2_000, values: [Float](repeating: 0.2, count: 1_000)))
        XCTAssertEqual(scheduler.activeCount, 1)
        clock.advance(nanoseconds: 250_000_000)
        scheduler.fireDue()
        XCTAssertEqual(emissions.value.flatMap(\.1).count, 3_000)
        XCTAssertLessThanOrEqual(scheduler.activeCount, 1)
    }

    private func makePipeline(
        clock: ManualArrivalClock,
        scheduler: ManualCompositionScheduler,
        emissions: CompositionEmissionBox
    ) -> SerializedAudioCompositionPipeline {
        SerializedAudioCompositionPipeline(
            arrivalClock: { clock.nowNanoseconds },
            scheduler: scheduler,
            emit: { session, samples in emissions.append(session: session, samples: samples) }
        )
    }
}

private final class CompositionEmissionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(UUID, [Float])] = []

    var value: [(UUID, [Float])] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func append(session: UUID, samples: [Float]) {
        lock.lock(); storage.append((session, samples)); lock.unlock()
    }

    func removeAll() {
        lock.lock(); storage.removeAll(); lock.unlock()
    }
}

private final class ManualArrivalClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    var nowNanoseconds: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func advance(nanoseconds: UInt64) {
        lock.lock(); value += nanoseconds; lock.unlock()
    }
}

private final class ManualCompositionScheduler: AudioCompositionScheduler, @unchecked Sendable {
    private final class Entry: @unchecked Sendable {
        let deadline: UInt64
        let operation: @Sendable () -> Void
        var cancelled = false

        init(deadline: UInt64, operation: @escaping @Sendable () -> Void) {
            self.deadline = deadline
            self.operation = operation
        }
    }

    private final class Token: AudioCompositionScheduledTask, @unchecked Sendable {
        private weak var owner: ManualCompositionScheduler?
        private let entry: Entry

        init(owner: ManualCompositionScheduler, entry: Entry) {
            self.owner = owner
            self.entry = entry
        }

        func cancel() {
            owner?.cancel(entry)
        }
    }

    private let clock: ManualArrivalClock
    private let lock = NSLock()
    private var entries: [Entry] = []

    init(clock: ManualArrivalClock) {
        self.clock = clock
    }

    var activeCount: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.filter { !$0.cancelled }.count
    }

    func schedule(
        deadlineNanoseconds: UInt64,
        operation: @escaping @Sendable () -> Void
    ) -> any AudioCompositionScheduledTask {
        let entry = Entry(deadline: deadlineNanoseconds, operation: operation)
        lock.lock(); entries.append(entry); lock.unlock()
        return Token(owner: self, entry: entry)
    }

    func fireDue() {
        while true {
            let entry: Entry? = {
                lock.lock(); defer { lock.unlock() }
                guard let index = entries.firstIndex(where: { !$0.cancelled && $0.deadline <= clock.nowNanoseconds }) else {
                    return nil
                }
                let result = entries[index]
                entries.remove(at: index)
                return result
            }()
            guard let entry else { return }
            entry.operation()
        }
    }

    private func cancel(_ entry: Entry) {
        lock.lock(); entry.cancelled = true; lock.unlock()
    }
}
