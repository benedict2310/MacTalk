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
    case failed
    case cmdVScheduledUnverified

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
    var conversionFailures: UInt64 = 0
    var composedSamples: UInt64 = 0
    var vadSkips: UInt64 = 0
    var trimmedSamples: UInt64 = 0
    var fallbackCount: UInt64 = 0
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

    func recordMicrophoneInput(inputSamples: UInt64, convertedSamples: UInt64, conversionNanoseconds: UInt64, conversionFailed: Bool = false) {
        let time = tick(); state.withLock { s in
            mark(&s.firstCapture, at: time); s.audio.microphoneInputSamples &+= inputSamples; s.audio.microphoneConvertedSamples &+= convertedSamples; s.audio.conversionNanoseconds &+= conversionNanoseconds; if conversionFailed { s.audio.conversionFailures &+= 1 }
            s.capture.microphoneCallbacks &+= 1
        }
    }
    func recordApplicationInput(callbacks: UInt64 = 1, samples: UInt64 = 0, lossEvents: UInt64 = 0) {
        let t = tick(); state.withLock { s in mark(&s.firstCapture, at: t); s.audio.applicationInputSamples &+= samples; s.capture.applicationCallbacks &+= callbacks; s.capture.applicationLossEvents &+= lossEvents }
    }
    func recordConversionFailure() { state.withLock { $0.audio.conversionFailures &+= 1 } }
    func recordComposedOutput(samples: UInt64) { let t = tick(); state.withLock { s in mark(&s.firstComposed, at: t); s.audio.composedSamples &+= samples } }
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
            let duration = item.startedAt.map { delta(t, $0) } ?? 0
            s.queue.completedCount &+= 1; if !succeeded { s.queue.failedCount &+= 1 }; s.pending = s.pending > 0 ? s.pending - 1 : 0
            switch item.kind {
            case .incremental: s.incrementalDuration &+= duration; s.incrementalAudio &+= item.audioSamples; s.incrementalCompleted &+= 1; if succeeded { s.incrementalSucceeded &+= 1 } else { s.incrementalFailed &+= 1 }
            case .final: s.finalDuration &+= duration; s.finalAudio &+= item.audioSamples; s.finalCompleted &+= 1; if succeeded { s.finalSucceeded &+= 1 } else { s.finalFailed &+= 1 }
            }
        }
    }
    func recordInferenceFailed(id: UUID) { recordInferenceCompleted(id: id, succeeded: false) }
    func recordPartialPresented() { let t = tick(); state.withLock { mark(&$0.partial, at: t) } }
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

// MARK: - Signposts

enum PipelineSignposts {
    static let log = OSLog(subsystem: Bundle.main.bundleIdentifier ?? "com.mactalk.app", category: "pipeline")
    static func sessionID() -> OSSignpostID { OSSignpostID(log: log) }
    static func inferenceID() -> OSSignpostID { OSSignpostID(log: log) }
    static func beginSession(_ id: OSSignpostID) { os_signpost(.begin, log: log, name: "TranscriptionSession", signpostID: id) }
    static func endSession(_ id: OSSignpostID) { os_signpost(.end, log: log, name: "TranscriptionSession", signpostID: id) }
    static func beginInference(_ id: OSSignpostID, kind: PipelineInferenceKind) { os_signpost(.begin, log: log, name: "Inference", signpostID: id, "%{public}s", kind.rawValue) }
    static func endInference(_ id: OSSignpostID) { os_signpost(.end, log: log, name: "Inference", signpostID: id) }
    static func firstAudio(_ id: OSSignpostID) { os_signpost(.event, log: log, name: "FirstAudio", signpostID: id) }
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
    func record(_ report: PipelineSessionReport) async { var reports = readReports(); reports.append(report); writeReports(Array(reports.suffix(retentionLimit))) }
    func reports(limit: Int) async -> [PipelineSessionReport] { guard limit > 0 else { return [] }; return Array(readReports().suffix(limit)) }
    func formattedReport(limit: Int) async -> String { format(Array(readReports().suffix(max(0, limit)))) }

