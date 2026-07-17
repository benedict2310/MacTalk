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
