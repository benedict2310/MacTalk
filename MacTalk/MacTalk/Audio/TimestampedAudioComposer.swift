//
//  TimestampedAudioComposer.swift
//  MacTalk
//
//  Deterministic timestamp-aligned composition of already-resampled audio.
//

import Foundation

/// A Core Audio host timestamp represented without floating point arithmetic.
struct AudioHostTimestamp: Sendable, Comparable, Equatable, Hashable {
    let nanoseconds: Int64

    init(nanoseconds: Int64) {
        self.nanoseconds = nanoseconds
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.nanoseconds < rhs.nanoseconds
    }

    /// Converts a host timestamp delta to a 16 kHz frame index using signed,
    /// round-to-nearest integer arithmetic.
    func frameOffset(from epoch: Self, sampleRate: Int = 16_000) -> Int {
        let delta = nanoseconds - epoch.nanoseconds
        let numerator = delta.multipliedReportingOverflow(by: Int64(sampleRate))
        guard !numerator.overflow else {
            return delta < 0 ? Int.min : Int.max
        }
        return AudioTimelineComposer.roundedQuotient(numerator.partialValue, denominator: 1_000_000_000)
    }
}

enum AudioCompositionSource: Sendable, Equatable {
    case microphone
    case application
}

enum AudioCompositionMode: Sendable, Equatable {
    case microphoneOnly
    case microphoneAndApplication
}

struct TimedAudioChunk: Sendable, Equatable {
    let source: AudioCompositionSource
    let start: AudioHostTimestamp
    let samples: [Float]

    init(source: AudioCompositionSource, start: AudioHostTimestamp, samples: [Float]) {
        self.source = source
        self.start = start
        self.samples = samples
    }
}

struct AudioCompositionConfiguration: Sendable, Equatable {
    let sampleRate: Int
    let maximumLatenessFrames: Int
    let maximumBufferedFrames: Int
    let maximumZeroFillFrames: Int
    let timestampSnapFrames: Int

    init(
        sampleRate: Int = 16_000,
        maximumLatenessFrames: Int = 4_000,
        maximumBufferedFrames: Int = 16_000,
        maximumZeroFillFrames: Int = 4_000,
        timestampSnapFrames: Int = 1
    ) {
        precondition(sampleRate > 0)
        precondition(maximumLatenessFrames >= 0)
        precondition(maximumBufferedFrames > 0)
        precondition(maximumZeroFillFrames >= 0)
        precondition(timestampSnapFrames >= 0)
        self.sampleRate = sampleRate
        self.maximumLatenessFrames = maximumLatenessFrames
        self.maximumBufferedFrames = maximumBufferedFrames
        self.maximumZeroFillFrames = maximumZeroFillFrames
        self.timestampSnapFrames = timestampSnapFrames
    }
}

struct AudioCompositionMetrics: Sendable, Equatable {
    var lateFramesDropped = 0
    var preAnchorFramesDropped = 0
    var discontinuitiesElided = 0
    var nonFiniteSamplesReplaced = 0
    var clippedSamples = 0
}

/// A bounded, synchronous timestamp composer. It has no AVFoundation or
/// callback dependencies, which makes the media timeline independently
/// testable and keeps all conversion/composition work off the render thread.
struct AudioTimelineComposer: Sendable {
    private struct SourceState: Sendable {
        var samples: [Int: Float] = [:]
        var latestPlacedEnd: Int?
        var latestObservedEnd: Int?
        var expectedNextStart: Int?
        var hasInput = false
    }

    private var sessionID: UUID?
    private var mode: AudioCompositionMode = .microphoneOnly
    private var epoch: AudioHostTimestamp?
    private var outputCursor = 0
    private var sources: [AudioCompositionSource: SourceState] = [
        .microphone: SourceState(), .application: SourceState()
    ]
    private var preAnchorApplication: [TimedAudioChunk] = []
    private var preAnchorFrames = 0
    private var _metrics = AudioCompositionMetrics()
    private let configuration: AudioCompositionConfiguration

