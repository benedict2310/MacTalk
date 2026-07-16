//
//  TranscriptionController.swift
//  MacTalk
//
//  Orchestrates audio capture, mixing, and transcription
//

import Foundation
@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
import QuartzCore  // FIX P0: For CACurrentMediaTime() in throttledUIUpdate
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
        let session = UUID()
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

/// Capture boundary used by the transcription controller.
///
/// Keeping capture lifecycle and callbacks behind this dependency lets callers
/// provide a different capture implementation without changing session gating.
protocol TranscriptionCaptureSession: AnyObject {
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
    /// Stops only the app/system-audio stream, preserving microphone capture.
    func stopAppAudio()
    /// Stops every active capture source.
    func stop()
}

/// Platform capture implementation used by the application.
final class LiveTranscriptionCaptureSession: @unchecked Sendable, TranscriptionCaptureSession {
    private let micCapture = AudioCapture()
    private let screenCapture = ScreenAudioCapture()

    func startMicrophone(
        sessionID: UUID,
        callback: @escaping @Sendable (UUID, AudioCaptureFrame) -> Void
    ) throws {
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

    func stopAppAudio() {
        screenCapture.stop()
    }

    func stop() {
        micCapture.stop()
        stopAppAudio()
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
final class TranscriptionController: @unchecked Sendable {
    enum Mode: Sendable {
        case micOnly
        case micPlusAppAudio
    }

    // MARK: - Properties

    private let captureSession: any TranscriptionCaptureSession
    private let settingsStore: AppSettings
    private let mixer: AudioMixer
    private let micStream: AudioMixer.Stream
    private let appStream: AudioMixer.Stream
    private let engine: any ASREngine
    private let levelMonitor = MultiChannelLevelMonitor()
    private let audioSessionGate = AudioSessionGate()
    /// Separately gates queued ScreenCaptureKit callbacks so app-audio fallback
    /// can invalidate that stream without interrupting the microphone session.
    private let appAudioGate = AudioSessionGate()

    private let chunkDurationMs: Int = 3000  // 3 seconds for better context
    private let firstChunkDurationMs: Int = 1500  // 1.5 seconds for fast first result
    private let samplesPerMs = 16  // 16kHz sample rate
    private let maxFinalAudioSamples = 9_600_000  // 10 minutes at 16kHz mono
    private let finalAudioTrimMarginSamples = 160_000  // Trim in 10s chunks to reduce churn
    private let tailDrainMs: Int = 100
    private let diagnosticsQueue = DispatchQueue(label: "com.mactalk.audio.diagnostics", qos: .utility)
    private let audioDiagnosticsEnabled = false
    private let audioDiagnosticsInterval: TimeInterval = 1.0

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
    var onFinal: (@Sendable @MainActor (String) -> Void)?
    var onMicLevel: (@Sendable @MainActor (AudioLevelMonitor.LevelData) -> Void)?
    var onAppLevel: (@Sendable @MainActor (AudioLevelMonitor.LevelData) -> Void)?
    var onAppAudioLost: (@Sendable @MainActor () -> Void)?  // Callback when app audio is lost
    var onFallbackToMicOnly: (@Sendable @MainActor () -> Void)?  // Callback when falling back to mic-only
    var onFinalizationComplete: (@Sendable @MainActor () -> Void)?
    var autoPasteEnabled = false

    // Performance optimization
    private var adaptiveQualityEnabled = true
    private let uiUpdateThrottle: TimeInterval = 0.1  // 100ms

    // MARK: - Initialization

    init(
        engine: any ASREngine,
        captureSession: any TranscriptionCaptureSession = LiveTranscriptionCaptureSession(),
        settings: AppSettings = .shared
    ) {
        let mixer = AudioMixer()
        self.captureSession = captureSession
        self.settingsStore = settings
        self.mixer = mixer
        self.micStream = mixer.makeStream()
        self.appStream = mixer.makeStream()
        self.engine = engine
        self.audioState = OSAllocatedUnfairLock(
            initialState: AudioState(chunkDuration: chunkDurationMs, language: "en")
        )

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
        DLOG("Transcription start requested: mode=\(recordingMode)")

        // Invalidate callbacks from any previous capture before resetting the
        // streams. ScreenCaptureKit may still deliver a queued callback after
        // stopCapture has been requested.
        let sessionID = audioSessionGate.begin()
        if settingsSnapshot != nil, recordingSettings.provider != engine.provider {
            throw NSError(domain: "TranscriptionController", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Settings provider does not match the selected transcription engine"
            ])
        }
        captureSession.stop()
        appAudioGate.stop()

        // Clear previous state
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

        // Start microphone capture FIRST so we don't lose the beginning
        // of the user's speech while the engine prepares.
        try captureSession.startMicrophone(sessionID: sessionID) { [weak self] callbackSessionID, frame in
            self?.processAudioFrame(frame, sessionID: callbackSessionID)
        }
        DLOG("Mic capture started (pre-roll buffering while engine prepares)")
        print("🎤 Mic capture started (pre-roll buffering while engine prepares)")

        // Set up app audio capture if needed (also starts immediately)
        if case .micPlusAppAudio = recordingMode {
            guard let source = audioSource else {
                await cancelStartAndWait()
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
            } catch {
                await cancelStartAndWait()
                throw error
            }
        }

        // Now prepare the engine — audio is already being captured and
        // buffered in audioChunk/allAudio while this runs. If preparation fails,
        // stop captures here so direct callers cannot leave the microphone active.
        do {
            try await engine.prepare()
            await engine.reset()
        } catch {
            await cancelStartAndWait()
            throw error
        }

        DLOG("Engine prepared/reset; transcription fully started in mode=\(recordingMode)")
        print("Transcription started in mode: \(recordingMode)")
    }

    func stop() {
        DLOG("Transcription stop requested")
        // Invalidate callbacks and mark the state before capture shutdown.
        // Queued work can then never append after final stream draining begins.
        audioSessionGate.stop()
        appAudioGate.stop()
        let sessionID: UUID? = audioState.withLock { state in
            guard !state.isStopping else { return nil }
            state.isStopping = true
            return state.sessionID
        }
        guard let sessionID else {
            DLOG("Ignoring duplicate transcription stop request")
            return
        }
        captureSession.stop()
        finishAudioStreams()
        // Keep the controller alive through final inference and clipboard delivery.
        Task { [self] in
            // Capture the final in-flight microphone buffer without a noticeable delay.
            try? await Task.sleep(nanoseconds: UInt64(tailDrainMs) * 1_000_000)

            await cancelPendingChunkTasks(sessionID: sessionID)
            await flushFinalChunk(sessionID: sessionID)

            audioState.withLock { state in
                if state.sessionID == sessionID {
                    state.isStopping = false
                }
            }
            if let onFinalizationComplete {
                await onFinalizationComplete()
            }
        }

        print("Transcription stopped")
    }

    func cancelStart() {
        let sessionID = cancelStartAndReturnSession()

        Task { [weak self] in
            guard let self else { return }
            await self.cancelPendingChunkTasks(sessionID: sessionID)
        }

        print("Transcription start cancelled")
    }

    private func cancelStartAndWait() async {
        let sessionID = cancelStartAndReturnSession()
        await cancelPendingChunkTasks(sessionID: sessionID)
        print("Transcription start cancelled")
    }

    private func cancelStartAndReturnSession() -> UUID {
        audioSessionGate.stop()
        appAudioGate.stop()
        captureSession.stop()

        return audioState.withLock { state in
            let sessionID = state.sessionID
            state.audioChunk.removeAll()
            state.allAudio.removeAll()
            state.fullTranscript.removeAll()
            state.sessionID = UUID()
            state.chunkProcessingTail = nil
            state.isStopping = false
            return sessionID
        }
    }

    // MARK: - Audio Processing

    private func finishAudioStreams() {
        if let samples = micStream.finish(), !samples.isEmpty {
            appendSamples(samples, allowStopping: true)
        }
        if let samples = appStream.finish(), !samples.isEmpty {
            appendSamples(samples, allowStopping: true)
        }
    }

    private func processAudioFrame(_ frame: AudioCaptureFrame, sessionID: UUID) {
        guard audioSessionGate.accepts(sessionID) else { return }
        let samples = micStream.convert(samples: frame.samples, sampleRate: frame.sampleRate)
        guard audioSessionGate.accepts(sessionID) else { return }
        guard let samples else {
            return
        }

        // Update microphone level
        let micLevel = levelMonitor.update(channel: .microphone, buffer: samples)
        if let onMicLevel {
            Task { @MainActor [micLevel] in
                onMicLevel(micLevel)
            }
        }

        appendSamples(samples, sessionID: sessionID)
    }

    @discardableResult
    private func processSampleBuffer(
        _ sampleBuffer: CMSampleBuffer,
        sessionID: UUID,
        appGeneration: UUID
    ) -> Int? {
        // ScreenCaptureKit can deliver queued callbacks after stopAppAudio().
        // Reject them before touching the app stream converter.
        guard audioSessionGate.accepts(sessionID), appAudioGate.accepts(appGeneration) else {
            return nil
        }
        let samples = mixer.convertSampleBuffer(sampleBuffer, using: appStream)
        guard audioSessionGate.accepts(sessionID), appAudioGate.accepts(appGeneration) else {
            return nil
        }
        guard let samples else {
            return nil
        }

        // Update app audio level
        let appLevel = levelMonitor.update(channel: .application, buffer: samples)
        if let onAppLevel {
            Task { @MainActor [appLevel] in
                onAppLevel(appLevel)
            }
        }

        appendSamples(samples, sessionID: sessionID)
        return samples.count
    }

    private func appendSamples(
        _ samples: [Float],
        sessionID: UUID? = nil,
        allowStopping: Bool = false
    ) {
        logAudioDiagnosticsIfNeeded(samples)

        let usesIncrementalChunks = engine.provider.usesIncrementalChunkProcessing
        let (chunkCount, threshold) = audioState.withLock { state -> (Int, Int) in
            // Session validation uses the state snapshot while its lock is held;
            // never acquire the session gate while holding audioState.
            if let sessionID, state.sessionID != sessionID || (state.isStopping && !allowStopping) {
                return (state.audioChunk.count, Int.max)
            }
            if usesIncrementalChunks {
                state.audioChunk.append(contentsOf: samples)
            }
            state.allAudio.append(contentsOf: samples)

            if state.allAudio.count > maxFinalAudioSamples + finalAudioTrimMarginSamples {
                let overflow = state.allAudio.count - maxFinalAudioSamples
                state.allAudio.removeFirst(overflow)
            }

            // Use shorter duration for the first chunk to reduce latency
            let effectiveDuration = state.isFirstChunk ? firstChunkDurationMs : state.currentChunkDuration
            return (state.audioChunk.count, samplesPerMs * effectiveDuration)
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
            print("🔇 Skipping silent chunk (RMS: \(String(format: "%.4f", rms)))")
            return
        }

        DLOG("Processing chunk: samples=\(chunkSamples.count), RMS=\(String(format: "%.4f", rms))")
        print("🎤 Processing chunk with RMS: \(String(format: "%.4f", rms))")

        // Transcribe chunks on background tasks, serialized by the previous task tail.
        // Parakeet streaming carries decoder state between chunks, so chunk order matters.
        let taskID = UUID()
        audioState.withLock { state in
            let previousTask = state.chunkProcessingTail
            let task = Task.detached(priority: .userInitiated) { [weak self, chunkSamples, sessionID, language, previousTask] in
                guard let self = self else { return }
                defer {
                    self.removePendingChunkTask(id: taskID, sessionID: sessionID)
                }

                _ = await previousTask?.value
                guard !Task.isCancelled else { return }

                do {
                    let partial = try await PerformanceMonitor.shared.measure("ASRInference") {
                        try await self.engine.process(samples: chunkSamples, language: language)
                    }

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
                                self.throttledUIUpdate(trimmedText)
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

    private func flushFinalChunk(sessionID: UUID) async {
        let snapshot: (audio: [Float], language: String?) = audioState.withLock { state in
            guard state.sessionID == sessionID else { return ([], nil) }
            let audio = state.allAudio
            state.audioChunk.removeAll()
            state.allAudio.removeAll()
            return (audio, state.language)
        }

        guard !snapshot.audio.isEmpty else {
            await emitFinalTranscript(sessionID: sessionID)
            return
        }

        // Check if audio is mostly silent
        let rms = sqrt(snapshot.audio.map { $0 * $0 }.reduce(0, +) / Float(snapshot.audio.count))
        let silenceThreshold: Float = 0.005  // Lowered threshold

        if rms < silenceThreshold {
            print("🔇 Skipping silent final audio (RMS: \(String(format: "%.4f", rms)))")
            await emitFinalTranscript(sessionID: sessionID)
            return
        }

        DLOG("Processing final transcription with ALL audio: samples=\(snapshot.audio.count), RMS=\(String(format: "%.4f", rms))")
        print("🎤 Processing final transcription with ALL audio: \(snapshot.audio.count) samples (RMS: \(String(format: "%.4f", rms)))")

        // Transcribe complete audio recording
        do {
            let finalSegment = try await PerformanceMonitor.shared.measure("ASRFinalInference") {
                try await engine.finalize(samples: snapshot.audio, language: snapshot.language)
            }

            if let finalSegment {
                let trimmedText = finalSegment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedText.isEmpty {
                    DLOG("Final transcription result received: chars=\(trimmedText.count)")
                    audioState.withLock { state in
                        guard state.sessionID == sessionID else { return }
                        state.fullTranscript = [trimmedText]
                    }
                }
            }
        } catch {
            DebugLogger.shared.log(.error(description: error.localizedDescription))
        }

        await emitFinalTranscript(sessionID: sessionID)
    }

    private func emitFinalTranscript(sessionID: UUID) async {
        let combined: String? = audioState.withLock { state in
            guard state.sessionID == sessionID else { return nil }
            let result = state.fullTranscript.joined(separator: " ")
            state.fullTranscript.removeAll()  // Clear to prevent duplicate emissions
            return result
        }

        guard let combined else {
            DLOG("Final transcript discarded because its recording session is no longer current")
            return
        }

        let cleaned = cleanTranscript(combined)
        if cleaned != combined {
            DLOG("Cleaned final transcript: rawChars=\(combined.count), cleanedChars=\(cleaned.count)")
        }

        guard !cleaned.isEmpty else {
            DLOG("Final transcription produced no text; clipboard left unchanged")
            return
        }

        if let onFinal {
            // Ensure clipboard propagation completes before a new recording starts.
            await onFinal(cleaned)
        }
    }

    // MARK: - Text Post-Processing

    private func cleanTranscript(_ text: String) -> String {
        TranscriptCleaner.clean(text)
    }

    // MARK: - Edge Case Handling

    private func handleAppAudioError(_ error: Error, sessionID: UUID) {
        guard audioSessionGate.accepts(sessionID) else { return }
        DebugLogger.shared.log(.error(description: error.localizedDescription))

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

    private func throttledUIUpdate(_ text: String) {
        let shouldUpdate = audioState.withLock { state -> Bool in
            let now = CACurrentMediaTime()
            guard now - state.lastUIUpdateTime >= uiUpdateThrottle else {
                return false  // Throttle UI updates
            }
            state.lastUIUpdateTime = now
            return true
        }

        if shouldUpdate {
            if let onPartial {
                Task { @MainActor in
                    onPartial(text)
                }
            }
        }
    }

    private func logAudioDiagnosticsIfNeeded(_ samples: [Float]) {
        guard audioDiagnosticsEnabled else { return }

        let shouldLog = audioState.withLock { state -> Bool in
            let now = CACurrentMediaTime()
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
