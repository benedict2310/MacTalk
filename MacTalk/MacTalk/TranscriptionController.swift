//
//  TranscriptionController.swift
//  MacTalk
//
//  Orchestrates audio capture, mixing, and transcription
//

import Foundation
import Darwin
import AudioToolbox
@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
import os

/// Identifies the currently accepted audio-capture session.
///
/// Capture callbacks can arrive after ScreenCaptureKit has been asked to stop.
/// The gate is checked before conversion and again before appending converted
/// samples so a stopped or replaced session cannot mutate a new stream.
final class AudioSessionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var activeSession: UUID?

    func begin() -> UUID {
        begin(UUID())
    }

    @discardableResult
    func begin(_ session: UUID) -> UUID {
        lock.lock()
        activeSession = session
        lock.unlock()
        return session
    }

    func stop() {
        lock.lock()
        activeSession = nil
        lock.unlock()
    }

    func accepts(_ session: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeSession == session
    }

}

private final class CompositionOwnerBox: @unchecked Sendable {
    weak var owner: TranscriptionController?
}

private struct StartGeneration: Sendable, Equatable {
    let sequence: UInt64
    let sessionID: UUID
}

private struct ScheduledStop: Sendable {
    let token: UUID
    var task: (any AudioCompositionScheduledTask)?
}

private struct ControllerLifecycleState: Sendable {
    var nextGeneration: UInt64 = 0
    var activeGeneration: StartGeneration?
    var scheduledStop: ScheduledStop?
}

private func UInt64ToHostNanoseconds(_ hostTime: UInt64) -> Int64? {
    guard hostTime != 0 else { return nil }
    let nanos = AudioConvertHostTimeToNanos(hostTime)
    return Int64(exactly: nanos)
}

enum TranscriptCleaner {
    private static let leadingArtifactCharacters = CharacterSet(charactersIn: ".,;:!?…·-–—")
    private static let fillerPattern = #"\b(?:um+|uh+|erm+|er+|hmm+|hm+)\b[,;:]*"#

    static func clean(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        result = stripLeadingArtifacts(from: result)
        result = removeFillerWords(from: result)
        result = stripLeadingArtifacts(from: result)
        result = normalizeSpacing(in: result)
        result = capitalizeSentenceStarts(in: result)

        // Ensure ends with punctuation
        let punctuation: Set<Character> = [".", "!", "?"]
        if let last = result.last, !punctuation.contains(last) {
            result += "."
        }

        return result
    }

    private static func stripLeadingArtifacts(from text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let firstScalar = result.unicodeScalars.first,
              leadingArtifactCharacters.contains(firstScalar) {
            result.removeFirst()
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    private static func removeFillerWords(from text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: fillerPattern, options: [.caseInsensitive]) else {
            return text
        }
        let range = NSRange(location: 0, length: text.utf16.count)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
    }

    private static func normalizeSpacing(in text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove duplicate spaces
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }

        // Normalize common spacing artifacts around punctuation
        let punctuationSpacingFixes = [" .": ".", " ,": ",", " !": "!", " ?": "?", " ;": ";", " :": ":"]
        for (artifact, replacement) in punctuationSpacingFixes {
            result = result.replacingOccurrences(of: artifact, with: replacement)
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func capitalizeSentenceStarts(in text: String) -> String {
        var result = ""
        var shouldCapitalizeNextLetter = true

        for character in text {
            if shouldCapitalizeNextLetter, character.isLetter {
                result += character.uppercased()
                shouldCapitalizeNextLetter = false
                continue
            }

            result.append(character)

            if character == "." || character == "!" || character == "?" {
                shouldCapitalizeNextLetter = true
            } else if !character.isWhitespace && character.isLetter {
                shouldCapitalizeNextLetter = false
            }
        }

        return result
    }
}

enum TranscriptFinalReconciler {
    private struct Word {
        let canonical: String
        let range: Range<String.Index>
    }

    static func reconcile(incrementalSegments: [String], finalText: String) -> String {
        let incrementalText = incrementalSegments.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !incrementalText.isEmpty else { return finalText }

        let incrementalWords = words(in: incrementalText)
        let finalWords = words(in: finalText)
        guard !incrementalWords.isEmpty, !finalWords.isEmpty else { return finalText }

        let incrementalCanonical = incrementalWords.map(\.canonical)
        let finalCanonical = finalWords.map(\.canonical)
        if finalCanonical.count >= incrementalCanonical.count,
           Array(finalCanonical.prefix(incrementalCanonical.count)) == incrementalCanonical {
            return finalText
        }

        let maximumOverlap = min(incrementalCanonical.count, finalCanonical.count)
        let overlap = stride(from: maximumOverlap, through: 1, by: -1).first { count in
            Array(incrementalCanonical.suffix(count)) == Array(finalCanonical.prefix(count))
        }
        guard let overlap else { return finalText }
        guard let incrementalLastWord = incrementalWords.last else { return finalText }
        let incrementalPrefix = incrementalText[..<incrementalLastWord.range.upperBound]
        let finalTail = finalText[finalWords[overlap - 1].range.upperBound...]
        return String(incrementalPrefix) + String(finalTail)
    }

    private static func words(in text: String) -> [Word] {
        var result: [Word] = []
        var wordStart: String.Index?

        for index in text.indices {
            let character = text[index]
            if character.isLetter || character.isNumber {
                if wordStart == nil { wordStart = index }
            } else if let start = wordStart {
                let range = start..<index
                result.append(Word(canonical: text[range].lowercased(), range: range))
                wordStart = nil
            }
        }

        if let start = wordStart {
            let range = start..<text.endIndex
            result.append(Word(canonical: text[range].lowercased(), range: range))
        }
        return result
    }
}

/// Capture boundary used by the transcription controller.
///
/// Keeping capture lifecycle and callbacks behind this dependency lets callers
/// provide a different capture implementation without changing session gating.
protocol TranscriptionCaptureSession: AnyObject {
    var healthSnapshot: CaptureHealthMetrics { get }
    func startMicrophone(
        sessionID: UUID,
        callback: @escaping @Sendable (UUID, AudioCaptureFrame) -> Void
    ) throws
    func startAppAudio(
        sessionID: UUID,
        source: AppPickerWindowController.AudioSource,
        callback: @escaping @Sendable (UUID, CMSampleBuffer) -> Void,
        errorCallback: @escaping @Sendable (UUID, Error) -> Void
    ) async throws
    /// Requests capture shutdown without awaiting. This is safe on callback
    /// and other hot paths because it performs no async I/O.
    func requestStop()
    /// Awaits durable retirement of any in-flight capture start and its stream.
    func stopAndWait() async throws
    /// Stops only the app/system-audio stream, preserving microphone capture.
    func stopAppAudio()
    /// Stops every active capture source.
    func stop()
}

extension TranscriptionCaptureSession {
    var healthSnapshot: CaptureHealthMetrics { .zero }
    func requestStop() { stop() }
    func stopAndWait() async throws {}
}

/// Platform capture implementation used by the application.
final class LiveTranscriptionCaptureSession: @unchecked Sendable, TranscriptionCaptureSession {
    private let micCapture = AudioCapture()
    private let screenCapture = ScreenAudioCapture()
    private let healthLock = NSLock()

    var healthSnapshot: CaptureHealthMetrics {
        healthLock.lock()
        defer { healthLock.unlock() }
        return CaptureHealthMetrics(microphoneDroppedBuffers: micCapture.droppedBufferCount)
    }

    func startMicrophone(
        sessionID: UUID,
        callback: @escaping @Sendable (UUID, AudioCaptureFrame) -> Void
    ) throws {
        healthLock.lock()
        defer { healthLock.unlock() }
        try micCapture.start(sessionID: sessionID, onPCMFloatBuffer: callback)
    }

    func startAppAudio(
        sessionID: UUID,
        source: AppPickerWindowController.AudioSource,
        callback: @escaping @Sendable (UUID, CMSampleBuffer) -> Void,
        errorCallback: @escaping @Sendable (UUID, Error) -> Void
    ) async throws {
        if source.isSystemAudio, let display = source.display {
            try await screenCapture.selectDisplay(
                display: display,
                sessionID: sessionID,
                onAudioSampleBuffer: callback,
                onStreamError: errorCallback
            )
        } else if let app = source.app {
            try await screenCapture.selectApp(
                app: app,
                sessionID: sessionID,
                onAudioSampleBuffer: callback,
                onStreamError: errorCallback
            )
        } else {
            throw NSError(domain: "TranscriptionController", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Invalid audio source"
            ])
        }
    }

    func requestStop() {
        healthLock.lock()
        defer { healthLock.unlock() }
        micCapture.stop()
        screenCapture.requestStop()
    }

    func stopAndWait() async throws {
        requestStop()
        try await screenCapture.stopAndWait()
    }

    func stopAppAudio() {
        screenCapture.requestStop()
    }

    func stop() {
        requestStop()
    }
}

/// Orchestrates audio capture, mixing, and transcription.
///
/// ## Thread Safety
/// This class is marked `@unchecked Sendable` because:
/// - Audio buffers are protected by `OSAllocatedUnfairLock`
/// - All member classes (AudioCapture, ScreenAudioCapture, AudioMixer, etc.) are Sendable
/// - UI callbacks are dispatched to MainActor
///
/// ## Threading Model
/// - Audio callbacks arrive from audio render threads (high priority)
/// - Transcription runs on background queues (userInitiated)
/// - UI updates are dispatched to MainActor

/// Timing boundary used by the controller. Tests provide a manual scheduler;
/// production uses monotonic DispatchTime, so lifecycle tests never wait on wall
/// clock time or poll for completion.
protocol TranscriptionScheduler: AudioCompositionScheduler {
    var nowNanoseconds: UInt64 { get }
}

struct DispatchTranscriptionScheduler: TranscriptionScheduler, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.mactalk.transcription-timers", qos: .userInitiated)

