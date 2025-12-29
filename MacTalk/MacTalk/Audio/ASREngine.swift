//
//  ASREngine.swift
//  MacTalk
//
//  Abstractions for Whisper and Parakeet ASR engines
//

import Foundation
@preconcurrency import AVFoundation

enum ASRProvider: String, CaseIterable, Sendable {
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

    func prepare() async throws
    func reset() async

    func process(_ buffer: AVAudioPCMBuffer, language: String?) async throws -> ASRPartial?
    func finalize(_ buffer: AVAudioPCMBuffer, language: String?) async throws -> ASRFinalSegment?

    func setPartialHandler(_ handler: (@Sendable (ASRPartial) -> Void)?)
}

extension ASREngine {
    func process(samples: [Float], language: String?) async throws -> ASRPartial? {
        guard let buffer = Self.makePCMBuffer(samples: samples) else {
            return nil
        }
        return try await process(buffer, language: language)
    }

    func finalize(samples: [Float], language: String?) async throws -> ASRFinalSegment? {
        guard let buffer = Self.makePCMBuffer(samples: samples) else {
            return nil
        }
        return try await finalize(buffer, language: language)
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
