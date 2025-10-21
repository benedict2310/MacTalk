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

    private var audioChunk: [Float] = []
    private let chunkLock = NSLock()

    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onMicLevel: ((AudioLevelMonitor.LevelData) -> Void)?
    var onAppLevel: ((AudioLevelMonitor.LevelData) -> Void)?
    var language: String?
    var autoPasteEnabled = false

    private var fullTranscript: [String] = []

    // MARK: - Initialization

    init(engine: WhisperEngine) {
        self.engine = engine
    }

    // MARK: - Control

    func start(mode: Mode, appName: String? = nil) async throws {
        // Clear previous state
        chunkLock.lock()
        audioChunk.removeAll()
        fullTranscript.removeAll()
        chunkLock.unlock()

        // Set up microphone capture
        micCapture.onPCMFloatBuffer = { [weak self] buffer, _ in
            self?.processAudioBuffer(buffer)
        }
        try micCapture.start()

        // Set up app audio capture if needed
        if case .micPlusAppAudio = mode {
            guard let appName = appName else {
                throw NSError(domain: "TranscriptionController", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "App name required for mic+app mode"
                ])
            }

            screenCapture.onAudioSampleBuffer = { [weak self] sampleBuffer in
                self?.processSampleBuffer(sampleBuffer)
            }

            try await screenCapture.selectFirstWindow(named: appName)
        }

        print("Transcription started in mode: \(mode)")
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

        appendSamples(samples)
    }

    private func processSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let samples = mixer.convertSampleBuffer(sampleBuffer) else {
            return
        }

        // Update app audio level
        let appLevel = levelMonitor.update(channel: .application, buffer: samples)
        onAppLevel?(appLevel)

        appendSamples(samples)
    }

    private func appendSamples(_ samples: [Float]) {
        chunkLock.lock()
        audioChunk.append(contentsOf: samples)
        let chunkCount = audioChunk.count
        chunkLock.unlock()

        // Check if we have enough samples for a chunk
        let threshold = samplesPerMs * chunkDurationMs
        if chunkCount >= threshold {
            processChunk()
        }
    }

    private func processChunk() {
        chunkLock.lock()
        let threshold = samplesPerMs * chunkDurationMs
        guard audioChunk.count >= threshold else {
            chunkLock.unlock()
            return
        }

        let chunkSamples = Array(audioChunk.prefix(threshold))
        audioChunk.removeFirst(threshold)
        chunkLock.unlock()

        // Transcribe chunk on background queue
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            if let result = self.engine.transcribeStreaming(
                samples: chunkSamples,
                language: self.language
            ) {
                let trimmedText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedText.isEmpty {
                    self.fullTranscript.append(trimmedText)
                    self.onPartial?(trimmedText)
                }
            }
        }
    }

    private func flushFinalChunk() {
        chunkLock.lock()
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
}
