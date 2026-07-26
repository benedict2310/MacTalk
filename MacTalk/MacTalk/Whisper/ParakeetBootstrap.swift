//
//  ParakeetBootstrap.swift
//  MacTalk
//
//  Shared Parakeet source-model bootstrap and engine state.
//

import Foundation
import FluidAudio
import os

struct ParakeetBootstrapLoadedManager: @unchecked Sendable {
    let manager: AsrManager
    /// Owns the verified snapshot bytes and CoreML assets for at least as long
    /// as the manager can be returned to an engine.
    let retained: AnyObject
}

protocol ParakeetBootstrapSourcePreparing: Sendable {
    func prepare() async throws -> URL
}

protocol ParakeetBootstrapVerifiedLoading: Sendable {
    func load() async throws -> ParakeetBootstrapLoadedManager
}

protocol ParakeetBootstrapLegacyCleaning: Sendable {
    func removeCompiledGeneration() async throws
}

private struct ProductionParakeetSourcePreparer: ParakeetBootstrapSourcePreparing {
    let parent: URL

    func prepare() async throws -> URL {
        let store = ParakeetSourceStore.canonical(parent: parent)
        let workspace = parent.appendingPathComponent(".source-downloads", isDirectory: true)
        let materializer = BoundedParakeetSourceArtifactMaterializer(
            transport: BoundedModelDownloadTransport(),
            workspaceRoot: workspace
        )
        let reuser = try ParakeetCompiledWeightReuser(
            store: store,
            sourceEntries: GeneratedModelProvenance.parakeetSource,
            compiledEntries: GeneratedModelProvenance.parakeetCompiled
        )
        return try await ParakeetSourcePreparer(
            store: store,
            materializer: materializer,
            weightReuser: reuser
        ).prepareIfNeeded()
    }
}

private struct ProductionParakeetVerifiedLoader: ParakeetBootstrapVerifiedLoading {
    let store: ParakeetSourceStore

    func load() async throws -> ParakeetBootstrapLoadedManager {
        let snapshot: VerifiedParakeetSourceSnapshot
        do {
            snapshot = try await VerifiedParakeetSourceSnapshotProvider(store: store).makeVerifiedSnapshot()
        } catch let error as ParakeetSourceSnapshotError {
            if error == .cancelled { throw CancellationError() }
            throw ParakeetBootstrap.BootstrapError.modelsNotAvailable
        }
        let loaded = try await VerifiedParakeetModelLoader().load(snapshot: snapshot, policy: .production)
        let manager = AsrManager()
        try await manager.loadModels(loaded.models)
        return ParakeetBootstrapLoadedManager(manager: manager, retained: loaded)
    }
}

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

    private struct LoadOperation: @unchecked Sendable {
        let generation: UInt64
        let task: Task<ParakeetBootstrapLoadedManager, Error>
    }

    private struct State: @unchecked Sendable {
        var engineState: EngineState = .idle
        var generation: UInt64 = 0
        var publishedGeneration: UInt64?
        var loaded: ParakeetBootstrapLoadedManager?
        var loadOperation: LoadOperation?
    }

    static let shared: ParakeetBootstrap = {
        let parent = ParakeetModelDownloader.modelsDirectory
        let store = ParakeetSourceStore.canonical(parent: parent)
        return ParakeetBootstrap(
            preparer: ProductionParakeetSourcePreparer(parent: parent),
            loader: ProductionParakeetVerifiedLoader(store: store),
            cleaner: ParakeetLegacyCompiledCleaner(parent: parent)
        )
    }()

    private let stateLock = OSAllocatedUnfairLock(initialState: State())
    private let preparer: any ParakeetBootstrapSourcePreparing
    private let loader: any ParakeetBootstrapVerifiedLoading
    private let cleaner: any ParakeetBootstrapLegacyCleaning

    init(
        preparer: any ParakeetBootstrapSourcePreparing,
        loader: any ParakeetBootstrapVerifiedLoading,
        cleaner: any ParakeetBootstrapLegacyCleaning
    ) {
        self.preparer = preparer
        self.loader = loader
        self.cleaner = cleaner
        // FluidAudio must not repair or replace MacTalk's verified source.
        ModelHub.offlineMode = true
    }

    func currentState() -> EngineState {
        stateLock.withLock { $0.engineState }
    }

    func currentManager() -> AsrManager? {
        stateLock.withLock { $0.loaded?.manager }
    }

    func ensureReady() async throws -> AsrManager {
        if let manager = currentManager() { return manager }
        let operation = startLoad(forceReplacement: false)
        return try await awaitLoad(operation)
    }

    func reset() async {
        // Decoder state belongs to ParakeetEngineCore; immutable loaded source
        // models remain shared across engine sessions.
    }

    @discardableResult
    func downloadModels() async throws -> URL {
        setEngineState(.downloading)
        do {
            let sourceURL = try await preparer.prepare()
            let operation = startLoad(forceReplacement: true)
            _ = try await awaitLoad(operation)
            return sourceURL
        } catch {
            handleFailure(error)
            throw error
        }
    }

    private func startLoad(forceReplacement: Bool) -> LoadOperation {
        let (operation, cancelled): (LoadOperation, Task<ParakeetBootstrapLoadedManager, Error>?) = stateLock.withLock { state in
            if !forceReplacement, let existing = state.loadOperation {
                return (existing, nil)
            }
            state.generation &+= 1
            let generation = state.generation
            let task = Task { [loader] in try await loader.load() }
            let previous = state.loadOperation?.task
            let operation = LoadOperation(generation: generation, task: task)
            state.loadOperation = operation
            state.engineState = .loading
            return (operation, previous)
        }
        cancelled?.cancel()
        postEngineState(.loading)
        return operation
    }

    private func awaitLoad(_ operation: LoadOperation) async throws -> AsrManager {
        do {
            let loaded = try await operation.task.value
            enum Publication { case owner, already, stale }
            let publication: Publication = stateLock.withLock { state in
                guard state.generation == operation.generation else { return .stale }
                if state.publishedGeneration == operation.generation { return .already }
                state.loaded = loaded
                state.publishedGeneration = operation.generation
                state.loadOperation = nil
                state.engineState = .ready
                return .owner
            }
            switch publication {
            case .stale:
                throw CancellationError()
            case .already:
                return loaded.manager
            case .owner:
                postEngineState(.ready)
                // Compiled retirement is post-publication and best effort. A
                // cleanup failure must not revoke a verified source manager.
                try? await cleaner.removeCompiledGeneration()
                return loaded.manager
            }
        } catch {
            let ownsFailure = stateLock.withLock { state -> Bool in
                guard state.generation == operation.generation else { return false }
                state.loadOperation = nil
                state.engineState = state.loaded == nil ? failureState(for: error) : .ready
                return true
            }
            if ownsFailure { postEngineState(currentState()) }
            throw error
        }
    }

    private func handleFailure(_ error: Error) {
        let next: EngineState = stateLock.withLock { state in
            if state.loaded != nil { state.engineState = .ready }
            else { state.engineState = failureState(for: error) }
            return state.engineState
        }
        postEngineState(next)
    }

    private func failureState(for error: Error) -> EngineState {
        if let bootstrap = error as? BootstrapError, bootstrap == .modelsNotAvailable { return .idle }
        if error is CancellationError { return .idle }
        return .failed(error.localizedDescription)
    }

    private func setEngineState(_ value: EngineState) {
        stateLock.withLock { $0.engineState = value }
        postEngineState(value)
    }

    private func postEngineState(_ value: EngineState) {
        NotificationCenter.default.post(name: .parakeetEngineStateDidChange, object: value)
    }
}
