//
//  TranscriptionController.swift
//  MacTalk
//
//  Orchestrates audio capture, mixing, and transcription
//

import Foundation
import AVFoundation

final class TranscriptionController {
    enum Mode {
        case micOnly
        case micPlusAppAudio
    }

    // MARK: - Properties

    private let micCapture = AudioCapture()
    private let screenCapture = ScreenAudioCapture()
    private let mixer = AudioMixer()
    private let engine: WhisperEngine
    private let levelMonitor = MultiChannelLevelMonitor()

    private let chunkDurationMs: Int = 750  // 0.75 seconds
    private let samplesPerMs = 16  // 16kHz sample rate

    // Separate buffers for each audio source to enable proper mixing
    private var micBuffer: [Float] = []
    private var appBuffer: [Float] = []
    private var audioChunk: [Float] = []
    private let chunkLock = NSLock()

    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onMicLevel: ((AudioLevelMonitor.LevelData) -> Void)?
    var onAppLevel: ((AudioLevelMonitor.LevelData) -> Void)?
    var onAppAudioLost: (() -> Void)?  // Callback when app audio is lost
    var onFallbackToMicOnly: (() -> Void)?  // Callback when falling back to mic-only
    var language: String?
    var autoPasteEnabled = false

    private var fullTranscript: [String] = []
    private var currentMode: Mode = .micOnly
    private var appAudioRetryCount = 0
    private let maxAppAudioRetries = 3

    // Performance optimization
    private var adaptiveQualityEnabled = true
    private var currentChunkDuration: Int
    private var lastUIUpdateTime: TimeInterval = 0
    private let uiUpdateThrottle: TimeInterval = 0.1  // 100ms

    // MARK: - Initialization

    init(engine: WhisperEngine) {
        self.engine = engine
        self.currentChunkDuration = chunkDurationMs

        // Adapt to battery mode if enabled
        if adaptiveQualityEnabled && PerformanceMonitor.shared.isBatteryMode {
            configureBatteryMode(true)
        }
    }

    // MARK: - Control

    func start(mode: Mode, audioSource: AppPickerWindowController.AudioSource? = nil) async throws {
        // Clear previous state
        chunkLock.lock()
        micBuffer.removeAll()
        appBuffer.removeAll()
        audioChunk.removeAll()
        fullTranscript.removeAll()
        chunkLock.unlock()

        currentMode = mode
        appAudioRetryCount = 0

        // Set up microphone capture
        micCapture.onPCMFloatBuffer = { [weak self] buffer, _ in
            self?.processAudioBuffer(buffer)
        }
        try micCapture.start()

        // Set up app audio capture if needed
        if case .micPlusAppAudio = mode {
            guard let source = audioSource else {
                throw NSError(domain: "TranscriptionController", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Audio source required for mic+app mode"
                ])
            }

            try await startAppAudioCapture(source: source)
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
        onMicLevel?(micLevel)

        chunkLock.lock()
        micBuffer.append(contentsOf: samples)
        mixAndAppendSamples()
        let chunkCount = audioChunk.count
        chunkLock.unlock()

        // Check if we have enough samples for a chunk
        let threshold = samplesPerMs * chunkDurationMs
        if chunkCount >= threshold {
            processChunk()
        }
    }

    private func processSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let samples = mixer.convertSampleBuffer(sampleBuffer) else {
            return
        }

        // Update app audio level
        let appLevel = levelMonitor.update(channel: .application, buffer: samples)
        onAppLevel?(appLevel)

        chunkLock.lock()
        appBuffer.append(contentsOf: samples)
        mixAndAppendSamples()
        let chunkCount = audioChunk.count
        chunkLock.unlock()

