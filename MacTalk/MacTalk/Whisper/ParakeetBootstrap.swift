//
//  ParakeetBootstrap.swift
//  MacTalk
//
//  Shared Parakeet source-model bootstrap and engine state.
//

import Foundation
import FluidAudio
import os

/// Consumer handle: retaining it keeps the verified snapshot bytes and CoreML
/// assets alive for every inference using this exact manager generation.
final class ParakeetBootstrapLoadedManager: @unchecked Sendable {
    let manager: AsrManager
    private let retained: AnyObject

    init(manager: AsrManager, retained: AnyObject) {
        self.manager = manager
        self.retained = retained
    }
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

protocol ParakeetBootstrapSourceAvailability: Sendable {
    func isAvailable() -> Bool
}

private struct UnavailableParakeetSource: ParakeetBootstrapSourceAvailability {
    func isAvailable() -> Bool { false }
}

private struct ProductionParakeetSourcePreparer: ParakeetBootstrapSourcePreparing {
    let parent: URL

    func prepare() async throws -> URL {
        let store = ParakeetSourceStore.canonical(parent: parent)
        let materializer = BoundedParakeetSourceArtifactMaterializer(
            transport: BoundedModelDownloadTransport(),
            workspaceRoot: parent.appendingPathComponent(".source-downloads", isDirectory: true)
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
            case .modelsNotAvailable: return "Parakeet models are not downloaded."
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

    private struct OperationOutcome: @unchecked Sendable {
        let loaded: ParakeetBootstrapLoadedManager
        let sourceURL: URL?
    }

    private struct LoadOperation: @unchecked Sendable {
        let generation: UInt64
        let task: Task<OperationOutcome, Error>
    }

    private struct State: @unchecked Sendable {
        var engineState: EngineState = .idle
        var generation: UInt64 = 0
        var publishedGeneration: UInt64?
        var loaded: ParakeetBootstrapLoadedManager?
        var operation: LoadOperation?
        var cleanupPending = false
        var cleanupInFlight = false
    }

    static let shared: ParakeetBootstrap = {
        let parent = ParakeetModelDownloader.modelsDirectory
        let store = ParakeetSourceStore.canonical(parent: parent)
        return ParakeetBootstrap(
            preparer: ProductionParakeetSourcePreparer(parent: parent),
            loader: ProductionParakeetVerifiedLoader(store: store),
            cleaner: ParakeetLegacyCompiledCleaner(parent: parent),
            availability: ParakeetSourceAvailability(store: store)
        )
    }()

    private let stateLock = OSAllocatedUnfairLock(initialState: State())
    /// Serializes state mutation with its corresponding notification. This
    /// prevents an obsolete generation from emitting after a newer state.
    private let transitionLock = NSLock()
    private let preparer: any ParakeetBootstrapSourcePreparing
    private let loader: any ParakeetBootstrapVerifiedLoading
    private let cleaner: any ParakeetBootstrapLegacyCleaning
    private let availability: any ParakeetBootstrapSourceAvailability

    init(
        preparer: any ParakeetBootstrapSourcePreparing,
        loader: any ParakeetBootstrapVerifiedLoading,
        cleaner: any ParakeetBootstrapLegacyCleaning,
        availability: any ParakeetBootstrapSourceAvailability = UnavailableParakeetSource()
    ) {
        self.preparer = preparer
        self.loader = loader
        self.cleaner = cleaner
        self.availability = availability
        ModelHub.offlineMode = true
    }

    func currentState() -> EngineState {
        stateLock.withLock { $0.engineState }
    }

    func currentLoadedManager() -> ParakeetBootstrapLoadedManager? {
        stateLock.withLock { $0.loaded }
    }

    func modelsAvailable() -> Bool {
        currentLoadedManager() != nil || availability.isAvailable()
    }

    func ensureReady() async throws -> ParakeetBootstrapLoadedManager {
        if let loaded = currentLoadedManager() {
            await retryCleanupIfNeeded()
            return loaded
        }
        let operation = startOperation(preparesSource: false, forceReplacement: false)
        return try await awaitOperation(operation).loaded
    }

    func reset() async {
        // Decoder state belongs to ParakeetEngineCore; immutable model handles
        // remain shared across engine sessions.
    }

    @discardableResult
    func downloadModels() async throws -> URL {
        let operation = startOperation(preparesSource: true, forceReplacement: true)
        return try await withTaskCancellationHandler(operation: {
            let outcome = try await awaitOperation(operation)
            guard let sourceURL = outcome.sourceURL else { throw BootstrapError.modelsNotAvailable }
            return sourceURL
        }, onCancel: { [weak self] in
            self?.cancelOperation(generation: operation.generation)
        })
    }

    private func startOperation(preparesSource: Bool, forceReplacement: Bool) -> LoadOperation {
        transitionLock.lock()
        let result: (operation: LoadOperation, previous: Task<OperationOutcome, Error>?, state: EngineState, created: Bool) = stateLock.withLock { state in
            if !forceReplacement, let existing = state.operation {
                return (existing, nil, state.engineState, false)
            }
            state.generation &+= 1
            let generation = state.generation
            let task = Task { [preparer, loader] () throws -> OperationOutcome in
                let sourceURL = preparesSource ? try await preparer.prepare() : nil
                try Task.checkCancellation()
                let loaded = try await loader.load()
                try Task.checkCancellation()
                return OperationOutcome(loaded: loaded, sourceURL: sourceURL)
            }
            let operation = LoadOperation(generation: generation, task: task)
            let previous = state.operation?.task
            state.operation = operation
            state.engineState = preparesSource ? .downloading : .loading
            return (operation, previous, state.engineState, true)
        }
        if result.created {
            NotificationCenter.default.post(name: .parakeetEngineStateDidChange, object: result.state)
        }
        transitionLock.unlock()
        result.previous?.cancel()
        return result.operation
    }

    private func awaitOperation(_ operation: LoadOperation) async throws -> OperationOutcome {
        do {
            let outcome = try await operation.task.value
            enum Publication { case owner, already, stale }
            let publication: Publication = transition(generation: operation.generation) { state in
                if state.publishedGeneration == operation.generation { return .already }
                state.loaded = outcome.loaded
                state.publishedGeneration = operation.generation
                state.operation = nil
                state.cleanupPending = true
                state.engineState = .ready
                return .owner
            } ?? .stale
            switch publication {
            case .stale:
                throw CancellationError()
            case .already:
                return outcome
            case .owner:
                await retryCleanupIfNeeded()
                return outcome
            }
        } catch {
            _ = transition(generation: operation.generation) { state in
                state.operation = nil
                state.engineState = state.loaded == nil ? failureState(for: error) : .ready
            }
            throw error
        }
    }

    private func cancelOperation(generation: UInt64) {
        transitionLock.lock()
        let cancelled: Task<OperationOutcome, Error>? = stateLock.withLock { state in
            guard state.generation == generation else { return nil }
            let task = state.operation?.task
            state.generation &+= 1
            state.operation = nil
            state.engineState = state.loaded == nil ? .idle : .ready
            return task
        }
        if cancelled != nil {
            NotificationCenter.default.post(name: .parakeetEngineStateDidChange, object: currentState())
        }
        transitionLock.unlock()
        cancelled?.cancel()
    }

    private func retryCleanupIfNeeded() async {
        let claimed = stateLock.withLock { state -> Bool in
            guard state.cleanupPending, !state.cleanupInFlight else { return false }
            state.cleanupInFlight = true
            return true
        }
        guard claimed else { return }
        do {
            try await cleaner.removeCompiledGeneration()
            stateLock.withLock { state in
                state.cleanupPending = false
                state.cleanupInFlight = false
            }
        } catch {
            stateLock.withLock { $0.cleanupInFlight = false }
        }
    }

    /// Performs a generation check, state transition, and notification under a
    /// single ordering lock. Returning nil means this generation is obsolete.
    private func transition<T: Sendable>(generation: UInt64, mutation: @Sendable (inout State) -> T) -> T? {
        transitionLock.lock()
        let result: (T, EngineState)? = stateLock.withLock { state in
            guard state.generation == generation else { return nil }
            let value = mutation(&state)
            return (value, state.engineState)
        }
        if let result {
            NotificationCenter.default.post(name: .parakeetEngineStateDidChange, object: result.1)
        }
        transitionLock.unlock()
        return result?.0
    }

    private func failureState(for error: Error) -> EngineState {
        if let bootstrap = error as? BootstrapError, bootstrap == .modelsNotAvailable { return .idle }
        if error is CancellationError { return .idle }
        return .failed(error.localizedDescription)
    }
}
