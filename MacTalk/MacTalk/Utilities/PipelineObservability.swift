import Foundation
import Darwin
import os

// MARK: - Privacy-preserving schema

enum PipelineSessionOutcome: String, Codable, Sendable { case completed, noSpeech, cancelled, startFailed, inferenceFailed }
enum PipelineInferenceKind: String, Codable, Sendable { case incremental, final }

enum PipelineInsertOutcome: String, Codable, Sendable {
    case notAttempted
    case inserted
    case permissionDenied
    case targetChanged
    case failed
    case cmdVScheduledUnverified
    case rejected

    var completed: Bool { self == .inserted }
}

struct PipelineSessionContext: Codable, Sendable, Equatable {
    let id: UUID
    let provider: ASRProvider
    let modelID: String
    let captureMode: SettingsCaptureMode
    let language: String?
    let batteryMode: Bool
    let startedAt: Date
}

struct CaptureHealthMetrics: Codable, Sendable, Equatable {
    var microphoneDroppedBuffers: UInt64 = 0
    var microphoneCallbacks: UInt64 = 0
    var applicationCallbacks: UInt64 = 0
    var applicationLossEvents: UInt64 = 0
    static let zero = CaptureHealthMetrics()
}

struct PipelineLatencyMetrics: Codable, Sendable, Equatable {
    var prepareMs: Double?
    var firstAcceptedCaptureMs: Double?
    var firstComposedAudioMs: Double?
    var firstPartialFromStartMs: Double?
    var firstPartialFromComposedAudioMs: Double?
    var stopToFinalMs: Double?
    var finalOutputHandoffMs: Double?
    var totalMs: Double?
}

struct PipelineAudioMetrics: Codable, Sendable, Equatable {
    var microphoneInputSamples: UInt64 = 0
    var microphoneConvertedSamples: UInt64 = 0
    var applicationInputSamples: UInt64 = 0
    var conversionNanoseconds: UInt64 = 0
    var applicationConversionNanoseconds: UInt64 = 0
    var conversionFailures: UInt64 = 0
    var composedSamples: UInt64 = 0
    var vadSkips: UInt64 = 0
    var trimmedSamples: UInt64 = 0
    var fallbackCount: UInt64 = 0

    private enum CodingKeys: String, CodingKey {
        case microphoneInputSamples, microphoneConvertedSamples, applicationInputSamples
        case conversionNanoseconds, applicationConversionNanoseconds, conversionFailures
        case composedSamples, vadSkips, trimmedSamples, fallbackCount
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        microphoneInputSamples = try values.decodeIfPresent(UInt64.self, forKey: .microphoneInputSamples) ?? 0
        microphoneConvertedSamples = try values.decodeIfPresent(UInt64.self, forKey: .microphoneConvertedSamples) ?? 0
        applicationInputSamples = try values.decodeIfPresent(UInt64.self, forKey: .applicationInputSamples) ?? 0
        conversionNanoseconds = try values.decodeIfPresent(UInt64.self, forKey: .conversionNanoseconds) ?? 0
        applicationConversionNanoseconds = try values.decodeIfPresent(UInt64.self, forKey: .applicationConversionNanoseconds) ?? 0
        conversionFailures = try values.decodeIfPresent(UInt64.self, forKey: .conversionFailures) ?? 0
        composedSamples = try values.decodeIfPresent(UInt64.self, forKey: .composedSamples) ?? 0
        vadSkips = try values.decodeIfPresent(UInt64.self, forKey: .vadSkips) ?? 0
        trimmedSamples = try values.decodeIfPresent(UInt64.self, forKey: .trimmedSamples) ?? 0
        fallbackCount = try values.decodeIfPresent(UInt64.self, forKey: .fallbackCount) ?? 0
    }
}

struct PipelineQueueMetrics: Codable, Sendable, Equatable {
    var queuedCount: UInt64 = 0
    var startedCount: UInt64 = 0
    var completedCount: UInt64 = 0
    var failedCount: UInt64 = 0
    var maximumDelayMs: Double?
    var maximumPending: UInt64 = 0
}