    var nowNanoseconds: UInt64 { DispatchTime.now().uptimeNanoseconds }

    func schedule(
        deadlineNanoseconds: UInt64,
        operation: @escaping @Sendable () -> Void
    ) -> any AudioCompositionScheduledTask {
        let workItem = DispatchWorkItem(block: operation)
        queue.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: deadlineNanoseconds), execute: workItem)
        return DispatchCompositionScheduledTask(workItem: workItem)
    }
}

final class TranscriptionController: @unchecked Sendable {
    enum Mode: Sendable {
        case micOnly
        case micPlusAppAudio
    }

    private enum TerminalResult {
        case noSpeech
        case completed(OutputResult?)
        case inferenceFailed
    }

    // MARK: - Properties

    private let captureSession: any TranscriptionCaptureSession
    private let settingsStore: AppSettings
    private let timingScheduler: any TranscriptionScheduler
    private let lifecycleState = OSAllocatedUnfairLock(initialState: ControllerLifecycleState())
    private let mixer: AudioMixer
    private let micStream: AudioMixer.Stream
    private let appStream: AudioMixer.Stream
    private let engine: any ASREngine
    private let metricsStore: any PipelineMetricsStoring
    private let observability: PipelineObservabilityEmitter
    private let batteryModeSnapshot: Bool
    private struct SessionLifecycle {
        let recorder: PipelineSessionRecorder
        let signpostID: OSSignpostID
        var microphoneDropBaseline: UInt64?
        var microphoneStarted = false
        var cancellationRequested = false
        var finalizationStarted = false
    }
    // Recorder, baseline, signpost, and terminal state are published/taken as
    // one unit. No asynchronous work or I/O is performed while this lock is held.
    private let sessionLifecycle = OSAllocatedUnfairLock(initialState: [UUID: SessionLifecycle]())
    // Every terminal path claims the same per-session task. Keeping ownership
    // in a lock-protected registry prevents timer/cleanup/replacement races
    // without ever awaiting while the lock is held.
    private struct FinalizationEntry {
        let token: UUID
        let task: Task<Void, Never>
    }
    private struct FinalizationClaim {
        let token: UUID
        let task: Task<Void, Never>
    }
    private struct ExplicitCleanupEntry {
        let token: UUID
        let task: Task<Void, Error>
    }
    private struct ExplicitCleanupClaim {
        let token: UUID
        let task: Task<Void, Error>
    }
    private let finalizationTasks = OSAllocatedUnfairLock(initialState: [UUID: FinalizationEntry]())
    private let explicitCleanupTasks = OSAllocatedUnfairLock(initialState: [UUID: ExplicitCleanupEntry]())
    private let captureRetirementFailures = OSAllocatedUnfairLock(initialState: Set<UUID>())
    private let levelMonitor = MultiChannelLevelMonitor()
    private let audioSessionGate = AudioSessionGate()
    /// Separately gates queued ScreenCaptureKit callbacks so app-audio fallback
    /// can invalidate that stream without interrupting the microphone session.
    private let appAudioGate = AudioSessionGate()
    /// The sole append path for both sources. Its queue is independent from
    /// audioState, avoiding lock-order inversions at callback boundaries.
    private let compositionOwnerBox: CompositionOwnerBox
    private let compositionPipeline: SerializedAudioCompositionPipeline

    private let chunkDurationMs: Int = 3000  // 3 seconds for better context
    private let firstChunkDurationMs: Int = 1500  // 1.5 seconds for fast first result
    private let samplesPerMs = 16  // 16kHz sample rate
    private let maxFinalAudioSamples: Int
    private let finalAudioTrimMarginSamples: Int
    private let tailDrainMs: Int = 100
    private let diagnosticsQueue = DispatchQueue(label: "com.mactalk.audio.diagnostics", qos: .utility)
    private let audioDiagnosticsEnabled = false
    private let audioDiagnosticsInterval: TimeInterval = 1.0
    /// Inert unless MACTALK_AUDIO_HARDWARE_VALIDATION_LOG is explicitly set.
    /// This records timestamp metadata only; samples and transcript text never
    /// enter the validation file.
    private let hardwareValidationRecorder: AudioHardwareValidationRecorder

    /// Audio buffer state protected by OSAllocatedUnfairLock.
    private struct PendingChunkTask {
        let id: UUID
        let task: Task<Void, Never>
    }

    private struct AudioState {
        var audioChunk: [Float] = []
        var allAudio: [Float] = []  // Store recent audio for final transcription
        var fullTranscript: [String] = []
        var currentMode: Mode = .micOnly
        var currentChunkDuration: Int
        var isFirstChunk: Bool = true
        var lastUIUpdateTime: TimeInterval = 0
        var lastDiagnosticsLogTime: TimeInterval = 0
        var sessionID: UUID
        var pendingTasks: [UUID: [PendingChunkTask]] = [:]
        var chunkProcessingTail: Task<Void, Never>?
        var language: String?
        var isStopping = false

        init(chunkDuration: Int, language: String?) {
            self.currentChunkDuration = chunkDuration
            self.sessionID = UUID()
            self.language = language
        }
    }

    private let audioState: OSAllocatedUnfairLock<AudioState>

    var onPartial: (@Sendable @MainActor (String) -> Void)?
    var onFinal: (@Sendable @MainActor (String) -> OutputResult?)?
    var onMicLevel: (@Sendable @MainActor (AudioLevelMonitor.LevelData) -> Void)?
    var onAppLevel: (@Sendable @MainActor (AudioLevelMonitor.LevelData) -> Void)?
    var onAppAudioLost: (@Sendable @MainActor () -> Void)?  // Callback when app audio is lost
    var onMicrophoneReady: (@Sendable @MainActor () -> Void)?
    var onFallbackToMicOnly: (@Sendable @MainActor () -> Void)?  // Callback when falling back to mic-only
    var onFinalizationComplete: (@Sendable @MainActor () -> Void)?

    // Performance optimization
    private var adaptiveQualityEnabled = true
    private let uiUpdateThrottle: TimeInterval = 0.1  // 100ms

    // MARK: - Initialization

