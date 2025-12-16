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
    private let engine: WhisperEngine
    private let levelMonitor = MultiChannelLevelMonitor()

    private let chunkDurationMs: Int = 3000  // 3 seconds for better context
    private let samplesPerMs = 16  // 16kHz sample rate

    /// Audio buffer state protected by OSAllocatedUnfairLock.
    private struct AudioState {
        var audioChunk: [Float] = []
        var allAudio: [Float] = []  // Store all audio for final transcription
        var fullTranscript: [String] = []
        var currentMode: Mode = .micOnly
        var currentChunkDuration: Int
        var lastUIUpdateTime: TimeInterval = 0

        init(chunkDuration: Int) {
            self.currentChunkDuration = chunkDuration
        }
    }

    private let audioState: OSAllocatedUnfairLock<AudioState>

    var onPartial: (@Sendable @MainActor (String) -> Void)?
    var onFinal: (@Sendable @MainActor (String) -> Void)?
    var onMicLevel: (@Sendable @MainActor (AudioLevelMonitor.LevelData) -> Void)?
    var onAppLevel: (@Sendable @MainActor (AudioLevelMonitor.LevelData) -> Void)?
    var onAppAudioLost: (@Sendable @MainActor () -> Void)?  // Callback when app audio is lost
    var onFallbackToMicOnly: (@Sendable @MainActor () -> Void)?  // Callback when falling back to mic-only
    var language: String? = "en"  // Default to English to avoid incorrect auto-detection
    var autoPasteEnabled = false

    // Performance optimization
    private var adaptiveQualityEnabled = true
    private let uiUpdateThrottle: TimeInterval = 0.1  // 100ms

    // MARK: - Initialization

    init(engine: WhisperEngine) {
        self.engine = engine
        self.audioState = OSAllocatedUnfairLock(initialState: AudioState(chunkDuration: chunkDurationMs))

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

    // MARK: - Control

    func start(mode: Mode, audioSource: AppPickerWindowController.AudioSource? = nil) async throws {
        // Clear previous state
        audioState.withLock { state in
            state.audioChunk.removeAll()
            state.allAudio.removeAll()
            state.fullTranscript.removeAll()
            state.currentMode = mode
        }

        // Set up microphone capture
        micCapture.onPCMFloatBuffer = { [weak self] buffer, _ in
            self?.processAudioBuffer(buffer)
        }
        try micCapture.start()

        // Set up app audio capture if needed
        if case .micPlusAppAudio = mode {
            guard let source = audioSource else {
                micCapture.stop() // Stop mic if validation fails
                throw NSError(domain: "TranscriptionController", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Audio source required for mic+app mode"
                ])
            }

            do {
                try await startAppAudioCapture(source: source)
            } catch {
                // Stop microphone capture if app audio setup fails
                micCapture.stop()
                throw error
            }
        }

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

        // Process any remaining audio
        flushFinalChunk()

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
        // Calculate RMS to check if we're actually getting audio
        let rms = sqrt(samples.map { $0 * $0 }.reduce(0, +) / Float(samples.count))
        let peak = samples.map { abs($0) }.max() ?? 0

        if samples.count > 0 && (rms > 0.001 || peak > 0.001) {
            print("📊 Audio samples: count=\(samples.count), RMS=\(String(format: "%.4f", rms)), Peak=\(String(format: "%.4f", peak))")
        }

        let (chunkCount, threshold) = audioState.withLock { state -> (Int, Int) in
            state.audioChunk.append(contentsOf: samples)
            state.allAudio.append(contentsOf: samples)  // Store all audio for final transcription
            return (state.audioChunk.count, samplesPerMs * chunkDurationMs)
        }

        // Check if we have enough samples for a chunk
        if chunkCount >= threshold {
            processChunk()
        }
    }

    private func processChunk() {
        let chunkSamples: [Float]? = audioState.withLock { state in
            let threshold = samplesPerMs * state.currentChunkDuration
            guard state.audioChunk.count >= threshold else {
                return nil
            }

            let samples = Array(state.audioChunk.prefix(threshold))
            state.audioChunk.removeFirst(threshold)
            return samples
        }

        guard let chunkSamples = chunkSamples else { return }

        // Simple Voice Activity Detection (VAD) - skip if chunk is too quiet
        let rms = sqrt(chunkSamples.map { $0 * $0 }.reduce(0, +) / Float(chunkSamples.count))
        let silenceThreshold: Float = 0.005  // Lowered to catch quieter speech

        if rms < silenceThreshold {
            print("🔇 Skipping silent chunk (RMS: \(String(format: "%.4f", rms)))")
            return
        }

        print("🎤 Processing chunk with RMS: \(String(format: "%.4f", rms))")

        // Transcribe chunk on background queue with performance monitoring
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let result = PerformanceMonitor.shared.measureSync("WhisperInference") {
                return self.engine.transcribeStreaming(
                    samples: chunkSamples,
                    language: self.language
                )
            }

            if let result = result {
                let trimmedText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedText.isEmpty {
                    self.audioState.withLock { state in
                        state.fullTranscript.append(trimmedText)
                    }
                    self.throttledUIUpdate(trimmedText)
                }
            }
        }
    }

    private func flushFinalChunk() {
        let finalAudio: [Float] = audioState.withLock { state in
            let audio = state.allAudio  // Use ALL accumulated audio for best quality
            state.audioChunk.removeAll()
            state.allAudio.removeAll()
            return audio
        }

        guard !finalAudio.isEmpty else {
            // Emit final combined transcript
            emitFinalTranscript()
            return
        }

        // Check if audio is mostly silent
        let rms = sqrt(finalAudio.map { $0 * $0 }.reduce(0, +) / Float(finalAudio.count))
        let silenceThreshold: Float = 0.005  // Lowered threshold

        if rms < silenceThreshold {
            print("🔇 Skipping silent final audio (RMS: \(String(format: "%.4f", rms)))")
            emitFinalTranscript()
            return
        }

        print("🎤 Processing final transcription with ALL audio: \(finalAudio.count) samples (RMS: \(String(format: "%.4f", rms)))")

        // Clear streaming transcript and transcribe ALL audio at once for best quality
        audioState.withLock { state in
            state.fullTranscript.removeAll()
        }

        // Transcribe complete audio recording
        if let result = engine.transcribeFinal(
            samples: finalAudio,
            language: language
        ) {
            let trimmedText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedText.isEmpty {
                audioState.withLock { state in
                    state.fullTranscript.append(trimmedText)
                }
            }
        }

        emitFinalTranscript()
    }

    private func emitFinalTranscript() {
        let combined: String = audioState.withLock { state in
            let result = state.fullTranscript.joined(separator: " ")
            state.fullTranscript.removeAll()  // Clear to prevent duplicate emissions
            return result
        }

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
                state.currentChunkDuration = 1000  // 1 second instead of 750ms
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
}
