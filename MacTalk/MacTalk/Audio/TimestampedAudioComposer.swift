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
    var bufferedOverlapFramesDropped = 0
    var preAnchorFramesDropped = 0
    var invalidMicrophoneTimestamps = 0
    var invalidApplicationTimestamps = 0
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
        /// Number of source-local frames elided from this source's raw PTS
        /// timeline. Keeping this on the source (rather than advancing the
        /// shared output cursor) prevents a discontinuous source from
        /// discarding already buffered coverage from its counterpart.
        var discontinuityOffset = 0
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

    /// True when composition has retained media that cannot yet be emitted
    /// without a cross-source arrival-expiry decision. This is deliberately a
    /// data-availability signal only; elapsed time belongs to the serialized
    /// pipeline's monotonic arrival clock.
    var isWaitingForCounterpart: Bool {
        guard mode == .microphoneAndApplication, epoch != nil,
              let microphone = sources[.microphone],
              let application = sources[.application],
              maxPlacedEnd() > outputCursor else { return false }
        guard microphone.hasInput, application.hasInput,
              let microphoneEnd = microphone.latestObservedEnd,
              let applicationEnd = application.latestObservedEnd else {
            return true
        }
        return microphoneEnd != applicationEnd
    }

    var hasPendingOutput: Bool { maxPlacedEnd() > outputCursor }

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

        var pendingApplication: [TimedAudioChunk] = []
        var placePendingAfterCurrent = false
        if epoch == nil {
            guard chunk.source == .microphone else {
                bufferPreAnchor(chunk)
                return []
            }
            epoch = chunk.start
            pendingApplication = preAnchorApplication
            preAnchorApplication.removeAll(keepingCapacity: true)
            preAnchorFrames = 0
            // Preserve the established callback behavior for aligned
            // pre-anchor packets, but establish current microphone coverage
            // first when a queued application PTS is itself discontinuous.
            placePendingAfterCurrent = pendingApplication.contains {
                $0.start.frameOffset(from: epoch!, sampleRate: configuration.sampleRate)
                    > configuration.maximumZeroFillFrames
            }
            if !placePendingAfterCurrent {
                for queued in pendingApplication { place(queued) }
            }
        }

        // Process packets in bounded slices. This lets a second source make
        // progress even when the first source filled the horizon, while each
        // insertion and each returned emission remains bounded.
        let sliceSize = max(1, min(configuration.maximumZeroFillFrames, configuration.maximumBufferedFrames))
        let originalFrame = chunk.start.frameOffset(from: epoch!, sampleRate: configuration.sampleRate)
        var output: [Float] = []
        var offset = 0
        while offset < chunk.samples.count {
            let count = min(sliceSize, chunk.samples.count - offset)
            let sliceStart = offset == 0
                ? chunk.start
                : AudioHostTimestamp(nanoseconds: frameTimestamp(originalFrame + offset, epoch: epoch!))
            let slice = TimedAudioChunk(
                source: chunk.source,
                start: sliceStart,
                samples: Array(chunk.samples[offset..<(offset + count)])
            )
            place(slice)
            let remaining = configuration.maximumBufferedFrames - output.count
            if remaining > 0 {
                output.append(contentsOf: renderThroughSafeWatermark().prefix(remaining))
            }
            offset += count
            if output.count >= configuration.maximumBufferedFrames {
                // The caller must receive a bounded batch. Remaining packet
                // data is outside this bounded synchronous handoff and is
                // deliberately dropped rather than materialized.
                _metrics.lateFramesDropped += chunk.samples.count - offset
                break
            }
        }
        if placePendingAfterCurrent {
            for queued in pendingApplication { place(queued) }
            if output.count < configuration.maximumBufferedFrames {
                output.append(contentsOf: renderThroughSafeWatermark().prefix(
                    configuration.maximumBufferedFrames - output.count
                ))
            }
        }
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
              // Tail samples continue the source's raw converter stream. A
              // discontinuity may have compressed its placed timeline, so
              // latestPlacedEnd is not a valid raw PTS for the next packet:
              // passing it through place would subtract discontinuityOffset a
              // second time and drop the tail. expectedNextStart is retained
              // in raw PTS frames specifically for this continuation.
              let rawNextStart = sources[source]?.expectedNextStart else { return [] }
        let timestamp = AudioHostTimestamp(nanoseconds: frameTimestamp(rawNextStart, epoch: epoch))
        return ingest(
            sessionID: sessionID,
            chunk: TimedAudioChunk(source: source, start: timestamp, samples: samples)
        )
    }

    /// Expires the current bounded arrival-lateness window. The media
    /// timestamp timeline is unchanged: this only permits the available
    /// source coverage to render, with the other source contributing silence.
    /// Callers that need wall-clock policy must decide when to call `tick`.
    mutating func tick(sessionID: UUID) -> [Float] {
        guard self.sessionID == sessionID,
              mode == .microphoneAndApplication else { return [] }
        return render(until: maxPlacedEnd())
    }

    /// Descriptive alias for callers that model expiry rather than periodic
    /// ticking. Both APIs intentionally share the same bounded behavior.
    mutating func expire(sessionID: UUID) -> [Float] {
        tick(sessionID: sessionID)
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

    mutating func recordInvalidTimestamp(sessionID: UUID, source: AudioCompositionSource) {
        guard self.sessionID == sessionID else { return }
        switch source {
        case .microphone:
            _metrics.invalidMicrophoneTimestamps += 1
        case .application:
            _metrics.invalidApplicationTimestamps += 1
        }
    }

    private mutating func bufferPreAnchor(_ chunk: TimedAudioChunk) {
        // The zero-fill limit is a timeline-gap policy, not the capacity of
        // the pre-anchor queue. Keeping those limits separate is important:
        // a valid application callback may be larger than 250 ms and must not
        // become schedule-dependent merely because it arrived before mic.
        let available = configuration.maximumBufferedFrames - preAnchorFrames
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
        var rawStart = chunk.start.frameOffset(from: epoch, sampleRate: configuration.sampleRate)
        if let expected = state.expectedNextStart,
           abs(rawStart - expected) <= configuration.timestampSnapFrames {
            rawStart = expected
        }

        let rawEnd = rawStart + chunk.samples.count
        state.latestObservedEnd = max(state.latestObservedEnd ?? Int.min, rawEnd)

        // A discontinuity belongs to the source which observed it. Place the
        // source after the furthest already-retained source coverage, keeping
        // only the configured zero-fill interval, but do not move the shared
        // output cursor. The cursor may still point into valid microphone
        // frames that have not reached the cross-source watermark yet.
        var originalStart = rawStart - state.discontinuityOffset
        let placementFloor = max(
            outputCursor,
            sources.values.compactMap(\.latestPlacedEnd).max() ?? outputCursor
        )
        // Only a forward jump in this source's raw PTS timeline is a
        // discontinuity. A contiguous oversized callback can extend beyond
        // the bounded retained window while latestPlacedEnd still points at
        // that window's old end; treating that stale placement as a gap would
        // shift the remainder of an otherwise valid source and duplicate
        // audio on its converter tail.
        let isForwardDiscontinuity: Bool
        if let expected = state.expectedNextStart {
            isForwardDiscontinuity = rawStart > expected + configuration.timestampSnapFrames
        } else {
            isForwardDiscontinuity = originalStart > placementFloor + configuration.maximumZeroFillFrames
        }
        if isForwardDiscontinuity,
           originalStart > placementFloor + configuration.maximumZeroFillFrames {
            let skipped = originalStart - placementFloor - configuration.maximumZeroFillFrames
            state.discontinuityOffset += skipped
            originalStart -= skipped
            _metrics.discontinuitiesElided += skipped
        }
        var start = originalStart
        if start < outputCursor {
            let dropped = min(chunk.samples.count, outputCursor - start)
            _metrics.lateFramesDropped += dropped
            start += dropped
        }

        // Never materialize more than the configured horizon. A callback can
        // contain an arbitrarily large packet; retaining only this bounded
        // window is equivalent to trimming a packet before insertion.
        let retainedStart = max(start, outputCursor)
        let retainedEnd = min(
            originalStart + chunk.samples.count,
            outputCursor + configuration.maximumBufferedFrames
        )
        let offset = max(0, retainedStart - originalStart)
        guard offset < chunk.samples.count, retainedStart < retainedEnd else {
            // This callback was wholly late or outside the bounded horizon.
            // It may inform the watermark, but it must not rewind sequencing.
            if let expected = state.expectedNextStart {
                state.expectedNextStart = max(expected, rawEnd)
            } else {
                state.expectedNextStart = rawEnd
            }
            state.hasInput = true
            sources[source] = state
            return
        }

        var placedEnd = state.latestPlacedEnd ?? Int.min
        state.hasInput = true
        for index in offset..<min(chunk.samples.count, offset + retainedEnd - retainedStart) {
            let frame = originalStart + index
            guard frame >= outputCursor, frame < retainedEnd else { continue }
            // A late callback may overlap data which is still buffered. The
            // first accepted callback wins; never overwrite buffered samples.
            if state.samples[frame] != nil {
                _metrics.bufferedOverlapFramesDropped += 1
                continue
            }
            var value = chunk.samples[index]
            if !value.isFinite {
                value = 0
                _metrics.nonFiniteSamplesReplaced += 1
            } else if value < -1 || value > 1 {
                value = min(1, max(-1, value))
                _metrics.clippedSamples += 1
            }
            state.samples[frame] = value
            placedEnd = max(placedEnd, frame + 1)
        }
        if placedEnd != Int.min {
            state.latestPlacedEnd = max(state.latestPlacedEnd ?? Int.min, placedEnd)
        }
        // A duplicate/backward callback must never move the expected timeline
        // backwards. This is also what prevents a later callback from being
        // snapped into and overwriting an already accepted interval.
        state.expectedNextStart = max(state.expectedNextStart ?? Int.min, rawEnd)
        sources[source] = state
    }

    private mutating func renderThroughSafeWatermark() -> [Float] {
        guard epoch != nil else { return [] }
        let end: Int
        switch mode {
        case .microphoneOnly:
            end = sources[.microphone]?.latestPlacedEnd ?? outputCursor
        case .microphoneAndApplication:
            // Both source watermarks are required. Using the global maximum
            // treats a source which has not produced a callback as absent and
            // makes a 5,000-frame callback render differently depending on
            // which source callback happens to run first. The minimum of the
            // independent observed ends gives each source its full 250 ms
            // lateness window and is invariant under callback permutation.
            guard let mic = sources[.microphone], mic.hasInput,
                  let app = sources[.application], app.hasInput,
                  let micEnd = mic.latestObservedEnd,
                  let appEnd = app.latestObservedEnd else { return [] }
            end = max(
                outputCursor,
                min(micEnd, appEnd) - configuration.maximumLatenessFrames
            )
        }
        return render(until: end)
    }

    private mutating func render(until end: Int) -> [Float] {
        guard end > outputCursor else { return [] }
        // Keep every output allocation bounded, including finish/fallback
        // drains after an oversized callback.
        let boundedEnd = min(end, outputCursor + configuration.maximumBufferedFrames)
        let count = boundedEnd - outputCursor
        guard count > 0 else { return [] }
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
                state.samples = state.samples.filter { $0.key >= boundedEnd }
                sources[source] = state
            }
        }
        outputCursor = boundedEnd
        return output
    }

    private mutating func enforceBufferBound() {
        // Each source owns an independent bounded timeline window. A dual
        // stream must not evict one source merely because the other callback
        // arrived first; watermark rendering releases both windows together.
        for source in [AudioCompositionSource.microphone, .application] {
            guard var state = sources[source],
                  state.samples.count > configuration.maximumBufferedFrames else { continue }
            let excess = state.samples.count - configuration.maximumBufferedFrames
            for key in state.samples.keys.sorted().prefix(excess) {
                state.samples.removeValue(forKey: key)
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

/// A cancellable operation returned by `AudioCompositionScheduler`.
protocol AudioCompositionScheduledTask: Sendable {
    func cancel()
}

/// Schedules callbacks against a monotonic uptime deadline. Tests inject a
/// manual implementation; production uses `DispatchTime` rather than wall
/// clock/calendar time.
protocol AudioCompositionScheduler: Sendable {
    func schedule(
        deadlineNanoseconds: UInt64,
        operation: @escaping @Sendable () -> Void
    ) -> any AudioCompositionScheduledTask
}

private final class DispatchCompositionScheduledTask: AudioCompositionScheduledTask, @unchecked Sendable {
    private let workItem: DispatchWorkItem

    init(workItem: DispatchWorkItem) {
        self.workItem = workItem
    }

    func cancel() {
        workItem.cancel()
    }
}

private struct DispatchAudioCompositionScheduler: AudioCompositionScheduler {
    private let queue = DispatchQueue(label: "com.mactalk.audio-composition-timers", qos: .userInitiated)

    func schedule(
        deadlineNanoseconds: UInt64,
        operation: @escaping @Sendable () -> Void
    ) -> any AudioCompositionScheduledTask {
        let workItem = DispatchWorkItem(block: operation)
        queue.asyncAfter(
            deadline: DispatchTime(uptimeNanoseconds: deadlineNanoseconds),
            execute: workItem
        )
        return DispatchCompositionScheduledTask(workItem: workItem)
    }
}

/// Serializes composition and emission across microphone and ScreenCaptureKit
/// callback queues. Every operation completes before its caller returns.
/// Arrival lateness is intentionally owned here, not inferred from media PTS.
final class SerializedAudioCompositionPipeline: @unchecked Sendable {
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<Void>()
    private var composer: AudioTimelineComposer
    private let configuration: AudioCompositionConfiguration
    private let arrivalClock: @Sendable () -> UInt64
    private let scheduler: any AudioCompositionScheduler
    private var expiryTask: (any AudioCompositionScheduledTask)?
    private var expiryGeneration = UUID()
    private let emit: @Sendable (UUID, [Float]) -> Void
    private let microphoneReady: @Sendable (UUID) -> Void

    init(
        configuration: AudioCompositionConfiguration = AudioCompositionConfiguration(),
        arrivalClock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        scheduler: any AudioCompositionScheduler = DispatchAudioCompositionScheduler(),
        emit: @escaping @Sendable (UUID, [Float]) -> Void,
        microphoneReady: @escaping @Sendable (UUID) -> Void = { _ in }
    ) {
        let queue = DispatchQueue(label: "com.mactalk.audio-composition", qos: .userInitiated)
        queue.setSpecific(key: queueKey, value: ())
        self.queue = queue
        self.composer = AudioTimelineComposer(configuration: configuration)
        self.configuration = configuration
        self.arrivalClock = arrivalClock
        self.scheduler = scheduler
        self.emit = emit
        self.microphoneReady = microphoneReady
    }

    func reset(sessionID: UUID, mode: AudioCompositionMode) {
        onQueue {
            cancelExpiry()
            composer.reset(sessionID: sessionID, mode: mode)
        }
    }

    func ingest(sessionID: UUID, chunk: TimedAudioChunk) {
        // Capture arrival before entering the serialization queue. The media
        // timestamp in `chunk` remains untouched and is never used as a clock.
        let arrival = arrivalClock()
        onQueue {
            let wasReady = composer.hasMicrophoneAnchor
            let output = composer.ingest(sessionID: sessionID, chunk: chunk)
            if !wasReady && composer.hasMicrophoneAnchor { microphoneReady(sessionID) }
            if !output.isEmpty { emit(sessionID, output) }
            updateExpiry(sessionID: sessionID, arrivalNanoseconds: arrival)
        }
    }

    func ingestTail(sessionID: UUID, source: AudioCompositionSource, samples: [Float]) {
        onQueue {
            let output = composer.ingestTail(sessionID: sessionID, source: source, samples: samples)
            if !output.isEmpty { emit(sessionID, output) }
            updateExpiry(sessionID: sessionID, arrivalNanoseconds: arrivalClock())
        }
    }

    /// Explicitly advances the composer without consulting media timestamps.
    /// This is useful for deterministic schedulers and for a final bounded
    /// timer callback.
    func tick(sessionID: UUID) {
        onQueue { tickOnQueue(sessionID: sessionID, nowNanoseconds: arrivalClock()) }
    }

    func deactivateApplication(sessionID: UUID) {
        onQueue {
            cancelExpiry()
            let output = composer.deactivateApplication(sessionID: sessionID)
            if !output.isEmpty { emit(sessionID, output) }
        }
    }

    func finish(sessionID: UUID) {
        onQueue {
            cancelExpiry()
            let output = composer.finish(sessionID: sessionID)
            if !output.isEmpty { emit(sessionID, output) }
        }
    }

    func cancel(sessionID: UUID) {
        onQueue {
            cancelExpiry()
            composer.cancel(sessionID: sessionID)
        }
    }

    func recordInvalidTimestamp(sessionID: UUID, source: AudioCompositionSource) {
        onQueue { composer.recordInvalidTimestamp(sessionID: sessionID, source: source) }
    }

    var metrics: AudioCompositionMetrics {
        onQueue { composer.metrics }
    }

    private func updateExpiry(sessionID: UUID, arrivalNanoseconds: UInt64) {
        guard composer.isWaitingForCounterpart,
              composer.hasPendingOutput,
              configuration.maximumLatenessFrames > 0 else {
            cancelExpiry()
            return
        }
        guard expiryTask == nil else { return }
        let delay = UInt64(configuration.maximumLatenessFrames)
            .multipliedReportingOverflow(by: 1_000_000_000 / UInt64(configuration.sampleRate))
        let boundedDelay = delay.overflow ? 250_000_000 : delay.partialValue
        let deadline = arrivalNanoseconds > UInt64.max - boundedDelay
            ? UInt64.max
            : arrivalNanoseconds + boundedDelay
        let generation = UUID()
        expiryGeneration = generation
        expiryTask = scheduler.schedule(deadlineNanoseconds: deadline) { [weak self] in
            self?.expiryFired(sessionID: sessionID, generation: generation, deadlineNanoseconds: deadline)
        }
    }

    private func expiryFired(sessionID: UUID, generation: UUID, deadlineNanoseconds: UInt64) {
        onQueue {
            guard generation == expiryGeneration else { return }
            expiryTask = nil
            let now = arrivalClock()
            guard now >= deadlineNanoseconds else {
                // A scheduler may wake early; retain one task for the same
                // deadline rather than allowing timer accumulation.
                updateExpiry(sessionID: sessionID, arrivalNanoseconds: now)
                return
            }
            tickOnQueue(sessionID: sessionID, nowNanoseconds: now)
        }
    }

    private func tickOnQueue(sessionID: UUID, nowNanoseconds: UInt64) {
        let output = composer.tick(sessionID: sessionID)
        if !output.isEmpty { emit(sessionID, output) }
        updateExpiry(sessionID: sessionID, arrivalNanoseconds: nowNanoseconds)
    }

    private func cancelExpiry() {
        expiryTask?.cancel()
        expiryTask = nil
        expiryGeneration = UUID()
    }

    private func onQueue<T>(_ operation: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return operation()
        }
        return queue.sync(execute: operation)
    }
}