    init(
        engine: any ASREngine,
        captureSession: any TranscriptionCaptureSession = LiveTranscriptionCaptureSession(),
        settings: AppSettings = .shared,
        scheduler: any TranscriptionScheduler = DispatchTranscriptionScheduler(),
        metricsStore: any PipelineMetricsStoring = PipelineMetricsStore.shared,
        observability: PipelineObservabilityEmitter = .live,
        batteryModeSnapshot: Bool = false,
        maxFinalAudioSamples: Int = 9_600_000,
        finalAudioTrimMarginSamples: Int = 160_000
    ) {
        let mixer = AudioMixer()
        let ownerBox = CompositionOwnerBox()
        self.captureSession = captureSession
        self.settingsStore = settings
        self.timingScheduler = scheduler
        self.compositionOwnerBox = ownerBox
        self.compositionPipeline = SerializedAudioCompositionPipeline(
            scheduler: scheduler,
            emit: { [weak ownerBox] sessionID, samples in
                ownerBox?.owner?.appendSamples(samples, sessionID: sessionID, allowStopping: true)
            },
            microphoneReady: { [weak ownerBox] sessionID in
                guard let owner = ownerBox?.owner, owner.audioSessionGate.accepts(sessionID) else { return }
                if let onMicrophoneReady = owner.onMicrophoneReady {
                    Task { @MainActor in onMicrophoneReady() }
                }
            }
        )
        self.mixer = mixer
        self.micStream = mixer.makeStream()
        self.appStream = mixer.makeStream()
        self.engine = engine
        self.metricsStore = metricsStore
        self.observability = observability
        self.batteryModeSnapshot = batteryModeSnapshot
        self.maxFinalAudioSamples = max(1, maxFinalAudioSamples)
        self.finalAudioTrimMarginSamples = max(1, finalAudioTrimMarginSamples)
        self.hardwareValidationRecorder = AudioHardwareValidationRecorder.fromEnvironment()
        self.audioState = OSAllocatedUnfairLock(
            initialState: AudioState(chunkDuration: chunkDurationMs, language: "en")
        )
        ownerBox.owner = self

        // Adapt to battery mode if enabled (check asynchronously)
        if adaptiveQualityEnabled {
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if PerformanceMonitor.currentBatteryMode {
                    self.configureBatteryMode(true)
                }
            }
        }
    }

    var provider: ASRProvider {
        engine.provider
    }

    private func recorder(for sessionID: UUID) -> PipelineSessionRecorder? {
        sessionLifecycle.withLock { $0[sessionID]?.recorder }
    }

    private func claimFinalization(
        sessionID: UUID,
        operation: @escaping @Sendable () async -> Void
    ) -> FinalizationClaim {
        finalizationTasks.withLock { tasks in
            if let existing = tasks[sessionID] {
                return FinalizationClaim(token: existing.token, task: existing.task)
            }
            let token = UUID()
            let task = Task { await operation() }
            tasks[sessionID] = FinalizationEntry(token: token, task: task)
            return FinalizationClaim(token: token, task: task)
        }
    }

    private func existingFinalization(sessionID: UUID) -> FinalizationClaim? {
        finalizationTasks.withLock {
            guard let entry = $0[sessionID] else { return nil }
            return FinalizationClaim(token: entry.token, task: entry.task)
        }
    }

    private func replaceFinalization(
        sessionID: UUID,
        replacing token: UUID,
        operation: @escaping @Sendable () async -> Void
    ) -> FinalizationClaim {
        finalizationTasks.withLock { tasks in
            if let existing = tasks[sessionID], existing.token != token {
                return FinalizationClaim(token: existing.token, task: existing.task)
            }
            let replacementToken = UUID()
            let task = Task { await operation() }
            tasks[sessionID] = FinalizationEntry(token: replacementToken, task: task)
            return FinalizationClaim(token: replacementToken, task: task)
        }
    }

    private func claimExplicitCleanup(
        sessionID: UUID,
        operation: @escaping @Sendable () async throws -> Void
    ) -> ExplicitCleanupClaim {
        explicitCleanupTasks.withLock { tasks in
            if let existing = tasks[sessionID] {
                return ExplicitCleanupClaim(token: existing.token, task: existing.task)
            }
            let token = UUID()
            let task = Task { try await operation() }
            tasks[sessionID] = ExplicitCleanupEntry(token: token, task: task)
            return ExplicitCleanupClaim(token: token, task: task)
        }
    }

    private func pruneExplicitCleanup(sessionID: UUID, token: UUID) {
        explicitCleanupTasks.withLock { tasks in
            guard tasks[sessionID]?.token == token else { return }
            tasks.removeValue(forKey: sessionID)
        }
    }

    private func recordCaptureRetirementFailure(sessionID: UUID) {
        captureRetirementFailures.withLock { $0.insert(sessionID) }
    }

    private func throwCaptureRetirementFailureIfNeeded(sessionID: UUID) throws {
        let failed = captureRetirementFailures.withLock { $0.contains(sessionID) }
        if failed { throw ScreenCaptureLifecycleError.stopFailed }
    }

    private func completeStoppingSafely(sessionID: UUID) async {
        do {
            try await completeStopping(sessionID: sessionID)
        } catch {
            PipelineLog.captureRetirementFailed()
            recordCaptureRetirementFailure(sessionID: sessionID)
        }
    }

    private func completeStoppingForExplicitRetry(sessionID: UUID) async {
        do {
            try await completeStopping(sessionID: sessionID)
            _ = captureRetirementFailures.withLock { $0.remove(sessionID) }
        } catch {
            PipelineLog.captureRetirementFailed()
            recordCaptureRetirementFailure(sessionID: sessionID)
        }
    }

    private func pruneFinalization(sessionID: UUID, token: UUID) {
        // A completed waiter may be stale if a replacement claimed the same
        // session ID before that waiter resumed. Only the current token may
        // remove the registry entry.
        finalizationTasks.withLock { tasks in
            guard tasks[sessionID]?.token == token else { return }
            tasks.removeValue(forKey: sessionID)
        }
    }

    private func awaitFinalization(
        sessionID: UUID,
        operation: @escaping @Sendable () async -> Void
    ) async {
        let claim = claimFinalization(sessionID: sessionID, operation: operation)
        await claim.task.value
        pruneFinalization(sessionID: sessionID, token: claim.token)
    }

    private func reserveStartGeneration(sessionID: UUID) -> StartGeneration {
        lifecycleState.withLock { state in
            state.nextGeneration &+= 1
            let generation = StartGeneration(sequence: state.nextGeneration, sessionID: sessionID)
            state.activeGeneration = generation
            return generation
        }
    }

    private func invalidateStartGeneration(_ generation: StartGeneration) {
        lifecycleState.withLock { state in
            guard state.activeGeneration == generation else { return }
            state.activeGeneration = nil
        }
    }

    private func owns(_ generation: StartGeneration) -> Bool {
        lifecycleState.withLock { $0.activeGeneration == generation }
    }

    private func cancelScheduledStop() {
        let scheduled = lifecycleState.withLock { state -> ScheduledStop? in
            defer { state.scheduledStop = nil }
            return state.scheduledStop
        }
        scheduled?.task?.cancel()
    }

    private func reserveScheduledStop(token: UUID) {
        let previous = lifecycleState.withLock { state -> ScheduledStop? in
            let previous = state.scheduledStop
            state.scheduledStop = ScheduledStop(token: token, task: nil)
            return previous
        }
        previous?.task?.cancel()
    }

    private func installScheduledStop(_ task: any AudioCompositionScheduledTask, token: UUID) {
        let previous = lifecycleState.withLock { state -> ScheduledStop? in
            guard state.scheduledStop?.token == token else { return nil }
            let previous = state.scheduledStop
            state.scheduledStop?.task = task
            return previous
        }
        previous?.task?.cancel()
    }

    private func clearScheduledStop(token: UUID) {
        let scheduled = lifecycleState.withLock { state -> ScheduledStop? in
            guard state.scheduledStop?.token == token else { return nil }
            defer { state.scheduledStop = nil }
            return state.scheduledStop
        }
        scheduled?.task?.cancel()
    }

    private func isSessionActive(_ sessionID: UUID) -> Bool {
        sessionLifecycle.withLock { lifecycle in
            guard let lifecycle = lifecycle[sessionID] else { return false }
            return !lifecycle.cancellationRequested && !lifecycle.finalizationStarted
        }
    }

    private func installRecorder(for sessionID: UUID, settings: SettingsSnapshot) {
        let modelID = settings.provider == .whisper ? settings.whisperModelID : "parakeet"
        let context = PipelineSessionContext(
            id: sessionID,
            provider: settings.provider,
            modelID: modelID,
            captureMode: settings.captureMode,
            language: settings.language,
            batteryMode: batteryModeSnapshot,
            startedAt: Date()
        )
        let recorder = PipelineSessionRecorder(context: context, nowNanoseconds: { [timingScheduler] in timingScheduler.nowNanoseconds })
        let signpostID = PipelineSignposts.sessionID()
        sessionLifecycle.withLock { lifecycles in
            lifecycles[sessionID] = SessionLifecycle(recorder: recorder, signpostID: signpostID, microphoneDropBaseline: nil)
        }
        recorder.recordResourceCheckpoint(residentMemoryBytes: residentMemoryBytes())
        observability.beginSession(signpostID, context: context)
    }

    private func publishMicrophoneDropBaseline(for sessionID: UUID) {
        let baseline = captureSession.healthSnapshot.microphoneDroppedBuffers
        sessionLifecycle.withLock { lifecycles in
            guard var lifecycle = lifecycles[sessionID], !lifecycle.cancellationRequested else { return }
            lifecycle.microphoneDropBaseline = baseline
            lifecycle.microphoneStarted = false
            lifecycles[sessionID] = lifecycle
        }
    }

    private func markMicrophoneStarted(sessionID: UUID) {
        sessionLifecycle.withLock { lifecycles in
            guard var lifecycle = lifecycles[sessionID], !lifecycle.cancellationRequested else { return }
            lifecycle.microphoneStarted = true
            lifecycles[sessionID] = lifecycle
        }
    }

    private func takeLifecycle(for sessionID: UUID) -> SessionLifecycle? {
        sessionLifecycle.withLock { lifecycles in
            guard var lifecycle = lifecycles.removeValue(forKey: sessionID) else { return nil }
            lifecycle.finalizationStarted = true
            return lifecycle
        }
    }

    private func finalizeRecorder(sessionID: UUID, outcome: PipelineSessionOutcome, composition: AudioCompositionMetrics? = nil) async {
        guard let lifecycle = takeLifecycle(for: sessionID) else { return }
        lifecycle.recorder.recordResourceCheckpoint(residentMemoryBytes: residentMemoryBytes())
        var capture = captureSession.healthSnapshot
        let baseline = lifecycle.microphoneStarted ? (lifecycle.microphoneDropBaseline ?? 0) : capture.microphoneDroppedBuffers
        capture.microphoneDroppedBuffers = lifecycle.microphoneStarted ? (capture.microphoneDroppedBuffers >= baseline ? capture.microphoneDroppedBuffers - baseline : 0) : 0
        let report = lifecycle.recorder.finish(outcome: outcome, capture: capture, composition: composition ?? audioCompositionMetrics)
        // Controlled terminal paths await persistence before reporting lifecycle
        // completion. The summary is emitted only after this durable boundary.
        await metricsStore.record(report)
        observability.endSession(lifecycle.signpostID, context: report.context)
        observability.persistedSummary(report)
    }

    deinit {
        let lifecycles = sessionLifecycle.withLock { lifecycles -> [SessionLifecycle] in
            let values = Array(lifecycles.values)
            lifecycles.removeAll()
            return values
        }
        for lifecycle in lifecycles {
            lifecycle.recorder.recordResourceCheckpoint(residentMemoryBytes: residentMemoryBytes())
            let report = lifecycle.recorder.finish(outcome: .cancelled, capture: captureSession.healthSnapshot, composition: audioCompositionMetrics)
            Task { [metricsStore, observability] in
                await metricsStore.record(report)
                observability.endSession(lifecycle.signpostID, context: report.context)
                observability.persistedSummary(report)
            }
        }
    }

    private func residentMemoryBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }

    private func pipelineInsertOutcome(_ outcome: AutoInsertOutcome) -> PipelineInsertOutcome {
        switch outcome {
        case .notAttempted: return .notAttempted
        case .axSetValueSuccess: return .inserted
        case .cmdVFallback: return .cmdVScheduledUnverified
        case .permissionDenied: return .permissionDenied
        case .failed: return .failed
        case .skippedTargetChanged: return .targetChanged
        case .rejected: return .rejected
        }
    }

    var audioCompositionMetrics: AudioCompositionMetrics {
        compositionPipeline.metrics
    }

    func isUsingEngine(_ candidate: any ASREngine) -> Bool {
        ObjectIdentifier(engine as AnyObject) == ObjectIdentifier(candidate as AnyObject)
    }

    var language: String? {
        get {
            audioState.withLock { state in
                state.language
            }
        }
        set {
            audioState.withLock { state in
                state.language = newValue
            }
        }
    }

    // MARK: - Control

    func start(
        mode: Mode,
        audioSource: AppPickerWindowController.AudioSource? = nil,
        settingsSnapshot: SettingsSnapshot? = nil
    ) async throws {
        // A supplied snapshot is the complete recording contract. Keep the
        // legacy mode parameter for callers that have not migrated yet, but do
        // not let it override an immutable session snapshot.
        let recordingSettings = settingsSnapshot ?? settingsStore.snapshotAtRecordingStart()
        let recordingMode: Mode = settingsSnapshot.map {
            $0.captureMode == .micPlusAppAudio ? .micPlusAppAudio : .micOnly
        } ?? mode
        let recorderSettings = settingsSnapshot ?? recordingSettings.withCaptureMode(
            recordingMode == .micPlusAppAudio ? .micPlusAppAudio : .micOnly
        )
        DLOG("Transcription start requested: mode=\(recordingMode)")

        // Publish ownership before the first await. A cancellation or
        // replacement during prior-session finalization can then invalidate
        // this generation synchronously and prevent any later side effect.
        let generation = reserveStartGeneration(sessionID: UUID())
        cancelScheduledStop()
        guard !Task.isCancelled, owns(generation) else { throw CancellationError() }

        // Invalidate callbacks from any previous capture before resetting the
        // streams. ScreenCaptureKit may still deliver a queued callback after
        // stopCapture has been requested. A pending deterministic stop belongs
        // to the old session and must never flush the new one.
        if settingsSnapshot != nil, recordingSettings.provider != engine.provider {
            throw NSError(domain: "TranscriptionController", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Settings provider does not match the selected transcription engine"
            ])
        }
        let previousSessionID = audioState.withLock { $0.sessionID }
        audioSessionGate.stop()
        appAudioGate.stop()
        captureSession.requestStop()
        try await captureSession.stopAndWait()
        compositionPipeline.cancel(sessionID: previousSessionID)
        await cancelPendingChunkTasks(sessionID: previousSessionID)
        guard !Task.isCancelled, owns(generation) else {
            invalidateStartGeneration(generation)
            throw CancellationError()
        }
        let previousComposition = audioCompositionMetrics
        await awaitFinalization(sessionID: previousSessionID) { [weak self] in
            guard let self else { return }
            await self.finalizeRecorder(sessionID: previousSessionID, outcome: .cancelled, composition: previousComposition)
        }

        try Task.checkCancellation()
        guard owns(generation) else { throw CancellationError() }
        let sessionID = generation.sessionID
        audioSessionGate.begin(sessionID)
        installRecorder(for: sessionID, settings: recorderSettings)

        // Clear previous state
        guard !Task.isCancelled, owns(generation) else {
            try await cancelStartAndWait(sessionID: sessionID)
            throw CancellationError()
        }
        micStream.reset()
        appStream.reset()
        audioState.withLock { state in
            state.audioChunk.removeAll()
            state.allAudio.removeAll()
            state.fullTranscript.removeAll()
            state.currentMode = recordingMode
            state.isFirstChunk = true
            state.lastUIUpdateTime = 0
            state.lastDiagnosticsLogTime = 0
            state.sessionID = sessionID
            state.language = recordingSettings.language
            state.pendingTasks[sessionID] = []
            state.chunkProcessingTail = nil
            state.isStopping = false
        }
        compositionPipeline.reset(
            sessionID: sessionID,
            mode: recordingMode == .micPlusAppAudio ? .microphoneAndApplication : .microphoneOnly
        )

        // Publish the baseline before creating the capture delivery. Drops
        // during microphone startup therefore belong to this session.
        publishMicrophoneDropBaseline(for: sessionID)
        guard !Task.isCancelled, owns(generation), audioSessionGate.accepts(sessionID) else {
            try await cancelStartAndWait(sessionID: sessionID)
            throw CancellationError()
        }

        // Start microphone capture FIRST so we don't lose the beginning
        // of the user's speech while the engine prepares.
        do {
            guard !Task.isCancelled, owns(generation), audioSessionGate.accepts(sessionID) else {
                throw CancellationError()
            }
            try captureSession.startMicrophone(sessionID: sessionID) { [weak self] callbackSessionID, frame in
                self?.processAudioFrame(frame, sessionID: callbackSessionID)
            }
            markMicrophoneStarted(sessionID: sessionID)
        } catch is CancellationError {
            try await cancelStartAndWait(sessionID: sessionID, outcome: .cancelled)
            throw CancellationError()
        } catch {
            // A microphone start failure must invalidate the session and stop
            // any partially initialized capture before surfacing the error.
            try await cancelStartAndWait(sessionID: sessionID, outcome: .startFailed)
            throw error
        }
        guard audioSessionGate.accepts(sessionID), isSessionActive(sessionID) else {
            captureSession.requestStop()
            try await captureSession.stopAndWait()
            await awaitFinalization(sessionID: sessionID) { [weak self] in
                guard let self else { return }
                await self.finalizeRecorder(sessionID: sessionID, outcome: .cancelled)
            }
            throw CancellationError()
        }
        DLOG("Mic capture started (pre-roll buffering while engine prepares)")
        print("🎤 Mic capture started (pre-roll buffering while engine prepares)")

        // Set up app audio capture if needed (also starts immediately)
        if case .micPlusAppAudio = recordingMode {
            guard !Task.isCancelled, owns(generation), audioSessionGate.accepts(sessionID) else {
                try await cancelStartAndWait(sessionID: sessionID)
                throw CancellationError()
            }
            guard let source = audioSource else {
                try await cancelStartAndWait(sessionID: sessionID, outcome: .startFailed)
                throw NSError(domain: "TranscriptionController", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Audio source required for mic+app mode"
                ])
            }

            let appGeneration = appAudioGate.begin()
            do {
                try await captureSession.startAppAudio(
                    sessionID: sessionID,
                    source: source,
                    callback: { [weak self] callbackSessionID, sampleBuffer in
                        self?.processSampleBuffer(
                            sampleBuffer,
                            sessionID: callbackSessionID,
                            appGeneration: appGeneration
                        )
                    },
                    errorCallback: { [weak self] callbackSessionID, error in
                        guard let self else { return }
                        // Validate before fallback. Capture shutdown and state
                        // mutation must never occur under the gate lock.
                        guard self.audioSessionGate.accepts(callbackSessionID),
                              self.appAudioGate.accepts(appGeneration) else { return }
                        self.handleAppAudioError(error, sessionID: callbackSessionID)
                    }
                )
                try Task.checkCancellation()
                guard owns(generation), audioSessionGate.accepts(sessionID), isSessionActive(sessionID) else {
                    throw CancellationError()
                }
            } catch is CancellationError {
                try await cancelStartAndWait(sessionID: sessionID, outcome: .cancelled)
                throw CancellationError()
            } catch {
                try await cancelStartAndWait(sessionID: sessionID, outcome: .startFailed)
                throw error
            }
        }

        // Now prepare the engine — audio is already being captured and
        // buffered in audioChunk/allAudio while this runs. If preparation fails,
        // stop captures here so direct callers cannot leave the microphone active.
        guard !Task.isCancelled, owns(generation), isSessionActive(sessionID) else {
            try await cancelStartAndWait(sessionID: sessionID)
            throw CancellationError()
        }
        recorder(for: sessionID)?.recordPrepareStarted()
        do {
            try await engine.prepare()
            try Task.checkCancellation()
            guard owns(generation), audioSessionGate.accepts(sessionID), isSessionActive(sessionID) else {
                try await cancelStartAndWait(sessionID: sessionID)
                throw CancellationError()
            }
            guard !Task.isCancelled, owns(generation), audioSessionGate.accepts(sessionID) else {
                throw CancellationError()
            }
            await engine.reset()
            try Task.checkCancellation()
            guard owns(generation), audioSessionGate.accepts(sessionID), isSessionActive(sessionID) else {
                try await cancelStartAndWait(sessionID: sessionID)
                throw CancellationError()
            }
            recorder(for: sessionID)?.recordPrepareCompleted()
        } catch is CancellationError {
            try await cancelStartAndWait(sessionID: sessionID, outcome: .cancelled)
            throw CancellationError()
        } catch {
            try await cancelStartAndWait(sessionID: sessionID, outcome: .startFailed)
            throw error
        }

        DLOG("Engine prepared/reset; transcription fully started in mode=\(recordingMode)")
        print("Transcription started in mode: \(recordingMode)")
    }

    func stop() {
        guard let sessionID = beginStopping() else { return }
        let deadline = timingScheduler.nowNanoseconds
            .addingReportingOverflow(UInt64(tailDrainMs) * 1_000_000)
        let stopDeadline = deadline.overflow ? UInt64.max : deadline.partialValue
        let token = UUID()
        reserveScheduledStop(token: token)
        let task = timingScheduler.schedule(deadlineNanoseconds: stopDeadline) { [weak self] in
            guard let self else { return }
            self.clearScheduledStop(token: token)
            let finalization = self.claimFinalization(sessionID: sessionID) { [weak self] in
                guard let self else { return }
                await self.completeStoppingSafely(sessionID: sessionID)
            }
            Task { [weak self] in
                await finalization.task.value
                self?.pruneFinalization(sessionID: sessionID, token: finalization.token)
            }
        }
        installScheduledStop(task, token: token)
        print("Transcription stopped")
    }

    /// Synchronously requests capture shutdown, then awaits the complete
    /// terminal pipeline including metrics persistence. This is the contract
    /// used by explicit lifecycle cleanup; normal UI stop remains scheduled.
    func stopAndWait() async throws {
        let alreadyStopping = audioState.withLock { state in
            state.isStopping ? state.sessionID : nil
        }
        guard let sessionID = alreadyStopping ?? beginStopping() else { return }
        let cleanup = claimExplicitCleanup(sessionID: sessionID) { [weak self] in
            guard let self else { return }
            try await self.performExplicitStopAndWait(sessionID: sessionID)
        }
        do {
            try await cleanup.task.value
            pruneExplicitCleanup(sessionID: sessionID, token: cleanup.token)
        } catch {
            pruneExplicitCleanup(sessionID: sessionID, token: cleanup.token)
            throw error
        }
    }

    private func performExplicitStopAndWait(sessionID: UUID) async throws {
        cancelScheduledStop()
        if let existing = existingFinalization(sessionID: sessionID) {
            await existing.task.value
            let retirementFailed = captureRetirementFailures.withLock { $0.contains(sessionID) }
            guard retirementFailed else { return }
            let retry = replaceFinalization(sessionID: sessionID, replacing: existing.token) { [weak self] in
                await self?.completeStoppingForExplicitRetry(sessionID: sessionID)
            }
            await retry.task.value
            pruneFinalization(sessionID: sessionID, token: retry.token)
            try throwCaptureRetirementFailureIfNeeded(sessionID: sessionID)
            return
        }

        await awaitFinalization(sessionID: sessionID) { [weak self] in
            await self?.completeStoppingForExplicitRetry(sessionID: sessionID)
        }
        try throwCaptureRetirementFailureIfNeeded(sessionID: sessionID)
    }

    private func beginStopping() -> UUID? {
        DLOG("Transcription stop requested")
        audioSessionGate.stop()
        appAudioGate.stop()
        let sessionID: UUID? = audioState.withLock { state in
            guard !state.isStopping else { return nil }
            state.isStopping = true
            return state.sessionID
        }
        guard let sessionID else {
            DLOG("Ignoring duplicate transcription stop request")
            return nil
        }
        recorder(for: sessionID)?.recordStopRequested()
        captureSession.requestStop()
        return sessionID
    }

    private func completeStopping(sessionID: UUID) async throws {
        try await captureSession.stopAndWait()
        finishAudioStreams(sessionID: sessionID)
        compositionPipeline.finish(sessionID: sessionID)
        let terminalResult = await flushFinalChunk(sessionID: sessionID)
        let outcome: PipelineSessionOutcome
        switch terminalResult {
        case .noSpeech: outcome = .noSpeech
        case .completed: outcome = .completed
        case .inferenceFailed: outcome = .inferenceFailed
        }
        await finalizeRecorder(sessionID: sessionID, outcome: outcome)

        audioState.withLock { state in
            if state.sessionID == sessionID {
                state.isStopping = false
            }
        }
        if let onFinalizationComplete {
            await onFinalizationComplete()
        }
    }

    /// Invalidates a start synchronously and returns a strong durability handle.
    func requestCancelStart() -> SessionCleanup {
        cancelScheduledStop()
        let sessionID = invalidateCurrentStart()
        let task = Task { [self] in
            do {
                try await self.captureSession.stopAndWait()
            } catch {
                PipelineLog.captureRetirementFailed()
                throw ScreenCaptureLifecycleError.stopFailed
            }
            await self.cancelPendingChunkTasks(sessionID: sessionID)
            await self.finalizeRecorder(sessionID: sessionID, outcome: .cancelled)
        }
        return SessionCleanup(task: task, owner: self)
    }

    private func invalidateCurrentStart() -> UUID {
        audioSessionGate.stop()
        appAudioGate.stop()
        captureSession.requestStop()
        let sessionID = audioState.withLock { $0.sessionID }
        let generation = lifecycleState.withLock { $0.activeGeneration }
        if let generation { invalidateStartGeneration(generation) }
        compositionPipeline.cancel(sessionID: sessionID)
        sessionLifecycle.withLock { lifecycles in
            guard var lifecycle = lifecycles[sessionID] else { return }
            lifecycle.cancellationRequested = true
            lifecycles[sessionID] = lifecycle
        }
        return sessionID
    }

    func cancelStart() async {
        let sessionID = invalidateCurrentStart()
        do {
            try await captureSession.stopAndWait()
        } catch {
            recordCaptureRetirementFailure(sessionID: sessionID)
            return
        }
        await awaitFinalization(sessionID: sessionID) { [weak self] in
            guard let self else { return }
            await self.cancelPendingChunkTasks(sessionID: sessionID)
            await self.finalizeRecorder(sessionID: sessionID, outcome: .cancelled)
        }
        print("Transcription start cancelled")
    }

    private func cancelStartAndWait(
        sessionID requestedSessionID: UUID? = nil,
        outcome: PipelineSessionOutcome = .cancelled
    ) async throws {
        let sessionID: UUID
        if let requestedSessionID {
            sessionID = requestedSessionID
            let wasAlreadyCancelled = sessionLifecycle.withLock { lifecycles in
                guard var lifecycle = lifecycles[sessionID] else { return true }
                if lifecycle.cancellationRequested { return true }
                lifecycle.cancellationRequested = true
                lifecycles[sessionID] = lifecycle
                return false
            }
            if !wasAlreadyCancelled {
                cancelScheduledStop()
                audioSessionGate.stop()
                appAudioGate.stop()
                captureSession.requestStop()
                try await captureSession.stopAndWait()
                compositionPipeline.cancel(sessionID: sessionID)
            }
        } else {
            sessionID = cancelStartAndReturnSession()
            try await captureSession.stopAndWait()
        }
        await awaitFinalization(sessionID: sessionID) { [weak self] in
            guard let self else { return }
            await self.cancelPendingChunkTasks(sessionID: sessionID)
            await self.finalizeRecorder(sessionID: sessionID, outcome: outcome)
        }
        print("Transcription start cancelled")
    }

    private func cancelStartAndReturnSession() -> UUID {
        cancelScheduledStop()
        audioSessionGate.stop()
        appAudioGate.stop()
        captureSession.requestStop()

        let sessionID = audioState.withLock { state in
            let sessionID = state.sessionID
            state.audioChunk.removeAll()
            state.allAudio.removeAll()
            state.fullTranscript.removeAll()
            state.sessionID = UUID()
            state.chunkProcessingTail = nil
            state.isStopping = false
            return sessionID
        }
        compositionPipeline.cancel(sessionID: sessionID)
        sessionLifecycle.withLock { lifecycles in
            guard var lifecycle = lifecycles[sessionID] else { return }
            lifecycle.cancellationRequested = true
            lifecycles[sessionID] = lifecycle
        }
        return sessionID
    }

    // MARK: - Audio Processing

    private func finishAudioStreams(sessionID: UUID) {
        guard audioState.withLock({ $0.sessionID == sessionID && $0.isStopping }) else { return }
        if let samples = micStream.finish(), !samples.isEmpty {
            compositionPipeline.ingestTail(
                sessionID: sessionID,
                source: .microphone,
                samples: samples
            )
        }
        if let samples = appStream.finish(), !samples.isEmpty {
            compositionPipeline.ingestTail(
                sessionID: sessionID,
                source: .application,
                samples: samples
            )
        }
    }

    private func emitFirstAudio(sessionID: UUID) {
        if let signpostID = sessionLifecycle.withLock({ $0[sessionID]?.signpostID }) {
            PipelineSignposts.firstAudio(signpostID)
        }
    }

    private func processAudioFrame(_ frame: AudioCaptureFrame, sessionID: UUID) {
        guard audioSessionGate.accepts(sessionID) else { return }
        guard let timestampNanos = UInt64ToHostNanoseconds(frame.firstSampleHostTime) else {
            compositionPipeline.recordInvalidTimestamp(
                sessionID: sessionID,
                source: .microphone
            )
            return
        }
        let conversionStart = timingScheduler.nowNanoseconds
        let samples = micStream.convert(samples: frame.samples, sampleRate: frame.sampleRate)
        let conversionEnd = timingScheduler.nowNanoseconds
        let conversionDuration = conversionEnd >= conversionStart ? conversionEnd - conversionStart : 0
        guard audioSessionGate.accepts(sessionID) else { return }
        guard let samples else {
            recorder(for: sessionID)?.recordMicrophoneInput(inputSamples: UInt64(frame.samples.count), convertedSamples: 0, conversionNanoseconds: conversionDuration, conversionFailed: true)
            return
        }
        if recorder(for: sessionID)?.recordMicrophoneInput(inputSamples: UInt64(frame.samples.count), convertedSamples: UInt64(samples.count), conversionNanoseconds: conversionDuration) == true {
            emitFirstAudio(sessionID: sessionID)
        }

        hardwareValidationRecorder.recordMicrophone(
            sessionID: sessionID,
            hostNanoseconds: timestampNanos,
            sampleCount: samples.count
        )

        // Update microphone level
        let micLevel = levelMonitor.update(channel: .microphone, buffer: samples)
        if let onMicLevel {
            Task { @MainActor [micLevel] in
                onMicLevel(micLevel)
            }
        }

        compositionPipeline.ingest(
            sessionID: sessionID,
            chunk: TimedAudioChunk(
                source: .microphone,
                start: AudioHostTimestamp(nanoseconds: timestampNanos),
                samples: samples
            )
        )
    }

    @discardableResult
    private func processSampleBuffer(
        _ sampleBuffer: CMSampleBuffer,
        sessionID: UUID,
        appGeneration: UUID
    ) -> Int? {
        // ScreenCaptureKit can deliver queued callbacks after stopAppAudio().
        // Reject them before touching the app stream converter. Invalid PTS is
        // a rejected callback too, but is counted for diagnostics.
        guard audioSessionGate.accepts(sessionID), appAudioGate.accepts(appGeneration) else {
            return nil
        }
        let presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard let timestamp = AudioHostTimestamp(
            presentationTimeStamp: presentationTimeStamp
        ) else {
            compositionPipeline.recordInvalidTimestamp(
                sessionID: sessionID,
                source: .application
            )
            return nil
        }
        let conversionStart = timingScheduler.nowNanoseconds
        let samples = mixer.convertSampleBuffer(sampleBuffer, using: appStream)
        let conversionEnd = timingScheduler.nowNanoseconds
        let conversionDuration = conversionEnd >= conversionStart ? conversionEnd - conversionStart : 0
        guard audioSessionGate.accepts(sessionID), appAudioGate.accepts(appGeneration) else {
            return nil
        }
        guard let samples else {
            recorder(for: sessionID)?.recordApplicationInput(callbacks: 1, samples: 0, conversionNanoseconds: conversionDuration, conversionFailed: true)
            return nil
        }
        if recorder(for: sessionID)?.recordApplicationInput(callbacks: 1, samples: UInt64(samples.count), conversionNanoseconds: conversionDuration) == true {
            emitFirstAudio(sessionID: sessionID)
        }

        hardwareValidationRecorder.recordApplication(
            sessionID: sessionID,
            ptsValue: presentationTimeStamp.value,
            ptsTimescale: presentationTimeStamp.timescale,
            mappedHostNanoseconds: timestamp.nanoseconds,
            sampleCount: samples.count
        )

        // Update app audio level
        let appLevel = levelMonitor.update(channel: .application, buffer: samples)
        if let onAppLevel {
            Task { @MainActor [appLevel] in
                onAppLevel(appLevel)
            }
        }

        compositionPipeline.ingest(
            sessionID: sessionID,
            chunk: TimedAudioChunk(source: .application, start: timestamp, samples: samples)
        )
        return samples.count
    }

    private func appendSamples(
        _ samples: [Float],
        sessionID: UUID? = nil,
        allowStopping: Bool = false
    ) {
        logAudioDiagnosticsIfNeeded(samples)

        let usesIncrementalChunks = engine.provider.usesIncrementalChunkProcessing
        let (chunkCount, threshold, trimmedSamples) = audioState.withLock { state -> (Int, Int, Int) in
            // Session validation uses the state snapshot while its lock is held;
            // never acquire the session gate while holding audioState.
            if let sessionID, state.sessionID != sessionID || (state.isStopping && !allowStopping) {
                return (state.audioChunk.count, Int.max, 0)
            }
            if usesIncrementalChunks {
                state.audioChunk.append(contentsOf: samples)
            }
            state.allAudio.append(contentsOf: samples)

            var trimmedSamples = 0
            if state.allAudio.count > maxFinalAudioSamples + finalAudioTrimMarginSamples {
                let overflow = state.allAudio.count - maxFinalAudioSamples
                state.allAudio.removeFirst(overflow)
                trimmedSamples = overflow
            }

            // Use shorter duration for the first chunk to reduce latency
            let effectiveDuration = state.isFirstChunk ? firstChunkDurationMs : state.currentChunkDuration
            return (state.audioChunk.count, samplesPerMs * effectiveDuration, trimmedSamples)
        }
        if let sessionID {
            if recorder(for: sessionID)?.recordComposedOutput(samples: UInt64(samples.count)) == true,
               let signpostID = sessionLifecycle.withLock({ $0[sessionID]?.signpostID }) {
                PipelineSignposts.firstComposedAudio(signpostID)
            }
            if trimmedSamples > 0 { recorder(for: sessionID)?.recordTrimmedAudio(samples: UInt64(trimmedSamples)) }
        }

        // FluidAudio's shared Parakeet manager can stall when an incremental
        // request is cancelled immediately before final inference. Use one
        // final request for Parakeet; Whisper keeps live incremental updates.
        if usesIncrementalChunks, chunkCount >= threshold {
            processChunk()
        }
    }

    private func processChunk() {
        let snapshot: (samples: [Float], sessionID: UUID, language: String?)? = audioState.withLock { state in
            let effectiveDuration = state.isFirstChunk ? firstChunkDurationMs : state.currentChunkDuration
            let threshold = samplesPerMs * effectiveDuration
            guard state.audioChunk.count >= threshold else {
                return nil
            }

            let samples = Array(state.audioChunk.prefix(threshold))
            state.audioChunk.removeFirst(threshold)
            state.isFirstChunk = false  // Subsequent chunks use normal duration
            return (samples, state.sessionID, state.language)
        }

        guard let snapshot = snapshot else { return }

        let chunkSamples = snapshot.samples
        let sessionID = snapshot.sessionID
        let language = snapshot.language

        // Simple Voice Activity Detection (VAD) - skip if chunk is too quiet
        let rms = sqrt(chunkSamples.map { $0 * $0 }.reduce(0, +) / Float(chunkSamples.count))
        let silenceThreshold: Float = 0.005  // Lowered to catch quieter speech

        if rms < silenceThreshold {
            recorder(for: sessionID)?.recordVADSkip()
            print("🔇 Skipping silent chunk (RMS: \(String(format: "%.4f", rms)))")
            return
        }

        DLOG("Processing chunk: samples=\(chunkSamples.count), RMS=\(String(format: "%.4f", rms))")
        print("🎤 Processing chunk with RMS: \(String(format: "%.4f", rms))")

        // Transcribe chunks on background tasks, serialized by the previous task tail.
        // Parakeet streaming carries decoder state between chunks, so chunk order matters.
        let taskID = UUID()
        recorder(for: sessionID)?.recordInferenceQueued(id: taskID, kind: .incremental, audioSamples: UInt64(chunkSamples.count))
        audioState.withLock { state in
            let previousTask = state.chunkProcessingTail
            let task = Task.detached(priority: .userInitiated) { [weak self, chunkSamples, sessionID, language, previousTask] in
                guard let self = self else { return }
                var succeeded = false
                _ = await previousTask?.value
                guard !Task.isCancelled else {
                    self.recorder(for: sessionID)?.recordInferenceCompleted(id: taskID, succeeded: false)
                    self.removePendingChunkTask(id: taskID, sessionID: sessionID)
                    return
                }
                let inferenceSignpostID = PipelineSignposts.inferenceID()
                PipelineSignposts.beginInference(inferenceSignpostID, kind: .incremental)
                defer {
                    PipelineSignposts.endInference(inferenceSignpostID)
                    self.recorder(for: sessionID)?.recordInferenceCompleted(id: taskID, succeeded: succeeded)
                    self.removePendingChunkTask(id: taskID, sessionID: sessionID)
                }
                self.recorder(for: sessionID)?.recordInferenceStarted(id: taskID)

                do {
                    let partial = try await self.engine.process(samples: chunkSamples, language: language)
                    succeeded = true

                    guard !Task.isCancelled else { return }

                    if let partial {
                        let trimmedText = partial.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmedText.isEmpty {
                            let didAppend = self.audioState.withLock { state in
                                guard state.sessionID == sessionID else { return false }
                                state.fullTranscript.append(trimmedText)
                                return true
                            }
                            if didAppend {
                                let presented = await self.throttledUIUpdate(trimmedText)
                                if presented,
                                   self.recorder(for: sessionID)?.recordPartialPresented() == true,
                                   let signpostID = self.sessionLifecycle.withLock({ $0[sessionID]?.signpostID }) {
                                    PipelineSignposts.firstPartial(signpostID)
                                }
                            }
                        }
                    }
                } catch {
                    DebugLogger.shared.log(.error(description: error.localizedDescription))
                }
            }

            guard state.sessionID == sessionID else {
                task.cancel()
                return
            }
            state.pendingTasks[sessionID, default: []].append(PendingChunkTask(id: taskID, task: task))
            state.chunkProcessingTail = task
        }
    }

    private func flushFinalChunk(sessionID: UUID) async -> TerminalResult {
        let snapshot: (audio: [Float], language: String?) = audioState.withLock { state in
            guard state.sessionID == sessionID else { return ([], nil) }
            let audio = state.allAudio
            state.audioChunk.removeAll()
            state.allAudio.removeAll()
            return (audio, state.language)
        }

        guard !snapshot.audio.isEmpty else {
            return await emitFinalTranscript(sessionID: sessionID)
        }

        // Check if audio is mostly silent
        let rms = sqrt(snapshot.audio.map { $0 * $0 }.reduce(0, +) / Float(snapshot.audio.count))
        let silenceThreshold: Float = 0.005  // Lowered threshold

        if rms < silenceThreshold {
            recorder(for: sessionID)?.recordVADSkip()
            print("🔇 Skipping silent final audio (RMS: \(String(format: "%.4f", rms)))")
            return await emitFinalTranscript(sessionID: sessionID)
        }

        DLOG("Processing final transcription with ALL audio: samples=\(snapshot.audio.count), RMS=\(String(format: "%.4f", rms))")
        print("🎤 Processing final transcription with ALL audio: \(snapshot.audio.count) samples (RMS: \(String(format: "%.4f", rms)))")

        // Capture the in-flight partial tasks before starting final inference.
        // Whisper permits both requests to run concurrently, but final output
        // must not become observable until the partial has delivered its UI
        // callback. Holding the final segment locally also prevents a late
        // partial from being appended after final text replaces the transcript.
        let pendingPartialTasks: [Task<Void, Never>] = audioState.withLock { state in
            guard state.sessionID == sessionID else { return [] }
            return state.pendingTasks[sessionID]?.map(\.task) ?? []
        }
        var finalText: String?

        // The final request may overlap queued partial work, but its signpost
        // begins at the actual engine call rather than including queue delay.
        let finalInferenceID = UUID()
        recorder(for: sessionID)?.recordInferenceQueued(id: finalInferenceID, kind: .final, audioSamples: UInt64(snapshot.audio.count))
        recorder(for: sessionID)?.recordInferenceStarted(id: finalInferenceID)
        var inferenceFailed = false
        let finalInferenceSignpostID = PipelineSignposts.inferenceID()
        PipelineSignposts.beginInference(finalInferenceSignpostID, kind: .final)
        do {
            let finalSegment = try await engine.finalize(samples: snapshot.audio, language: snapshot.language)
            PipelineSignposts.endInference(finalInferenceSignpostID)
            recorder(for: sessionID)?.recordInferenceCompleted(id: finalInferenceID, succeeded: true)
            recorder(for: sessionID)?.recordResourceCheckpoint(residentMemoryBytes: residentMemoryBytes())
            if let finalSegment {
                let trimmedText = finalSegment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedText.isEmpty {
                    DLOG("Final transcription result received: chars=\(trimmedText.count)")
                    finalText = trimmedText
                }
            }
        } catch {
            PipelineSignposts.endInference(finalInferenceSignpostID)
            inferenceFailed = true
            recorder(for: sessionID)?.recordInferenceCompleted(id: finalInferenceID, succeeded: false)
            recorder(for: sessionID)?.recordResourceCheckpoint(residentMemoryBytes: residentMemoryBytes())
            DebugLogger.shared.log(.error(description: error.localizedDescription))
        }

        // A partial result is still useful when final inference fails. Wait for
        // every queued partial to publish before handing that accumulated text
        // to output, while retaining the terminal inferenceFailed outcome.
        for task in pendingPartialTasks {
            await task.value
        }
        if inferenceFailed {
            _ = await emitFinalTranscript(sessionID: sessionID)
            return .inferenceFailed
        }

        if let finalText {
            audioState.withLock { state in
                guard state.sessionID == sessionID else { return }
                state.fullTranscript = [TranscriptFinalReconciler.reconcile(
                    incrementalSegments: state.fullTranscript,
                    finalText: finalText
                )]
            }
        }
        return await emitFinalTranscript(sessionID: sessionID)
    }

    private func emitFinalTranscript(sessionID: UUID) async -> TerminalResult {
        let combined: String? = audioState.withLock { state in
            guard state.sessionID == sessionID else { return nil }
            let result = state.fullTranscript.joined(separator: " ")
            state.fullTranscript.removeAll()  // Clear to prevent duplicate emissions
            return result
        }

        guard let combined else {
            DLOG("Final transcript discarded because its recording session is no longer current")
            return .noSpeech
        }

        let cleaned = cleanTranscript(combined)
        if cleaned != combined {
            DLOG("Cleaned final transcript: rawChars=\(combined.count), cleanedChars=\(cleaned.count)")
        }

        guard !cleaned.isEmpty else {
            DLOG("Final transcription produced no text; clipboard left unchanged")
            return .noSpeech
        }

        guard let onFinal else { return .completed(nil) }
        recorder(for: sessionID)?.recordFinalPresented()
        // The synchronous result is the complete output handoff contract.
        let result = await onFinal(cleaned)
        if let result {
            recorder(for: sessionID)?.recordOutputHandoff(
                clipboardWritten: result.clipboardWritten,
                insertOutcome: pipelineInsertOutcome(result.insertOutcome)
            )
        } else {
            // A callback was present and synchronously rejected this result
            // (normally because the coordinator no longer owns the request).
            // Preserve the recognized transcript's completed lifecycle while
            // distinguishing rejected output from no callback/no speech.
            recorder(for: sessionID)?.recordOutputHandoff(
                clipboardWritten: false,
                insertOutcome: .rejected
            )
        }
        return .completed(result)
    }

    // MARK: - Text Post-Processing

    private func cleanTranscript(_ text: String) -> String {
        TranscriptCleaner.clean(text)
    }

    // MARK: - Edge Case Handling

    private func handleAppAudioError(_ error: Error, sessionID: UUID) {
        guard audioSessionGate.accepts(sessionID) else { return }
        DebugLogger.shared.log(.error(description: error.localizedDescription))
        recorder(for: sessionID)?.recordApplicationLoss()
        recorder(for: sessionID)?.recordFallback()
        hardwareValidationRecorder.recordApplicationLoss(
            sessionID: sessionID,
            error: error.localizedDescription
        )

        // Notify that app audio was lost
        if let onAppAudioLost {
            Task { @MainActor in
                onAppAudioLost()
            }
        }

        // Immediately fall back to mic-only mode
        // Retrying a stopped ScreenCaptureKit stream is unreliable and complex,
        // so we gracefully degrade to mic-only to maintain recording continuity
        print("📉 Falling back to microphone-only mode due to app audio failure")
        fallbackToMicOnly(sessionID: sessionID)
    }

    private func fallbackToMicOnly(sessionID: UUID) {
        guard audioSessionGate.accepts(sessionID) else { return }
        print("Falling back to microphone-only mode")

        // Invalidate queued app callbacks before asking ScreenCaptureKit to stop.
        // The microphone remains active, preserving an uninterrupted fallback.
        appAudioGate.stop()
        captureSession.stopAppAudio()
        // The application source is already being retired. Its converter tail
        // must be drained to reset converter state, but cannot extend the
        // fallback timeline beyond the last application frame; doing so would
        // introduce a zero gap before the next microphone callback.
        _ = appStream.finish()
        compositionPipeline.deactivateApplication(sessionID: sessionID)

        // Re-check after capture shutdown; callbacks may have restarted a
        // session while ScreenCaptureKit was stopping.
        guard audioSessionGate.accepts(sessionID) else { return }
        audioState.withLock { state in
            guard state.sessionID == sessionID else { return }
            state.currentMode = .micOnly
        }

        // Notify
        if let onFallbackToMicOnly {
            Task { @MainActor in
                onFallbackToMicOnly()
            }
        }
    }

    // MARK: - Adaptive Quality

    private func configureBatteryMode(_ enabled: Bool) {
        audioState.withLock { state in
            if enabled {
                // Increase chunk duration to reduce inference frequency
                state.currentChunkDuration = 5000  // 5 seconds instead of 3s
                print("Battery mode enabled: Reduced inference frequency")
            } else {
                // Restore normal chunk duration
                state.currentChunkDuration = chunkDurationMs
                print("Battery mode disabled: Normal inference frequency")
            }
        }
    }

    private func throttledUIUpdate(_ text: String) async -> Bool {
        let shouldUpdate = audioState.withLock { state -> Bool in
            let now = TimeInterval(timingScheduler.nowNanoseconds) / 1_000_000_000
            guard now - state.lastUIUpdateTime >= uiUpdateThrottle else {
                return false  // Throttle UI updates
            }
            state.lastUIUpdateTime = now
            return true
        }

        guard shouldUpdate, let onPartial else { return false }
        await onPartial(text)
        return true
    }

    private func logAudioDiagnosticsIfNeeded(_ samples: [Float]) {
        guard audioDiagnosticsEnabled else { return }

        let shouldLog = audioState.withLock { state -> Bool in
            let now = TimeInterval(timingScheduler.nowNanoseconds) / 1_000_000_000
            guard now - state.lastDiagnosticsLogTime >= audioDiagnosticsInterval else {
                return false
            }
            state.lastDiagnosticsLogTime = now
            return true
        }

        guard shouldLog else { return }

        diagnosticsQueue.async { [samples] in
            guard !samples.isEmpty else { return }
            var sum: Float = 0
            var peak: Float = 0
            for sample in samples {
                let absValue = abs(sample)
                peak = max(peak, absValue)
                sum += sample * sample
            }
            let rms = sqrt(sum / Float(samples.count))
            if rms > 0.001 || peak > 0.001 {
                print(
                    "📊 Audio samples: count=\(samples.count), RMS=\(String(format: "%.4f", rms)), " +
                    "Peak=\(String(format: "%.4f", peak))"
                )
            }
        }
    }

    private func cancelPendingChunkTasks(sessionID: UUID) async {
        let tasks: [PendingChunkTask] = audioState.withLock { state in
            let tasks = state.pendingTasks[sessionID] ?? []
            state.pendingTasks[sessionID] = nil
            return tasks
        }

        for pending in tasks {
            pending.task.cancel()
        }

        for pending in tasks {
            _ = await pending.task.value
        }
    }

    private func removePendingChunkTask(id: UUID, sessionID: UUID) {
        audioState.withLock { state in
            guard state.pendingTasks[sessionID] != nil else { return }
            state.pendingTasks[sessionID]?.removeAll { $0.id == id }
            if state.pendingTasks[sessionID]?.isEmpty == true {
                state.pendingTasks[sessionID] = nil
            }
        }
    }
}