struct PipelineInferenceMetrics: Codable, Sendable, Equatable {
    var queuedCount: UInt64 = 0
    var completedCount: UInt64 = 0
    var succeededCount: UInt64 = 0
    var failedCount: UInt64 = 0
    var audioSamples: UInt64 = 0
    var durationMs: Double?
    var realTimeFactor: Double?
}

struct PipelineOutputMetrics: Codable, Sendable, Equatable {
    var clipboardWritten = false
    var insertOutcome: PipelineInsertOutcome = .notAttempted
    var insertCompleted = false
}

struct PipelineResourceMetrics: Codable, Sendable, Equatable {
    var startResidentMemoryBytes: UInt64?
    var endResidentMemoryBytes: UInt64?
    var maxObservedResidentMemoryAtCheckpoints: UInt64?
}

struct PipelineSessionReport: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let context: PipelineSessionContext
    let outcome: PipelineSessionOutcome
    let completedAt: Date
    let latency: PipelineLatencyMetrics
    let audio: PipelineAudioMetrics
    let capture: CaptureHealthMetrics
    let queue: PipelineQueueMetrics
    let incrementalInference: PipelineInferenceMetrics
    let finalInference: PipelineInferenceMetrics
    let output: PipelineOutputMetrics
    let composition: AudioCompositionMetrics
    let resources: PipelineResourceMetrics
}

// MARK: - Session recorder

final class PipelineSessionRecorder: @unchecked Sendable {
    private struct InferenceState {
        let kind: PipelineInferenceKind
        let audioSamples: UInt64
        let queuedAt: UInt64
        var startedAt: UInt64?
    }
    private struct State {
        var lastNow: UInt64
        let sessionStart: UInt64
        var firstCapture: UInt64?
        var firstComposed: UInt64?
        var partial: UInt64?
        var stop: UInt64?
        var final: UInt64?
        var output: UInt64?
        var prepareStart: UInt64?
        var prepareDuration: UInt64?
        var audio = PipelineAudioMetrics()
        var capture = CaptureHealthMetrics.zero
        var queue = PipelineQueueMetrics()
        var inference: [UUID: InferenceState] = [:]
        var incrementalDuration: UInt64 = 0
        var incrementalAudio: UInt64 = 0
        var incrementalQueued: UInt64 = 0
        var incrementalCompleted: UInt64 = 0
        var incrementalSucceeded: UInt64 = 0
        var incrementalFailed: UInt64 = 0
        var finalDuration: UInt64 = 0
        var finalAudio: UInt64 = 0
        var finalQueued: UInt64 = 0
        var finalCompleted: UInt64 = 0
        var finalSucceeded: UInt64 = 0
        var finalFailed: UInt64 = 0
        var pending: UInt64 = 0
        var outputMetrics = PipelineOutputMetrics()
        var resources = PipelineResourceMetrics(startResidentMemoryBytes: nil, endResidentMemoryBytes: nil, maxObservedResidentMemoryAtCheckpoints: nil)
        var finished: PipelineSessionReport?
    }

    let context: PipelineSessionContext
    private let nowNanoseconds: @Sendable () -> UInt64
    private let state: OSAllocatedUnfairLock<State>

    init(context: PipelineSessionContext, nowNanoseconds: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.context = context
        self.nowNanoseconds = nowNanoseconds
        let initialNow = nowNanoseconds()
        self.state = OSAllocatedUnfairLock(initialState: State(lastNow: initialNow, sessionStart: initialNow))
    }

    private func tick() -> UInt64 {
        // The injected clock is sampled before acquiring the state lock. This
        // keeps callback paths free of external calls while the lock is held.
        let value = nowNanoseconds()
        return state.withLock { state in
            let monotonic = max(value, state.lastNow)
            state.lastNow = monotonic
            return monotonic
        }
    }
    private func mark(_ key: inout UInt64?, at time: UInt64) { if key == nil { key = time } }

