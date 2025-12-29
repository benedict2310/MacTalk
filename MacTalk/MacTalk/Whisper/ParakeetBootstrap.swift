//
//  ParakeetBootstrap.swift
//  MacTalk
//
//  Shared Parakeet model bootstrap and engine state
//

import Foundation
import CoreML
import FluidAudio
import os

extension AsrManager: @unchecked Sendable {}

final class ParakeetBootstrap: @unchecked Sendable {
    enum BootstrapError: LocalizedError, Sendable, Equatable {
        case modelsNotAvailable

        var errorDescription: String? {
            switch self {
            case .modelsNotAvailable:
                return "Parakeet models are not downloaded."
            }
        }
    }
    enum EngineState: Sendable, Equatable {
        case idle
        case downloading
        case loading
        case ready
        case failed(String)
    }

    static let shared = ParakeetBootstrap()

    private struct State: @unchecked Sendable {
        var engineState: EngineState = .idle
        var manager: AsrManager?
        var loadTask: Task<AsrManager, Error>?
    }

    private let stateLock = OSAllocatedUnfairLock(initialState: State())
    private let downloader = ParakeetModelDownloader()

    private init() {
        downloader.onState = { [weak self] state in
            self?.handleDownloadState(state)
        }
    }

    func currentState() -> EngineState {
        stateLock.withLock { $0.engineState }
    }

    func currentManager() -> AsrManager? {
        stateLock.withLock { $0.manager }
    }

    func ensureReady() async throws -> AsrManager {
        if let manager = currentManager() {
            return manager
        }

        if let existingTask = stateLock.withLock({ $0.loadTask }) {
            return try await existingTask.value
        }

        let task = Task { [weak self] () throws -> AsrManager in
            guard let self else {
                throw NSError(domain: "ParakeetBootstrap", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "Parakeet bootstrap unavailable."
                ])
            }

            try await self.ensureModelsAvailable()
            let manager = try await self.loadManager()
            return manager
        }

        stateLock.withLock { state in
            state.loadTask = task
        }

        do {
            let manager = try await task.value
            stateLock.withLock { state in
                state.manager = manager
                state.loadTask = nil
            }
            setEngineState(.ready)
            return manager
        } catch {
            stateLock.withLock { state in
                state.loadTask = nil
            }
            if let bootstrapError = error as? BootstrapError, bootstrapError == .modelsNotAvailable {
                setEngineState(.idle)
            } else {
                setEngineState(.failed(error.localizedDescription))
            }
            throw error
        }
    }

    func reset() async {
        guard let manager = currentManager() else { return }
        try? await manager.resetDecoderState()
    }

    private func ensureModelsAvailable() async throws {
        guard downloader.modelsAvailable() else {
            throw BootstrapError.modelsNotAvailable
        }
    }

    @discardableResult
    func downloadModels() async throws -> URL {
        setEngineState(.downloading)
        do {
            let url = try await downloader.downloadIfNeeded()
            setEngineState(.idle)
            return url
        } catch {
            setEngineState(.failed(error.localizedDescription))
            throw error
        }
    }

    private func loadManager() async throws -> AsrManager {
        setEngineState(.loading)

        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine

        let modelsPath = ParakeetModelDownloader.repoDirectory
        let models = try await AsrModels.load(from: modelsPath, configuration: config, version: .v3)

        let manager = AsrManager()
        try await manager.initialize(models: models)

        return manager
    }

    private func handleDownloadState(_ state: ParakeetModelDownloader.State) {
        NotificationCenter.default.post(name: .parakeetDownloadStateDidChange, object: state)
    }

    private func setEngineState(_ state: EngineState) {
        stateLock.withLock { $0.engineState = state }
        NotificationCenter.default.post(name: .parakeetEngineStateDidChange, object: state)
    }
}