        // Check if we have enough samples for a chunk
        let threshold = samplesPerMs * chunkDurationMs
        if chunkCount >= threshold {
            processChunk()
        }
    }

    /// Mix audio samples from microphone and app sources
    /// Called with chunkLock held
    ///
    /// In mic-only mode: Transfers mic samples directly to audioChunk
    /// In mic+app mode: Mixes samples from both sources by averaging them per frame.
    /// This ensures proper time-alignment and prevents the concatenation issue where
    /// samples would be appended sequentially (causing time-stretching/desync).
    private func mixAndAppendSamples() {
        // Must be called with chunkLock held

        if currentMode == .micOnly {
            // In mic-only mode, just move mic samples to audioChunk
            audioChunk.append(contentsOf: micBuffer)
            micBuffer.removeAll()
            return
        }

        // Mode B: Mix both sources
        // Only mix the samples we have from BOTH sources to maintain time alignment
        let availableSamples = min(micBuffer.count, appBuffer.count)

        if availableSamples > 0 {
            // Mix samples by averaging them to prevent clipping
            // Each sample is the average of mic and app at that time position
            audioChunk.reserveCapacity(audioChunk.count + availableSamples)

            for i in 0..<availableSamples {
                let mixed = (micBuffer[i] + appBuffer[i]) / 2.0
                audioChunk.append(mixed)
            }

            // Remove the mixed samples from source buffers
            micBuffer.removeFirst(availableSamples)
            appBuffer.removeFirst(availableSamples)
        }
    }

    private func processChunk() {
        chunkLock.lock()
        let threshold = samplesPerMs * currentChunkDuration
        guard audioChunk.count >= threshold else {
            chunkLock.unlock()
            return
        }

        let chunkSamples = Array(audioChunk.prefix(threshold))
        audioChunk.removeFirst(threshold)
        chunkLock.unlock()

        // Transcribe chunk on background queue with performance monitoring
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let result = PerformanceMonitor.shared.measure("WhisperInference") {
                return self.engine.transcribeStreaming(
                    samples: chunkSamples,
                    language: self.language
                )
            }

            if let result = result {
                let trimmedText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedText.isEmpty {
                    self.fullTranscript.append(trimmedText)
                    self.throttledUIUpdate(trimmedText)
                }
            }
        }
    }

    private func flushFinalChunk() {
        chunkLock.lock()
        // Mix any remaining buffered samples before flushing
        mixAndAppendSamples()

        // For mic-only mode or when one buffer still has data,
        // append any remaining samples directly
        if currentMode == .micOnly {
            audioChunk.append(contentsOf: micBuffer)
            micBuffer.removeAll()
        } else {
            // In mixed mode, there may be unmatched samples in either buffer
            // Append them as-is (better than discarding them)
            audioChunk.append(contentsOf: micBuffer)
            audioChunk.append(contentsOf: appBuffer)
            micBuffer.removeAll()
            appBuffer.removeAll()
        }

        let remainingSamples = audioChunk
        audioChunk.removeAll()
        chunkLock.unlock()

        guard !remainingSamples.isEmpty else {
            // Emit final combined transcript
            emitFinalTranscript()
            return
        }

        // Transcribe remaining audio
        if let result = engine.transcribeFinal(
            samples: remainingSamples,
            language: language
        ) {
            let trimmedText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedText.isEmpty {
                fullTranscript.append(trimmedText)
            }
        }

        emitFinalTranscript()
    }

    private func emitFinalTranscript() {
        let combined = fullTranscript.joined(separator: " ")
        let cleaned = cleanTranscript(combined)

        if !cleaned.isEmpty {
            onFinal?(cleaned)
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
        print("App audio error: \(error)")

        // Notify that app audio was lost
        DispatchQueue.main.async { [weak self] in
            self?.onAppAudioLost?()
        }

        // Attempt retry if within limits
        if appAudioRetryCount < maxAppAudioRetries {
            appAudioRetryCount += 1
            print("Retrying app audio capture (attempt \(appAudioRetryCount)/\(maxAppAudioRetries))...")

            // Retry after a delay
            DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) { [weak self] in
                // Retry logic would go here
                // For now, we'll just log
                print("Retry logic not yet implemented")
            }
        } else {
            // Max retries exceeded, fall back to mic-only
            fallbackToMicOnly()
        }
    }

    private func fallbackToMicOnly() {
        print("Falling back to microphone-only mode")

        // Stop app audio capture
        screenCapture.stop()

        // Update mode
        currentMode = .micOnly

        // Notify
        DispatchQueue.main.async { [weak self] in
            self?.onFallbackToMicOnly?()
        }
    }

    // MARK: - Adaptive Quality

    private func configureBatteryMode(_ enabled: Bool) {
        if enabled {
            // Increase chunk duration to reduce inference frequency
            currentChunkDuration = 1000  // 1 second instead of 750ms
            print("Battery mode enabled: Reduced inference frequency")
        } else {
            // Restore normal chunk duration
            currentChunkDuration = chunkDurationMs
            print("Battery mode disabled: Normal inference frequency")
        }
    }

    private func throttledUIUpdate(_ text: String) {
        let now = CACurrentMediaTime()
        guard now - lastUIUpdateTime >= uiUpdateThrottle else {
            return  // Throttle UI updates
        }
        lastUIUpdateTime = now
        onPartial?(text)
    }
}