    @discardableResult
    func recordMicrophoneInput(inputSamples: UInt64, convertedSamples: UInt64, conversionNanoseconds: UInt64, conversionFailed: Bool = false) -> Bool {
        let time = tick()
        return state.withLock { s in
            let isFirst = s.firstCapture == nil && convertedSamples > 0
            if convertedSamples > 0 { mark(&s.firstCapture, at: time) }
            s.audio.microphoneInputSamples &+= inputSamples; s.audio.microphoneConvertedSamples &+= convertedSamples; s.audio.conversionNanoseconds &+= conversionNanoseconds; if conversionFailed { s.audio.conversionFailures &+= 1 }
            s.capture.microphoneCallbacks &+= 1
            return isFirst
        }
    }
    @discardableResult
    func recordApplicationInput(callbacks: UInt64 = 1, samples: UInt64 = 0, lossEvents: UInt64 = 0, conversionNanoseconds: UInt64 = 0, conversionFailed: Bool = false) -> Bool {
        let t = tick(); return state.withLock { s in
            let isFirst = s.firstCapture == nil && samples > 0
            if samples > 0 { mark(&s.firstCapture, at: t) }
            s.audio.applicationInputSamples &+= samples
            s.audio.applicationConversionNanoseconds &+= conversionNanoseconds
            if conversionFailed { s.audio.conversionFailures &+= 1 }
            s.capture.applicationCallbacks &+= callbacks
            s.capture.applicationLossEvents &+= lossEvents
            return isFirst
        }
    }

    func recordApplicationLoss() {
        state.withLock { $0.capture.applicationLossEvents &+= 1 }
    }
    func recordConversionFailure() { state.withLock { $0.audio.conversionFailures &+= 1 } }
    @discardableResult
    func recordComposedOutput(samples: UInt64) -> Bool {
        let t = tick()
        return state.withLock { s in
            let isFirst = s.firstComposed == nil
            mark(&s.firstComposed, at: t); s.audio.composedSamples &+= samples
            return isFirst
        }
    }
    func recordVADSkip() { state.withLock { $0.audio.vadSkips &+= 1 } }
    func recordTrimmedAudio(samples: UInt64) { state.withLock { $0.audio.trimmedSamples &+= samples } }
    func recordFallback() { state.withLock { $0.audio.fallbackCount &+= 1 } }
    func recordCaptureDrop(count: UInt64 = 1) { state.withLock { $0.capture.microphoneDroppedBuffers &+= count } }
    func recordInferenceQueueDepth(_ depth: UInt64) { state.withLock { $0.queue.maximumPending = max($0.queue.maximumPending, depth) } }

    func recordPrepareStarted() { let t = tick(); state.withLock { $0.prepareStart = t } }
    func recordPrepareCompleted() { let t = tick(); state.withLock { s in if let start = s.prepareStart { s.prepareDuration = delta(t, start) } } }
    func recordPrepare(durationNanoseconds: UInt64) { _ = tick(); state.withLock { $0.prepareDuration = durationNanoseconds } }

