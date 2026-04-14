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

    private let micCapture = AudioCapture()
    private let screenCapture = ScreenAudioCapture()
    private let mixer = AudioMixer()
    private let engine: any ASREngine
    private let levelMonitor = MultiChannelLevelMonitor()

    private let chunkDurationMs: Int = 3000  // 3 seconds for better context
    private let firstChunkDurationMs: Int = 1500  // 1.5 seconds for fast first result
    private let samplesPerMs = 16  // 16kHz sample rate
    private let maxFinalAudioSamples = 9_600_000  // 10 minutes at 16kHz mono
    private let finalAudioTrimMarginSamples = 160_000  // Trim in 10s chunks to reduce churn
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
        var language: String?

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
    var autoPasteEnabled = false

    // Performance optimization
    private var adaptiveQualityEnabled = true
    private let uiUpdateThrottle: TimeInterval = 0.1  // 100ms

    // MARK: - Initialization

    init(engine: any ASREngine) {
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

    func start(mode: Mode, audioSource: AppPickerWindowController.AudioSource? = nil) async throws {
        // Clear previous state
        audioState.withLock { state in
            state.audioChunk.removeAll()
            state.allAudio.removeAll()
            state.fullTranscript.removeAll()
            state.currentMode = mode
            state.isFirstChunk = true
            state.lastUIUpdateTime = 0
            state.lastDiagnosticsLogTime = 0
            state.sessionID = UUID()
            state.pendingTasks[state.sessionID] = []
        }

        // Start microphone capture FIRST so we don't lose the beginning
        // of the user's speech while the engine prepares.
        micCapture.onPCMFloatBuffer = { [weak self] buffer, _ in
            self?.processAudioBuffer(buffer)
        }
        try micCapture.start()
        print("🎤 Mic capture started (pre-roll buffering while engine prepares)")

        // Set up app audio capture if needed (also starts immediately)
        if case .micPlusAppAudio = mode {
            guard let source = audioSource else {
                micCapture.stop()
                throw NSError(domain: "TranscriptionController", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Audio source required for mic+app mode"
                ])
            }

            do {
                try await startAppAudioCapture(source: source)
            } catch {
                micCapture.stop()
                throw error
            }
        }

        // Now prepare the engine — audio is already being captured and
        // buffered in audioChunk/allAudio while this runs.
        try await engine.prepare()
        await engine.reset()

        print("Transcription started in mode: \(mode)")
    }

    private func startAppAudioCapture(source: AppPickerWindowController.AudioSource) async throws {
        screenCapture.onAudioSampleBuffer = { [weak self] sampleBuffer in
            self?.processSampleBuffer(sampleBuffer)
        }

        // Install error handler
        screenCapture.onStreamError = { [weak self] error in
            self?.handleAppAudioError(error)
        }

        if source.isSystemAudio, let display = source.display {
            try await screenCapture.selectDisplay(display: display)
        } else if let app = source.app {
            try await screenCapture.selectApp(app: app)
        } else {
            throw NSError(domain: "TranscriptionController", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Invalid audio source"
            ])
        }
    }

    func stop() {
        micCapture.stop()
        screenCapture.stop()

        let sessionID = audioState.withLock { state in
            state.sessionID
        }

        Task { [weak self] in
            guard let self else { return }
            await self.cancelPendingChunkTasks(sessionID: sessionID)
            await self.flushFinalChunk(sessionID: sessionID)
        }

        print("Transcription stopped")
    }

    // MARK: - Audio Processing

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let samples = mixer.convert(buffer: buffer) else {
            return
        }

        // Update microphone level
        let micLevel = levelMonitor.update(channel: .microphone, buffer: samples)
        if let onMicLevel {
            Task { @MainActor [micLevel] in
                onMicLevel(micLevel)
            }
        }

        appendSamples(samples)
    }

    private func processSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let samples = mixer.convertSampleBuffer(sampleBuffer) else {
            return
        }

        // Update app audio level
        let appLevel = levelMonitor.update(channel: .application, buffer: samples)
        if let onAppLevel {
            Task { @MainActor [appLevel] in
                onAppLevel(appLevel)
            }
        }

        appendSamples(samples)
    }

    private func appendSamples(_ samples: [Float]) {
        logAudioDiagnosticsIfNeeded(samples)

        let (chunkCount, threshold) = audioState.withLock { state -> (Int, Int) in
            state.audioChunk.append(contentsOf: samples)
            state.allAudio.append(contentsOf: samples)

            if state.allAudio.count > maxFinalAudioSamples + finalAudioTrimMarginSamples {
                let overflow = state.allAudio.count - maxFinalAudioSamples
                state.allAudio.removeFirst(overflow)
            }

            // Use shorter duration for the first chunk to reduce latency
            let effectiveDuration = state.isFirstChunk ? firstChunkDurationMs : state.currentChunkDuration
            return (state.audioChunk.count, samplesPerMs * effectiveDuration)
        }

        // Check if we have enough samples for a chunk
        if chunkCount >= threshold {
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

        print("🎤 Processing chunk with RMS: \(String(format: "%.4f", rms))")

        // Transcribe chunk on background queue with performance monitoring
        let taskID = UUID()
        let task = Task.detached(priority: .userInitiated) { [weak self, chunkSamples, sessionID, language] in
            guard let self = self else { return }
            defer {
                self.removePendingChunkTask(id: taskID, sessionID: sessionID)
            }

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
                print("ASR chunk processing failed: \(error.localizedDescription)")
            }
        }

        audioState.withLock { state in
            state.pendingTasks[sessionID, default: []].append(PendingChunkTask(id: taskID, task: task))
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
            // Emit final combined transcript
            emitFinalTranscript(sessionID: sessionID)
            return
        }

        // Check if audio is mostly silent
        let rms = sqrt(snapshot.audio.map { $0 * $0 }.reduce(0, +) / Float(snapshot.audio.count))
        let silenceThreshold: Float = 0.005  // Lowered threshold

        if rms < silenceThreshold {
            print("🔇 Skipping silent final audio (RMS: \(String(format: "%.4f", rms)))")
            emitFinalTranscript(sessionID: sessionID)
            return
        }

        print("🎤 Processing final transcription with ALL audio: \(snapshot.audio.count) samples (RMS: \(String(format: "%.4f", rms)))")

        // Transcribe complete audio recording
        do {
            let finalSegment = try await PerformanceMonitor.shared.measure("ASRFinalInference") {
                try await engine.finalize(samples: snapshot.audio, language: snapshot.language)
            }

            if let finalSegment {
                let trimmedText = finalSegment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedText.isEmpty {
                    audioState.withLock { state in
                        guard state.sessionID == sessionID else { return }
                        state.fullTranscript = [trimmedText]
                    }
                }
            }
        } catch {
            print("ASR final processing failed: \(error.localizedDescription)")
        }

        emitFinalTranscript(sessionID: sessionID)
    }

    private func emitFinalTranscript(sessionID: UUID) {
        let combined: String? = audioState.withLock { state in
            guard state.sessionID == sessionID else { return nil }
            let result = state.fullTranscript.joined(separator: " ")
            state.fullTranscript.removeAll()  // Clear to prevent duplicate emissions
            return result
        }

        guard let combined = combined else { return }

        let cleaned = cleanTranscript(combined)

        if !cleaned.isEmpty {
            if let onFinal {
                Task { @MainActor in
                    onFinal(cleaned)
                }
            }
        }
    }

    // MARK: - Text Post-Processing

    private func cleanTranscript(_ text: String) -> String {
        var result = text

        // Remove duplicate spaces
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }

        // Trim whitespace
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)

        // Capitalize first letter
        if let first = result.first {
            result = first.uppercased() + result.dropFirst()
        }

        // Ensure ends with punctuation
        let punctuation: Set<Character> = [".", "!", "?"]
        if let last = result.last, !punctuation.contains(last) {
            result += "."
        }

        return result
    }

    // MARK: - Edge Case Handling

    private func handleAppAudioError(_ error: Error) {
        print("⚠️ App audio error: \(error)")

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
        fallbackToMicOnly()
    }

    private func fallbackToMicOnly() {
        print("Falling back to microphone-only mode")

        // Stop app audio capture
        screenCapture.stop()

        // Update mode
        audioState.withLock { state in
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