    private func readReports() -> [PipelineSessionReport] {
        guard secureParentAndFile() else { return [] }
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let boundedLength = min(size, UInt64(maximumFileBytes))
        let start = size - boundedLength
        guard (try? handle.seek(toOffset: start)) != nil else { return [] }
        let data = handle.readData(ofLength: Int(boundedLength))
        return data.split(separator: 10, omittingEmptySubsequences: true).compactMap { line in
            guard line.count <= maximumLineBytes else { return nil }
            return try? decoder.decode(PipelineSessionReport.self, from: Data(line))
        }
    }
    private func writeReports(_ reports: [PipelineSessionReport]) {
        guard secureParentAndFile(create: true) else { return }
        var kept: [Data] = []
        for report in reports {
            guard let data = try? encoder.encode(report), data.count + 1 <= maximumLineBytes else { continue }
            kept.append(data)
        }
        while !kept.isEmpty && kept.reduce(0, { $0 + $1.count + 1 }) > maximumFileBytes { kept.removeFirst() }
        let directory = fileURL.deletingLastPathComponent()
        let temp = directory.appendingPathComponent(".pipeline-metrics-\(UUID().uuidString).tmp")
        let data = kept.reduce(into: Data()) { result, line in result.append(line); result.append(10) }
        let fm = FileManager.default
        guard fm.createFile(atPath: temp.path, contents: nil, attributes: [.posixPermissions: NSNumber(value: 0o600)]) else { return }
        guard securePermissions(temp, mode: 0o600), !isSymlink(temp) else { try? fm.removeItem(at: temp); return }
        do {
            let handle = try FileHandle(forWritingTo: temp)
            try handle.write(contentsOf: data)
            try handle.close()
            guard securePermissions(temp, mode: 0o600) else { throw CocoaError(.fileWriteNoPermission) }
            if fm.fileExists(atPath: fileURL.path) {
                try fm.replaceItemAt(fileURL, withItemAt: temp)
            } else {
                try fm.moveItem(at: temp, to: fileURL)
            }
            guard securePermissions(fileURL, mode: 0o600), !isSymlink(fileURL) else { return }
        } catch {
            try? fm.removeItem(at: temp)
        }
    }
    private func secureParentAndFile(create: Bool = false) -> Bool {
        let fm = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        let directoryExists = fm.fileExists(atPath: directory.path)
        if !directoryExists {
            guard create else { return false }
            do {
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                guard chmod(directory.path, 0o700) == 0 else { return false }
            } catch { return false }
        }
        guard !isSymlink(directory), ownedByCurrentUser(directory), securePermissions(directory, mode: 0o700) else { return false }
        guard !isSymlink(fileURL) else { return false }
        if fm.fileExists(atPath: fileURL.path) {
            return securePermissions(fileURL, mode: 0o600)
        }
        return create
    }
    private func ownedByCurrentUser(_ url: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path), let owner = attrs[.ownerAccountID] as? NSNumber else { return false }
        return owner.uint32Value == getuid()
    }
    private func securePermissions(_ url: URL, mode: Int32) -> Bool {
        guard ownedByCurrentUser(url), let attrs = try? FileManager.default.attributesOfItem(atPath: url.path), let permissions = attrs[.posixPermissions] as? NSNumber else { return false }
        return permissions.int32Value & 0o777 == mode
    }
    private func isSymlink(_ url: URL) -> Bool { ((try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false) }

    private func format(_ reports: [PipelineSessionReport]) -> String {
        guard !reports.isEmpty else { return "No completed sessions\nSchema version: 1\nObservations: 0" }
        let groups = Dictionary(grouping: reports) { "\($0.context.provider.rawValue)/\($0.context.modelID)/\($0.context.captureMode.rawValue)" }
        var lines = ["Pipeline metrics (schema version 1)", "Observations: \(reports.count)", "Location: \(fileURL.path)"]
        for key in groups.keys.sorted() { lines.append("Dimension \(key): \(groups[key]!.count) observations") }
        lines.append("Outcomes: " + reports.map { $0.outcome.rawValue }.reduce(into: [:]) { $0[$1, default: 0] += 1 }.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", "))
        lines.append("First partial ms p50/p95: \(percentile(reports.compactMap { $0.latency.firstPartialFromStartMs }, p: 0.5))/\(percentile(reports.compactMap { $0.latency.firstPartialFromStartMs }, p: 0.95))")
        lines.append("Stop to final ms p50/p95: \(percentile(reports.compactMap { $0.latency.stopToFinalMs }, p: 0.5))/\(percentile(reports.compactMap { $0.latency.stopToFinalMs }, p: 0.95))")
        lines.append("Incremental RTF p50/p95: \(percentile(reports.compactMap { $0.incrementalInference.realTimeFactor }, p: 0.5))/\(percentile(reports.compactMap { $0.incrementalInference.realTimeFactor }, p: 0.95))")
        lines.append("Final RTF p50/p95: \(percentile(reports.compactMap { $0.finalInference.realTimeFactor }, p: 0.5))/\(percentile(reports.compactMap { $0.finalInference.realTimeFactor }, p: 0.95))")
        let drops = reports.reduce(0) { $0 + $1.capture.microphoneDroppedBuffers }
        let conversionFailures = reports.reduce(0) { $0 + $1.audio.conversionFailures }
        let compositionAnomalies = reports.reduce(0) { $0 + UInt64($1.composition.lateFramesDropped + $1.composition.nonFiniteSamplesReplaced) }
        let vadSkips = reports.reduce(0) { $0 + $1.audio.vadSkips }
        let trimmedSamples = reports.reduce(0) { $0 + $1.audio.trimmedSamples }
        let fallbackCount = reports.reduce(0) { $0 + $1.audio.fallbackCount }
        lines.append("Capture drops: \(drops); conversion failures: \(conversionFailures); composition anomalies: \(compositionAnomalies); VAD skips: \(vadSkips); trimmed samples: \(trimmedSamples); fallback: \(fallbackCount)")
        return lines.joined(separator: "\n")
    }
    private func percentile(_ values: [Double], p: Double) -> String { guard !values.isEmpty else { return "n/a" }; let sorted = values.sorted(); let index = max(0, Int(ceil(p * Double(sorted.count))) - 1); return String(format: "%.3f", sorted[index]) }
}