    func recordInferenceQueued(id: UUID, kind: PipelineInferenceKind, audioSamples: UInt64) {
        let t = tick(); state.withLock { s in
            s.inference[id] = InferenceState(kind: kind, audioSamples: audioSamples, queuedAt: t, startedAt: nil); s.queue.queuedCount &+= 1; s.pending &+= 1; s.queue.maximumPending = max(s.queue.maximumPending, s.pending)
            if kind == .incremental { s.incrementalQueued &+= 1 } else { s.finalQueued &+= 1 }
        }
    }
    func recordInferenceStarted(id: UUID) {
        let t = tick(); state.withLock { s in guard var item = s.inference[id] else { return }; item.startedAt = t; s.inference[id] = item; s.queue.startedCount &+= 1; if t >= item.queuedAt { s.queue.maximumDelayMs = max(s.queue.maximumDelayMs ?? 0, ms(delta(t, item.queuedAt))) }
        }
    }
    func recordInferenceCompleted(id: UUID, succeeded: Bool) {
        let t = tick(); state.withLock { s in
            guard let item = s.inference.removeValue(forKey: id) else { return }
            s.queue.completedCount &+= 1; if !succeeded { s.queue.failedCount &+= 1 }; s.pending = s.pending > 0 ? s.pending - 1 : 0
            guard let startedAt = item.startedAt else { return }
            let duration = delta(t, startedAt)
            switch item.kind {
            case .incremental: s.incrementalDuration &+= duration; s.incrementalAudio &+= item.audioSamples; s.incrementalCompleted &+= 1; if succeeded { s.incrementalSucceeded &+= 1 } else { s.incrementalFailed &+= 1 }
            case .final: s.finalDuration &+= duration; s.finalAudio &+= item.audioSamples; s.finalCompleted &+= 1; if succeeded { s.finalSucceeded &+= 1 } else { s.finalFailed &+= 1 }
            }
        }
    }
    func recordInferenceFailed(id: UUID) { recordInferenceCompleted(id: id, succeeded: false) }
    @discardableResult
    func recordPartialPresented() -> Bool {
        let t = tick()
        return state.withLock { s in
            let isFirst = s.partial == nil
            mark(&s.partial, at: t)
            return isFirst
        }
    }
    func recordStopRequested() { let t = tick(); state.withLock { mark(&$0.stop, at: t) } }
    func recordFinalPresented() { let t = tick(); state.withLock { mark(&$0.final, at: t) } }
    func recordOutputHandoff(clipboardWritten: Bool, insertOutcome: PipelineInsertOutcome) { let t = tick(); state.withLock { s in mark(&s.output, at: t); s.outputMetrics = PipelineOutputMetrics(clipboardWritten: clipboardWritten, insertOutcome: insertOutcome, insertCompleted: insertOutcome.completed) } }
    func recordResourceCheckpoint(residentMemoryBytes: UInt64) { state.withLock { s in if s.resources.startResidentMemoryBytes == nil { s.resources.startResidentMemoryBytes = residentMemoryBytes }; s.resources.endResidentMemoryBytes = residentMemoryBytes; s.resources.maxObservedResidentMemoryAtCheckpoints = max(s.resources.maxObservedResidentMemoryAtCheckpoints ?? 0, residentMemoryBytes) } }

    func finish(outcome: PipelineSessionOutcome, capture: CaptureHealthMetrics, composition: AudioCompositionMetrics, completedAt: Date = Date()) -> PipelineSessionReport {
        let t = tick()
        return state.withLock { s in
            if let finished = s.finished { return finished }
            s.capture.microphoneDroppedBuffers &+= capture.microphoneDroppedBuffers
            let inc = PipelineInferenceMetrics(queuedCount: s.incrementalQueued, completedCount: s.incrementalCompleted, succeededCount: s.incrementalSucceeded, failedCount: s.incrementalFailed, audioSamples: s.incrementalAudio, durationMs: s.incrementalCompleted > 0 ? ms(s.incrementalDuration) : nil, realTimeFactor: rtf(duration: s.incrementalDuration, samples: s.incrementalAudio))
            let fin = PipelineInferenceMetrics(queuedCount: s.finalQueued, completedCount: s.finalCompleted, succeededCount: s.finalSucceeded, failedCount: s.finalFailed, audioSamples: s.finalAudio, durationMs: s.finalCompleted > 0 ? ms(s.finalDuration) : nil, realTimeFactor: rtf(duration: s.finalDuration, samples: s.finalAudio))
            let latency = PipelineLatencyMetrics(prepareMs: s.prepareDuration.map(ms), firstAcceptedCaptureMs: s.firstCapture.map { ms(delta($0, s.sessionStart)) }, firstComposedAudioMs: s.firstComposed.map { ms(delta($0, s.sessionStart)) }, firstPartialFromStartMs: s.partial.map { ms(delta($0, s.sessionStart)) }, firstPartialFromComposedAudioMs: relative(s.partial, s.firstComposed), stopToFinalMs: relative(s.final, s.stop), finalOutputHandoffMs: relative(s.output, s.final), totalMs: ms(delta(s.lastNow, s.sessionStart)))
            let report = PipelineSessionReport(schemaVersion: 1, context: context, outcome: outcome, completedAt: completedAt, latency: latency, audio: s.audio, capture: s.capture, queue: s.queue, incrementalInference: inc, finalInference: fin, output: s.outputMetrics, composition: composition, resources: s.resources)
            s.finished = report; return report
        }
    }