    init(configuration: AudioCompositionConfiguration = AudioCompositionConfiguration()) {
        self.configuration = configuration
    }

    var metrics: AudioCompositionMetrics { _metrics }
    var hasMicrophoneAnchor: Bool { epoch != nil }
    var bufferedFrameCount: Int { sources.values.reduce(0) { $0 + $1.samples.count } }

    mutating func reset(sessionID: UUID, mode: AudioCompositionMode) {
        self.sessionID = sessionID
        self.mode = mode
        epoch = nil
        outputCursor = 0
        sources = [.microphone: SourceState(), .application: SourceState()]
        preAnchorApplication.removeAll(keepingCapacity: true)
        preAnchorFrames = 0
        _metrics = AudioCompositionMetrics()
    }

    mutating func ingest(sessionID: UUID, chunk: TimedAudioChunk) -> [Float] {
        guard self.sessionID == sessionID, !chunk.samples.isEmpty else { return [] }
        guard mode == .microphoneAndApplication || chunk.source == .microphone else { return [] }

        if epoch == nil {
            guard chunk.source == .microphone else {
                bufferPreAnchor(chunk)
                return []
            }
            epoch = chunk.start
            place(chunk)
            let pending = preAnchorApplication
            preAnchorApplication.removeAll(keepingCapacity: true)
            preAnchorFrames = 0
            for queued in pending { place(queued) }
        } else {
            place(chunk)
        }

        let output = renderThroughSafeWatermark()
        enforceBufferBound()
        return output
    }

    mutating func ingestTail(
        sessionID: UUID,
        source: AudioCompositionSource,
        samples: [Float]
    ) -> [Float] {
        guard self.sessionID == sessionID,
              !samples.isEmpty,
              let epoch,
              let end = sources[source]?.latestPlacedEnd else { return [] }
        let timestamp = AudioHostTimestamp(nanoseconds: frameTimestamp(end, epoch: epoch))
        return ingest(
            sessionID: sessionID,
            chunk: TimedAudioChunk(source: source, start: timestamp, samples: samples)
        )
    }

    mutating func deactivateApplication(sessionID: UUID) -> [Float] {
        guard self.sessionID == sessionID else { return [] }
        guard mode == .microphoneAndApplication else { return [] }
        let flushed = render(until: maxPlacedEnd())
        mode = .microphoneOnly
        sources[.application] = SourceState()
        return flushed
    }

    mutating func finish(sessionID: UUID) -> [Float] {
        guard self.sessionID == sessionID else { return [] }
        let result = render(until: maxPlacedEnd())
        self.sessionID = nil
        mode = .microphoneOnly
        epoch = nil
        outputCursor = 0
        sources = [.microphone: SourceState(), .application: SourceState()]
        preAnchorApplication.removeAll(keepingCapacity: true)
        preAnchorFrames = 0
        return result
    }

    mutating func cancel(sessionID: UUID) {
        guard self.sessionID == sessionID else { return }
        self.sessionID = nil
        epoch = nil
        outputCursor = 0
        sources = [.microphone: SourceState(), .application: SourceState()]
        preAnchorApplication.removeAll(keepingCapacity: true)
        preAnchorFrames = 0
    }

    private mutating func bufferPreAnchor(_ chunk: TimedAudioChunk) {
        let available = configuration.maximumZeroFillFrames - preAnchorFrames
        guard available > 0 else {
            _metrics.preAnchorFramesDropped += chunk.samples.count
            return
        }
        let retainedCount = min(available, chunk.samples.count)
        let retained = TimedAudioChunk(
            source: chunk.source,
            start: chunk.start,
            samples: Array(chunk.samples.prefix(retainedCount))
        )
        preAnchorApplication.append(retained)
        preAnchorFrames += retainedCount
        if retainedCount < chunk.samples.count {
            _metrics.preAnchorFramesDropped += chunk.samples.count - retainedCount
        }
    }

