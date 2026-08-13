//
//  ASREngine.swift
//  MacTalk
//
//  Abstractions for Whisper and Parakeet ASR engines
//

import Foundation
@preconcurrency import AVFoundation

/// Provider-neutral priority assigned before a recording starts. Providers may
/// translate it into their own hinting mechanism, but it never carries decoder
/// or model-specific state.
enum ASRVocabularyPriority: Int, Sendable, Equatable, Comparable {
    case low
    case normal
    case high

    static func < (lhs: ASRVocabularyPriority, rhs: ASRVocabularyPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// One immutable vocabulary hint from the recording session's vocabulary
/// snapshot. The identifier is suitable for diagnostics; term text is not.
struct ASRVocabularyHint: Sendable, Equatable {
    let id: UUID
    let writtenForm: String
    let spokenForm: String?
    let priority: ASRVocabularyPriority
}

/// Immutable, session-scoped inputs shared by every inference in one recording.
/// Provider-specific thresholds and decoder state intentionally do not belong
/// at this boundary.
struct ASRRequestContext: Sendable, Equatable {
    let language: String?
    let vocabularyHints: [ASRVocabularyHint]
    let vocabularySnapshotID: UUID?

    init(
        language: String? = nil,
        vocabularyHints: [ASRVocabularyHint] = [],
        vocabularySnapshotID: UUID? = nil
    ) {
        self.language = language
        self.vocabularyHints = vocabularyHints
        self.vocabularySnapshotID = vocabularySnapshotID
    }
}

enum ASRVocabularyHintingUnavailableReason: Sendable, Equatable {
    /// The provider needs another model artifact which has not yet been added
    /// to MacTalk's immutable, hash-verified model catalog.
    case additionalVerifiedResourcesRequired
}

/// Describes recognition-time support only. Deterministic transcript
/// replacement remains available independently of this provider capability.
enum ASRVocabularyHintingCapability: Sendable, Equatable {
    case initialPrompt
    case customVocabulary
    case unavailable(ASRVocabularyHintingUnavailableReason)
}

enum ASRProvider: String, CaseIterable, Codable, Sendable {
    case whisper
    case parakeet

    var displayName: String {
        switch self {
        case .whisper:
            return "Whisper"
        case .parakeet:
            return "Parakeet"
        }
    }

    /// Parakeet's shared FluidAudio manager must not receive an incremental
    /// inference and final inference at the same time. Cancelling an in-flight
    /// incremental request can leave finalization waiting indefinitely.
    var usesIncrementalChunkProcessing: Bool {
        switch self {
        case .whisper:
            return true
        case .parakeet:
            return false
        }
    }

    var vocabularyHintingCapability: ASRVocabularyHintingCapability {
        switch self {
        case .whisper:
            return .initialPrompt
        case .parakeet:
            return .unavailable(.additionalVerifiedResourcesRequired)
        }
    }
}

struct ASRWord: Sendable, Equatable {
    let text: String
    let startTime: TimeInterval?
    let endTime: TimeInterval?
    let confidence: Float?
}

struct ASRPartial: Sendable, Equatable {
    let text: String
    let words: [ASRWord]
}

struct ASRFinalSegment: Sendable, Equatable {
    let text: String
    let words: [ASRWord]
}

protocol ASREngine: Sendable {
    var provider: ASRProvider { get }
    var vocabularyHintingCapability: ASRVocabularyHintingCapability { get }

    func prepare() async throws
    func reset() async

    func process(_ buffer: AVAudioPCMBuffer, language: String?) async throws -> ASRPartial?
    func finalize(_ buffer: AVAudioPCMBuffer, language: String?) async throws -> ASRFinalSegment?

    func process(_ buffer: AVAudioPCMBuffer, context: ASRRequestContext) async throws -> ASRPartial?
    func finalize(_ buffer: AVAudioPCMBuffer, context: ASRRequestContext) async throws -> ASRFinalSegment?
}

extension ASREngine {
    var vocabularyHintingCapability: ASRVocabularyHintingCapability {
        provider.vocabularyHintingCapability
    }

    /// Compatibility adapter for engines that do not yet provide native
    /// recognition-time vocabulary support.
    func process(_ buffer: AVAudioPCMBuffer, context: ASRRequestContext) async throws -> ASRPartial? {
        try await process(buffer, language: context.language)
    }

    /// Compatibility adapter preserves existing behavior and makes an
    /// unavailable hinting resource non-fatal.
    func finalize(_ buffer: AVAudioPCMBuffer, context: ASRRequestContext) async throws -> ASRFinalSegment? {
        try await finalize(buffer, language: context.language)
    }

    func process(samples: [Float], language: String?) async throws -> ASRPartial? {
        guard let buffer = Self.makePCMBuffer(samples: samples) else {
            return nil
        }
        return try await process(buffer, language: language)
    }

    func process(samples: [Float], context: ASRRequestContext) async throws -> ASRPartial? {
        guard let buffer = Self.makePCMBuffer(samples: samples) else {
            return nil
        }
        return try await process(buffer, context: context)
    }

    func finalize(samples: [Float], language: String?) async throws -> ASRFinalSegment? {
        guard let buffer = Self.makePCMBuffer(samples: samples) else {
            return nil
        }
        return try await finalize(buffer, language: language)
    }

    func finalize(samples: [Float], context: ASRRequestContext) async throws -> ASRFinalSegment? {
        guard let buffer = Self.makePCMBuffer(samples: samples) else {
            return nil
        }
        return try await finalize(buffer, context: context)
    }

    private static func makePCMBuffer(samples: [Float]) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty else { return nil }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            return nil
        }

        let frameCount = AVAudioFrameCount(samples.count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        buffer.frameLength = frameCount

        samples.withUnsafeBufferPointer { pointer in
            guard let baseAddress = pointer.baseAddress else { return }
            if let channelData = buffer.floatChannelData {
                let byteCount = samples.count * MemoryLayout<Float>.stride
                memcpy(channelData[0], baseAddress, byteCount)
            }
        }

        return buffer
    }
}