    private func relative(_ a: UInt64?, _ b: UInt64?) -> Double? { guard let a, let b, a >= b else { return nil }; return ms(a - b) }
    private func delta(_ end: UInt64, _ start: UInt64) -> UInt64 { end >= start ? end - start : 0 }
    private func delta(_ end: UInt64, start: UInt64) -> UInt64 { end >= start ? end - start : 0 }
    private func ms(_ nanoseconds: UInt64) -> Double { Double(nanoseconds) / 1_000_000 }
    private func rtf(duration: UInt64, samples: UInt64) -> Double? { guard samples > 0, duration > 0 else { return nil }; return (Double(duration) / 1_000_000_000) / (Double(samples) / 16_000) }
}

// MARK: - Signposts and unified summary

enum PipelineLog {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.mactalk.app",
        category: "pipeline"
    )

    static func captureRetirementFailed() {
        logger.error("capture_retirement_failed")
    }
}

enum PipelineObservabilityEvent: Sendable, Equatable {
    case sessionBegin(PipelineSessionContext)
    case sessionEnd(PipelineSessionContext)
    case persistedSummary(PipelineSessionReport)
}

protocol PipelineObservabilityEventSink: Sendable {
    func emit(_ event: PipelineObservabilityEvent)
}

struct PipelineObservabilityEmitter: Sendable {
    static let live = PipelineObservabilityEmitter()
    private let sink: (any PipelineObservabilityEventSink)?

    init(sink: (any PipelineObservabilityEventSink)? = nil) {
        self.sink = sink
    }

    func beginSession(_ id: OSSignpostID, context: PipelineSessionContext) {
        PipelineSignposts.beginSession(id, context: context)
        sink?.emit(.sessionBegin(context))
    }

    func endSession(_ id: OSSignpostID, context: PipelineSessionContext) {
        PipelineSignposts.endSession(id, context: context)
        sink?.emit(.sessionEnd(context))
    }

    func persistedSummary(_ report: PipelineSessionReport) {
        PipelineSignposts.persistedSummary(report)
        sink?.emit(.persistedSummary(report))
    }
}

enum PipelineSignposts {
    static let log = OSLog(subsystem: Bundle.main.bundleIdentifier ?? "com.mactalk.app", category: "pipeline")
    static func sessionID() -> OSSignpostID { OSSignpostID(log: log) }
    static func inferenceID() -> OSSignpostID { OSSignpostID(log: log) }
    static func beginSession(_ id: OSSignpostID, context: PipelineSessionContext) {
        os_signpost(
            .begin,
            log: log,
            name: "TranscriptionSession",
            signpostID: id,
            "provider=%{public}s model=%{public}s captureMode=%{public}s",
            context.provider.rawValue,
            context.modelID,
            context.captureMode.rawValue
        )
    }
    static func endSession(_ id: OSSignpostID, context: PipelineSessionContext) {
        os_signpost(
            .end,
            log: log,
            name: "TranscriptionSession",
            signpostID: id,
            "provider=%{public}s model=%{public}s captureMode=%{public}s",
            context.provider.rawValue,
            context.modelID,
            context.captureMode.rawValue
        )
    }
    static func persistedSummary(_ report: PipelineSessionReport) {
        let incrementalRTF = report.incrementalInference.realTimeFactor.map { String(format: "%.3f", $0) } ?? "n/a"
        let finalRTF = report.finalInference.realTimeFactor.map { String(format: "%.3f", $0) } ?? "n/a"
        let totalMs = report.latency.totalMs.map { String(format: "%.3f", $0) } ?? "n/a"
        os_log(
            "pipeline_summary provider=%{public}s model=%{public}s captureMode=%{public}s outcome=%{public}s totalMs=%{public}s incrementalRTF=%{public}s finalRTF=%{public}s micDrops=%{public}llu appLoss=%{public}llu conversionFailures=%{public}llu compositionAnomalies=%{public}llu",
            log: log,
            type: .info,
            report.context.provider.rawValue,
            report.context.modelID,
            report.context.captureMode.rawValue,
            report.outcome.rawValue,
            totalMs,
            incrementalRTF,
            finalRTF,
            report.capture.microphoneDroppedBuffers,
            report.capture.applicationLossEvents,
            report.audio.conversionFailures,
            UInt64(max(0, report.composition.lateFramesDropped))
                + UInt64(max(0, report.composition.bufferedOverlapFramesDropped))
                + UInt64(max(0, report.composition.preAnchorFramesDropped))
                + UInt64(max(0, report.composition.invalidMicrophoneTimestamps))
                + UInt64(max(0, report.composition.invalidApplicationTimestamps))
                + UInt64(max(0, report.composition.discontinuitiesElided))
                + UInt64(max(0, report.composition.nonFiniteSamplesReplaced))
                + UInt64(max(0, report.composition.clippedSamples))
        )
    }
    static func beginInference(_ id: OSSignpostID, kind: PipelineInferenceKind) { os_signpost(.begin, log: log, name: "Inference", signpostID: id, "%{public}s", kind.rawValue) }
    static func endInference(_ id: OSSignpostID) { os_signpost(.end, log: log, name: "Inference", signpostID: id) }
    static func firstAudio(_ id: OSSignpostID) { os_signpost(.event, log: log, name: "FirstAudio", signpostID: id) }
    static func firstComposedAudio(_ id: OSSignpostID) { os_signpost(.event, log: log, name: "FirstComposedAudio", signpostID: id) }
    static func firstPartial(_ id: OSSignpostID) { os_signpost(.event, log: log, name: "FirstPartial", signpostID: id) }
}

