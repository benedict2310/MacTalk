//
//  ParakeetEngine.swift
//  MacTalk
//
//  ASREngine wrapper for FluidAudio Parakeet models
//

import Foundation
@preconcurrency import AVFoundation
import FluidAudio

final class ParakeetEngine: @unchecked Sendable, ASREngine {
    private let bootstrap: ParakeetBootstrap
    private let core: ParakeetEngineCore

    let provider: ASRProvider = .parakeet

    init(bootstrap: ParakeetBootstrap = .shared) {
        self.bootstrap = bootstrap
        self.core = ParakeetEngineCore(bootstrap: bootstrap)
    }

    func prepare() async throws {
        try await core.prepare()
    }

    func reset() async {
        await core.reset()
    }

    func process(_ buffer: AVAudioPCMBuffer, language: String?) async throws -> ASRPartial? {
        let result = try await core.transcribe(buffer: buffer)
        let words = mapWords(from: result)
        return ASRPartial(text: result.text, words: words)
    }

    func finalize(_ buffer: AVAudioPCMBuffer, language: String?) async throws -> ASRFinalSegment? {
        let result = try await core.finalize(buffer: buffer)
        let words = mapWords(from: result)
        return ASRFinalSegment(text: result.text, words: words)
    }

    private func mapWords(from result: ASRResult) -> [ASRWord] {
        guard let tokenTimings = result.tokenTimings else { return [] }
        return tokenTimings.map { timing in
            ASRWord(
                text: timing.token,
                startTime: timing.startTime,
                endTime: timing.endTime,
                confidence: timing.confidence
            )
        }
    }
}

private actor ParakeetEngineCore {
    private let bootstrap: ParakeetBootstrap
    private var manager: AsrManager?
    private var decoderState: TdtDecoderState?

    init(bootstrap: ParakeetBootstrap) {
        self.bootstrap = bootstrap
    }

    func prepare() async throws {
        manager = try await bootstrap.ensureReady()
    }

    func reset() async {
        decoderState = nil
        await bootstrap.reset()
    }

    func transcribe(buffer: AVAudioPCMBuffer) async throws -> ASRResult {
        let manager = try await bootstrap.ensureReady()
        if decoderState == nil {
            decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        }
        var state = decoderState!
        let result = try await manager.transcribe(buffer, decoderState: &state)
        decoderState = state
        return result
    }

    func finalize(buffer: AVAudioPCMBuffer) async throws -> ASRResult {
        let manager = try await bootstrap.ensureReady()
        var finalState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        return try await manager.transcribe(buffer, decoderState: &finalState)
    }
}
