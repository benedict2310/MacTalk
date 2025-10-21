//
//  WhisperEngine.swift
//  MacTalk
//
//  Swift wrapper around whisper.cpp C API
//

import Foundation

final class WhisperEngine {
    private var ctx: OpaquePointer?
    private let queue = DispatchQueue(label: "com.mactalk.whisper.engine", qos: .userInitiated)

    struct Result {
        let text: String
        let processingTime: TimeInterval
    }

    init?(modelURL: URL) {
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            print("Model file does not exist at path: \(modelURL.path)")
            return nil
        }

        let cPath = (modelURL.path as NSString).utf8String
        guard let path = cPath, let context = wt_whisper_init(path) else {
            print("Failed to initialize Whisper context")
            return nil
        }

        self.ctx = OpaquePointer(context)
        print("Whisper engine initialized with model: \(modelURL.lastPathComponent)")
    }

    deinit {
        if let ctx = ctx {
            wt_whisper_free(UnsafeMutableRawPointer(ctx))
        }
    }

    /// Transcribe audio samples (16kHz mono float32)
    func transcribe(
        samples: [Float],
        language: String? = nil,
        translate: Bool = false,
        noContext: Bool = false
    ) -> Result? {
        guard let ctx = ctx else {
            print("Whisper context is nil")
            return nil
        }

        guard !samples.isEmpty else {
            print("No samples to transcribe")
            return nil
        }

        return queue.sync {
            let startTime = Date()

            let textPtr = samples.withUnsafeBufferPointer { bufferPointer -> UnsafeMutablePointer<CChar>? in
                guard let baseAddress = bufferPointer.baseAddress else { return nil }

                let langCStr = language?.cString(using: .utf8)
                return wt_whisper_transcribe(
                    UnsafeMutableRawPointer(ctx),
                    baseAddress,
                    Int32(bufferPointer.count),
                    langCStr,
                    translate,
                    noContext
                )
            }

            guard let textPointer = textPtr else {
                print("Transcription returned nil")
                return nil
            }

            defer { free(textPointer) }

            let text = String(cString: textPointer)
            let processingTime = Date().timeIntervalSince(startTime)

            print("Transcribed \(samples.count) samples in \(processingTime)s: \(text.prefix(50))...")

            return Result(text: text, processingTime: processingTime)
        }
    }

    /// Convenience method for streaming with default settings
    func transcribeStreaming(samples: [Float], language: String? = nil) -> Result? {
        return transcribe(samples: samples, language: language, translate: false, noContext: false)
    }

    /// Convenience method for final transcription with full context
    func transcribeFinal(samples: [Float], language: String? = nil) -> Result? {
        return transcribe(samples: samples, language: language, translate: false, noContext: false)
    }
}