// MARK: - Bounded local store

protocol PipelineMetricsStoring: Sendable {
    func record(_ report: PipelineSessionReport) async
    func reports(limit: Int) async -> [PipelineSessionReport]
    func formattedReport(limit: Int) async -> String
}

actor PipelineMetricsStore: PipelineMetricsStoring {
    static let defaultURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/MacTalk/pipeline-metrics.jsonl")
    static let shared = PipelineMetricsStore()
    let fileURL: URL
    let retentionLimit: Int
    let maximumFileBytes: Int
    let maximumLineBytes: Int
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileURL: URL = PipelineMetricsStore.defaultURL, retentionLimit: Int = 100, maximumFileBytes: Int = 512 * 1024, maximumLineBytes: Int = 8 * 1024) {
        self.fileURL = fileURL
        self.retentionLimit = min(100, max(1, retentionLimit))
        self.maximumFileBytes = max(1, maximumFileBytes)
        self.maximumLineBytes = max(1, maximumLineBytes)
    }
    func record(_ report: PipelineSessionReport) async {
        guard isSemanticallyValid(report) else { return }
        var reports = readReports()
        reports.append(report)
        writeReports(Array(reports.suffix(retentionLimit)))
    }
    func reports(limit: Int) async -> [PipelineSessionReport] {
        guard limit > 0 else { return [] }
        return Array(readReports().suffix(limit))
    }
    func formattedReport(limit: Int) async -> String { format(Array(readReports().suffix(max(0, limit)))) }

    private var metricsBasename: String { fileURL.lastPathComponent }
    private var metricsDirectoryURL: URL { fileURL.deletingLastPathComponent() }

    private func openMetricsDirectory(create: Bool) -> Int32? {
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW
        var descriptor = open(metricsDirectoryURL.path, flags)
        if descriptor < 0, create, errno == ENOENT {
            do {
                try FileManager.default.createDirectory(at: metricsDirectoryURL, withIntermediateDirectories: true, attributes: [.posixPermissions: NSNumber(value: 0o700)])
            } catch {
                return nil
            }
            descriptor = open(metricsDirectoryURL.path, flags)
        }
        guard descriptor >= 0 else { return nil }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(),
              (info.st_mode & 0o7777) == 0o700 else {
            close(descriptor)
            return nil
        }
        return descriptor
    }

    private func readReports() -> [PipelineSessionReport] {
        guard let directoryDescriptor = openMetricsDirectory(create: false) else { return [] }
        defer { close(directoryDescriptor) }
        let descriptor = openat(directoryDescriptor, metricsBasename, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return [] }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(),
              (info.st_mode & 0o7777) == 0o600,
              info.st_size >= 0 else { return [] }
        let size = UInt64(info.st_size)
        let boundedLength = min(size, UInt64(maximumFileBytes))
        let start = size - boundedLength
        guard lseek(descriptor, off_t(start), SEEK_SET) >= 0 else { return [] }
        var bytes = [UInt8](repeating: 0, count: Int(boundedLength))
        var offset = 0
        while offset < bytes.count {
            let remaining = bytes.count - offset
            let count = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(descriptor, buffer.baseAddress!.advanced(by: offset), remaining)
            }
            if count < 0 {
                if errno == EINTR { continue }
                return []
            }
            if count == 0 { break }
            offset += count
        }
        let data = Data(bytes: bytes, count: offset)
        return data.split(separator: 10, omittingEmptySubsequences: true).compactMap { line in
            guard line.count <= maximumLineBytes,
                  let report = try? decoder.decode(PipelineSessionReport.self, from: Data(line)),
                  isSemanticallyValid(report) else { return nil }
            return report
        }
    }

    private func writeReports(_ reports: [PipelineSessionReport]) {
        guard let directoryDescriptor = openMetricsDirectory(create: true) else { return }
        defer { close(directoryDescriptor) }
        var kept: [Data] = []
        var totalBytes: UInt64 = 0
        for report in reports {
            guard isSemanticallyValid(report), let data = try? encoder.encode(report), data.count <= maximumLineBytes - 1 else { continue }
            kept.append(data)
            totalBytes = saturatingAdd(totalBytes, UInt64(data.count) + 1)
        }
        while !kept.isEmpty && totalBytes > UInt64(maximumFileBytes) {
            let removed = kept.removeFirst()
            totalBytes -= UInt64(removed.count) + 1
        }
        var data = Data()
        data.reserveCapacity(Int(totalBytes))
        for line in kept { data.append(line); data.append(10) }

        let destination = metricsBasename
        var destinationInfo = stat()
        let destinationStatus = fstatat(directoryDescriptor, destination, &destinationInfo, AT_SYMLINK_NOFOLLOW)
        if destinationStatus == 0 {
            guard (destinationInfo.st_mode & S_IFMT) == S_IFREG,
                  destinationInfo.st_uid == getuid(),
                  (destinationInfo.st_mode & 0o7777) == 0o600 else { return }
        } else if errno != ENOENT {
            return
        }

        let temporaryName = ".pipeline-metrics-\(UUID().uuidString).tmp"
        var temporaryDescriptor = openat(directoryDescriptor, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard temporaryDescriptor >= 0 else { return }
        var renamed = false
        defer {
            if temporaryDescriptor >= 0 { close(temporaryDescriptor) }
            if !renamed { unlinkat(directoryDescriptor, temporaryName, 0) }
        }
        var temporaryInfo = stat()
        guard fstat(temporaryDescriptor, &temporaryInfo) == 0,
              (temporaryInfo.st_mode & S_IFMT) == S_IFREG,
              temporaryInfo.st_uid == getuid(),
              (temporaryInfo.st_mode & 0o7777) == 0o600 else { return }
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { buffer in
                Darwin.write(temporaryDescriptor, buffer.baseAddress!.advanced(by: offset), data.count - offset)
            }
            if count < 0 {
                if errno == EINTR { continue }
                return
            }
            guard count > 0 else { return }
            offset += count
        }
        guard close(temporaryDescriptor) == 0 else {
            temporaryDescriptor = -1
            return
        }
        temporaryDescriptor = -1
        guard renameat(directoryDescriptor, temporaryName, directoryDescriptor, destination) == 0 else { return }
        renamed = true
    }

    private func isSemanticallyValid(_ report: PipelineSessionReport) -> Bool {
        let composition = report.composition
        guard composition.lateFramesDropped >= 0,
              composition.bufferedOverlapFramesDropped >= 0,
              composition.preAnchorFramesDropped >= 0,
              composition.invalidMicrophoneTimestamps >= 0,
              composition.invalidApplicationTimestamps >= 0,
              composition.discontinuitiesElided >= 0,
              composition.nonFiniteSamplesReplaced >= 0,
              composition.clippedSamples >= 0 else { return false }
        let latency = report.latency
        let queue = report.queue
        let incremental = report.incrementalInference
        let final = report.finalInference
        return [latency.prepareMs, latency.firstAcceptedCaptureMs, latency.firstComposedAudioMs,
                latency.firstPartialFromStartMs, latency.firstPartialFromComposedAudioMs,
                latency.stopToFinalMs, latency.finalOutputHandoffMs, latency.totalMs,
                queue.maximumDelayMs, incremental.durationMs, incremental.realTimeFactor,
                final.durationMs, final.realTimeFactor].allSatisfy { value in
            guard let value else { return true }
            return value.isFinite && value >= 0
        }
    }

    private func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : result
    }

    private func format(_ reports: [PipelineSessionReport]) -> String {
        guard !reports.isEmpty else { return "No completed sessions\nSchema version: 1\nObservations: 0" }
        let groups = Dictionary(grouping: reports) { "\($0.context.provider.rawValue)/\($0.context.modelID)/\($0.context.captureMode.rawValue)" }
        var lines = ["Pipeline metrics (schema version 1)", "Observations: \(reports.count)", "Location: \(fileURL.path)"]
        for key in groups.keys.sorted() {
            let dimensionReports = groups[key]!
            lines.append("Dimension \(key): \(dimensionReports.count) observations")
            lines.append(contentsOf: statistics(for: dimensionReports))
        }
        return lines.joined(separator: "\n")
    }

    private func statistics(for reports: [PipelineSessionReport]) -> [String] {
        let outcomes = reports.map { $0.outcome.rawValue }.reduce(into: [:]) { $0[$1, default: 0] += 1 }
        let drops = reports.reduce(UInt64(0)) { saturatingAdd($0, $1.capture.microphoneDroppedBuffers) }
        let conversionFailures = reports.reduce(UInt64(0)) { saturatingAdd($0, $1.audio.conversionFailures) }
        let compositionAnomalies = reports.reduce(UInt64(0)) { total, report in
            let composition = report.composition
            let counters = [composition.lateFramesDropped, composition.bufferedOverlapFramesDropped,
                            composition.preAnchorFramesDropped, composition.invalidMicrophoneTimestamps,
                            composition.invalidApplicationTimestamps, composition.discontinuitiesElided,
                            composition.nonFiniteSamplesReplaced, composition.clippedSamples]
            return counters.reduce(total) { saturatingAdd($0, UInt64($1)) }
        }
        let vadSkips = reports.reduce(UInt64(0)) { saturatingAdd($0, $1.audio.vadSkips) }
        let trimmedSamples = reports.reduce(UInt64(0)) { saturatingAdd($0, $1.audio.trimmedSamples) }
        let fallbackCount = reports.reduce(UInt64(0)) { saturatingAdd($0, $1.audio.fallbackCount) }
        return [
            "Outcomes: " + outcomes.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", "),
            "First partial ms p50/p95: \(percentile(reports.compactMap { $0.latency.firstPartialFromStartMs }, p: 0.5))/\(percentile(reports.compactMap { $0.latency.firstPartialFromStartMs }, p: 0.95))",
            "Stop to final ms p50/p95: \(percentile(reports.compactMap { $0.latency.stopToFinalMs }, p: 0.5))/\(percentile(reports.compactMap { $0.latency.stopToFinalMs }, p: 0.95))",
            "Incremental RTF p50/p95: \(percentile(reports.compactMap { $0.incrementalInference.realTimeFactor }, p: 0.5))/\(percentile(reports.compactMap { $0.incrementalInference.realTimeFactor }, p: 0.95))",
            "Final RTF p50/p95: \(percentile(reports.compactMap { $0.finalInference.realTimeFactor }, p: 0.5))/\(percentile(reports.compactMap { $0.finalInference.realTimeFactor }, p: 0.95))",
            "Capture drops: \(drops); conversion failures: \(conversionFailures); composition anomalies: \(compositionAnomalies); VAD skips: \(vadSkips); trimmed samples: \(trimmedSamples); fallback: \(fallbackCount)"
        ]
    }
    private func percentile(_ values: [Double], p: Double) -> String {
        guard !values.isEmpty else { return "n/a" }
        let sorted = values.sorted()
        let index = max(0, Int(ceil(p * Double(sorted.count))) - 1)
        return String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), sorted[index])
    }
}
