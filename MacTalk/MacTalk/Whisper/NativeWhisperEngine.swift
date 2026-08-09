//
//  NativeWhisperEngine.swift
//  MacTalk
//
//  Swift wrapper around whisper.cpp C API
//

import Foundation
import Darwin
@preconcurrency import AVFoundation

/// Swift wrapper around whisper.cpp C API for audio transcription.
///
/// ## Thread Safety
/// This class is marked `@unchecked Sendable` because:
/// - All transcription operations are serialized through a dedicated DispatchQueue
/// - The whisper context (`ctx`) is only accessed within the serial queue
/// - The queue provides a full memory barrier ensuring visibility across threads
///
/// ## C++ Bridge
/// The whisper.cpp context is NOT thread-safe internally. This class ensures
/// serial access to prevent data races in the underlying C++ code.
final class NativeWhisperEngine: @unchecked Sendable, ASREngine {
    /// Conservative final UTF-8 guard when the loaded whisper.cpp context does
    /// not expose an exact tokenizer budget at this Swift boundary.
    static let maximumInitialPromptUTF8Bytes = 640

    private var ctx: OpaquePointer?
    private let queue = DispatchQueue(label: "com.mactalk.whisper.engine", qos: .userInitiated)
    let provider: ASRProvider = .whisper

    /// Transcription result containing text and timing information.
    struct Result: Sendable {
        let text: String
        let processingTime: TimeInterval
    }

    /// The catalog specification is mandatory at the native boundary. The
    /// verifier hashes the same O_NOFOLLOW descriptor that is passed to
    /// whisper.cpp through /dev/fd, rather than re-opening a mutable path.
    init?(modelSpec: ModelSpec, modelURL: URL) {
        let fd: Int32
        do {
            fd = try ModelIntegrityVerifier.openValidated(source: modelURL, spec: modelSpec)
        } catch {
            DLOG("Whisper model failed native-boundary validation")
            return nil
        }
        defer { close(fd) }

        let fdPath = "/dev/fd/\(fd)"
        guard let context = wt_whisper_init(fdPath) else {
            DLOG("Whisper context initialization failed")
            return nil
        }

        self.ctx = OpaquePointer(context)
        DLOG("Whisper engine initialized")
    }

    deinit {
        if let ctx = ctx {
            wt_whisper_free(UnsafeMutableRawPointer(ctx))
        }
    }

    func prepare() async throws {}

    func reset() async {}

    func process(_ buffer: AVAudioPCMBuffer, language: String?) async throws -> ASRPartial? {
        guard let samples = samples(from: buffer) else {
            return nil
        }
        guard let result = transcribeStreaming(samples: samples, language: language) else {
            return nil
        }

        return ASRPartial(text: result.text, words: [])
    }

    func process(_ buffer: AVAudioPCMBuffer, context: ASRRequestContext) async throws -> ASRPartial? {
        guard let samples = samples(from: buffer) else {
            return nil
        }
        guard let result = transcribeStreaming(
            samples: samples,
            language: context.language,
            initialPrompt: Self.initialPrompt(for: context)
        ) else {
            return nil
        }

        return ASRPartial(text: result.text, words: [])
    }

    func finalize(_ buffer: AVAudioPCMBuffer, language: String?) async throws -> ASRFinalSegment? {
        guard let samples = samples(from: buffer) else {
            return nil
        }
        guard let result = transcribeFinal(samples: samples, language: language) else {
            return nil
        }
        return ASRFinalSegment(text: result.text, words: [])
    }

    func finalize(_ buffer: AVAudioPCMBuffer, context: ASRRequestContext) async throws -> ASRFinalSegment? {
        guard let samples = samples(from: buffer) else {
            return nil
        }
        guard let result = transcribeFinal(
            samples: samples,
            language: context.language,
            initialPrompt: Self.initialPrompt(for: context)
        ) else {
            return nil
        }
        return ASRFinalSegment(text: result.text, words: [])
    }

    /// Transcribe audio samples (16kHz mono float32)
    func transcribe(
        samples: [Float],
        language: String? = nil,
        translate: Bool = false,
        noContext: Bool = false,
        initialPrompt: String? = nil
    ) -> Result? {
        guard let ctx = ctx else {
            DLOG("Whisper context is unavailable")
            return nil
        }

        guard !samples.isEmpty else {
            DLOG("Whisper received no samples")
            return nil
        }

        return queue.sync {
            let startTime = Date()

            let textPtr = samples.withUnsafeBufferPointer { bufferPointer -> UnsafeMutablePointer<CChar>? in
                guard let baseAddress = bufferPointer.baseAddress else { return nil }

                return Self.withOptionalCString(language) { languagePointer in
                    Self.withOptionalCString(initialPrompt) { promptPointer in
                        wt_whisper_transcribe(
                            UnsafeMutableRawPointer(ctx),
                            baseAddress,
                            Int32(bufferPointer.count),
                            languagePointer,
                            translate,
                            noContext,
                            promptPointer
                        )
                    }
                }
            }

            guard let textPointer = textPtr else {
                DLOG("Whisper transcription returned no result")
                return nil
            }

            defer { free(textPointer) }

            let text = String(cString: textPointer)
            let processingTime = Date().timeIntervalSince(startTime)

            DebugLogger.shared.log(.transcriptCompleted(characterCount: text.count))

            return Result(text: text, processingTime: processingTime)
        }
    }

    /// Convenience method for streaming with default settings.
    func transcribeStreaming(
        samples: [Float],
        language: String? = nil,
        initialPrompt: String? = nil
    ) -> Result? {
        transcribe(
            samples: samples,
            language: language,
            translate: false,
            noContext: false,
            initialPrompt: initialPrompt
        )
    }

    /// Convenience method for final transcription with full context.
    func transcribeFinal(
        samples: [Float],
        language: String? = nil,
        initialPrompt: String? = nil
    ) -> Result? {
        transcribe(
            samples: samples,
            language: language,
            translate: false,
            noContext: false,
            initialPrompt: initialPrompt
        )
    }

    /// Converts the already ranked session hint snapshot into Whisper's compact
    /// initial prompt. Empty and duplicate entries are ignored without changing
    /// the relative order of the remaining terms.
    static func initialPrompt(for context: ASRRequestContext) -> String? {
        var seen = Set<String>()
        var prompt = ""
        for hint in context.vocabularyHints {
            let term = hint.writtenForm.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, seen.insert(term).inserted else { continue }
            let candidate = prompt.isEmpty ? term : "\(prompt), \(term)"
            guard candidate.utf8.count <= maximumInitialPromptUTF8Bytes else { continue }
            prompt = candidate
        }
        return prompt.isEmpty ? nil : prompt
    }

    /// `withCString` scopes each UTF-8 buffer across the complete synchronous
    /// native inference call. No pointer escapes into whisper.cpp state.
    private static func withOptionalCString<T>(
        _ value: String?,
        _ body: (UnsafePointer<CChar>?) -> T
    ) -> T {
        guard let value, !value.isEmpty else { return body(nil) }
        return value.withCString(body)
    }

    private func samples(from buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let channelData = buffer.floatChannelData else {
            return nil
        }
        let count = Int(buffer.frameLength)
        return Array(UnsafeBufferPointer(start: channelData[0], count: count))
    }
}