    private mutating func place(_ chunk: TimedAudioChunk) {
        guard let epoch else { return }
        let source = chunk.source
        var state = sources[source] ?? SourceState()
        var start = chunk.start.frameOffset(from: epoch, sampleRate: configuration.sampleRate)
        if let expected = state.expectedNextStart,
           abs(start - expected) <= configuration.timestampSnapFrames {
            start = expected
        }

        let originalStart = start
        if start < outputCursor {
            let dropped = min(chunk.samples.count, outputCursor - start)
            _metrics.lateFramesDropped += dropped
            start += dropped
        }
        if start >= outputCursor + configuration.maximumBufferedFrames,
           start > outputCursor + configuration.maximumZeroFillFrames {
            // A long discontinuity is represented by a bounded cursor advance;
            // never allocate the missing interval.
            let skipped = start - outputCursor - configuration.maximumZeroFillFrames
            outputCursor += skipped
            _metrics.discontinuitiesElided += skipped
        }

        let retainedStart = max(start, outputCursor)
        let offset = max(0, retainedStart - originalStart)
        guard offset < chunk.samples.count else {
            state.latestObservedEnd = max(state.latestObservedEnd ?? Int.min, originalStart + chunk.samples.count)
            state.expectedNextStart = originalStart + chunk.samples.count
            sources[source] = state
            return
        }
        let end = originalStart + chunk.samples.count
        state.latestObservedEnd = max(state.latestObservedEnd ?? Int.min, end)
        state.latestPlacedEnd = max(state.latestPlacedEnd ?? Int.min, end)
        state.expectedNextStart = end
        state.hasInput = true

        for index in offset..<chunk.samples.count {
            let frame = originalStart + index
            guard frame >= outputCursor else { continue }
            var value = chunk.samples[index]
            if !value.isFinite {
                value = 0
                _metrics.nonFiniteSamplesReplaced += 1
            } else if value < -1 || value > 1 {
                value = min(1, max(-1, value))
                _metrics.clippedSamples += 1
            }
            state.samples[frame] = value
        }
        sources[source] = state
    }

    private mutating func renderThroughSafeWatermark() -> [Float] {
        guard epoch != nil else { return [] }
        let end: Int
        switch mode {
        case .microphoneOnly:
            end = sources[.microphone]?.latestPlacedEnd ?? outputCursor
        case .microphoneAndApplication:
            let latest = max(
                sources[.microphone]?.latestObservedEnd ?? 0,
                sources[.application]?.latestObservedEnd ?? 0
            )
            let virtual = max(outputCursor, latest - configuration.maximumLatenessFrames)
            let micSafe = max(sources[.microphone]?.latestPlacedEnd ?? 0, virtual)
            let appSafe = max(sources[.application]?.latestPlacedEnd ?? 0, virtual)
            end = min(micSafe, appSafe)
        }
        return render(until: end)
    }

    private mutating func render(until end: Int) -> [Float] {
        guard end > outputCursor else { return [] }
        let count = end - outputCursor
        var output = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let frame = outputCursor + index
            let mic = sources[.microphone]?.samples[frame]
            let app = mode == .microphoneAndApplication ? sources[.application]?.samples[frame] : nil
            let value: Float
            switch (mic, app) {
            case let (.some(mic), .some(app)):
                value = (mic + app) * 0.5
            case let (.some(mic), .none), let (.none, .some(mic)):
                value = mic
            default:
                value = 0
            }
            if value < -1 || value > 1 {
                _metrics.clippedSamples += 1
                output[index] = min(1, max(-1, value))
            } else {
                output[index] = value.isFinite ? value : 0
            }
        }
        for source in [AudioCompositionSource.microphone, .application] {
            if var state = sources[source] {
                state.samples = state.samples.filter { $0.key >= end }
                sources[source] = state
            }
        }
        outputCursor = end
        return output
    }

    private mutating func enforceBufferBound() {
        guard bufferedFrameCount > configuration.maximumBufferedFrames else { return }
        // Keep the timeline bounded even when a source sends an unusually large
        // chunk. Rendering is deliberately not forced here because this method
        // has no emission channel; normal watermark and finish paths perform the
        // actual output. The oldest unrendered samples are the least useful
        // under the documented bounded-lateness policy.
        let excess = bufferedFrameCount - configuration.maximumBufferedFrames
        var remaining = excess
        for source in [AudioCompositionSource.microphone, .application] where remaining > 0 {
            guard var state = sources[source] else { continue }
            let keys = state.samples.keys.sorted()
            for key in keys where remaining > 0 {
                state.samples.removeValue(forKey: key)
                remaining -= 1
            }
            sources[source] = state
        }
    }

    private func maxPlacedEnd() -> Int {
        if mode == .microphoneOnly {
            return sources[.microphone]?.latestPlacedEnd ?? outputCursor
        }
        return max(
            sources[.microphone]?.latestPlacedEnd ?? outputCursor,
            sources[.application]?.latestPlacedEnd ?? outputCursor
        )
    }

    private func frameTimestamp(_ frame: Int, epoch: AudioHostTimestamp) -> Int64 {
        let delta = Int64(frame).multipliedReportingOverflow(by: 1_000_000_000)
        guard !delta.overflow else { return epoch.nanoseconds }
        return epoch.nanoseconds + delta.partialValue / Int64(configuration.sampleRate)
    }

    fileprivate static func roundedQuotient(_ numerator: Int64, denominator: Int64) -> Int {
        precondition(denominator > 0)
        if numerator >= 0 {
            return Int((numerator + denominator / 2) / denominator)
        }
        return Int(-((-numerator + denominator / 2) / denominator))
    }
}

/// Serializes composition and emission across microphone and ScreenCaptureKit
/// callback queues. Every operation completes before its caller returns.
final class SerializedAudioCompositionPipeline: @unchecked Sendable {
    private let queue: DispatchQueue
    private var composer: AudioTimelineComposer
    private let emit: @Sendable (UUID, [Float]) -> Void
    private let microphoneReady: @Sendable (UUID) -> Void

    init(
        configuration: AudioCompositionConfiguration = AudioCompositionConfiguration(),
        emit: @escaping @Sendable (UUID, [Float]) -> Void,
        microphoneReady: @escaping @Sendable (UUID) -> Void = { _ in }
    ) {
        queue = DispatchQueue(label: "com.mactalk.audio-composition", qos: .userInitiated)
        composer = AudioTimelineComposer(configuration: configuration)
        self.emit = emit
        self.microphoneReady = microphoneReady
    }

    func reset(sessionID: UUID, mode: AudioCompositionMode) {
        queue.sync { composer.reset(sessionID: sessionID, mode: mode) }
    }

    func ingest(sessionID: UUID, chunk: TimedAudioChunk) {
        queue.sync {
            let wasReady = composer.hasMicrophoneAnchor
            let output = composer.ingest(sessionID: sessionID, chunk: chunk)
            if !wasReady && composer.hasMicrophoneAnchor { microphoneReady(sessionID) }
            if !output.isEmpty { emit(sessionID, output) }
        }
    }

    func ingestTail(sessionID: UUID, source: AudioCompositionSource, samples: [Float]) {
        queue.sync {
            let output = composer.ingestTail(sessionID: sessionID, source: source, samples: samples)
            if !output.isEmpty { emit(sessionID, output) }
        }
    }

    func deactivateApplication(sessionID: UUID) {
        queue.sync {
            let output = composer.deactivateApplication(sessionID: sessionID)
            if !output.isEmpty { emit(sessionID, output) }
        }
    }

    func finish(sessionID: UUID) {
        queue.sync {
            let output = composer.finish(sessionID: sessionID)
            if !output.isEmpty { emit(sessionID, output) }
        }
    }

    func cancel(sessionID: UUID) {
        queue.sync { composer.cancel(sessionID: sessionID) }
    }

    var metrics: AudioCompositionMetrics {
        queue.sync { composer.metrics }
    }
}
