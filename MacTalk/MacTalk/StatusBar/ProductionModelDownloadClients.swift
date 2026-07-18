import Foundation

/// Production callback adapters live outside coordinator files so static
/// singleton APIs remain confined to the composition boundary.
@MainActor
final class ProductionModelDownloadClient: ModelDownloadClient {
    private let whisper: WhisperModelDownloadClient
    private let parakeet: ParakeetModelDownloadClient

    init(
        whisper: WhisperModelDownloadClient = WhisperModelDownloadClient(),
        parakeet: ParakeetModelDownloadClient = ParakeetModelDownloadClient()
    ) {
        self.whisper = whisper
        self.parakeet = parakeet
    }

    func download(_ requirement: ModelRequirement, onEvent: @escaping @MainActor (ModelDownloadClientEvent) -> Void) async throws {
        switch requirement {
        case let .whisper(spec): try await whisper.download(spec, onEvent: onEvent)
        case .parakeet: try await parakeet.download(onEvent: onEvent)
        }
    }

    func cancel() {
        whisper.cancel()
        parakeet.cancel()
    }
}

private final class WhisperDownloadContinuationOwner: @unchecked Sendable {
    private let lock = NSLock()
    private var operationID: ModelDownloadOperationID?
    private var continuation: CheckedContinuation<Void, Error>?

    func install(_ continuation: CheckedContinuation<Void, Error>, operationID: ModelDownloadOperationID) {
        lock.lock()
        let previous = self.continuation
        self.operationID = operationID
        self.continuation = continuation
        lock.unlock()

        // A direct adapter user can start a replacement download before the
        // prior manager operation reports its terminal state. Do not leave the
        // prior waiter suspended while handing ownership to the replacement.
        previous?.resume(throwing: CancellationError())
    }

    @discardableResult
    func finish(_ result: Result<Void, Error>, operationID: ModelDownloadOperationID) -> Bool {
        lock.lock()
        guard self.operationID == operationID, let continuation else {
            lock.unlock()
            return false
        }
        self.operationID = nil
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
        return true
    }

    func invalidate() -> ModelDownloadOperationID? {
        lock.lock()
        let operationID = self.operationID
        self.operationID = nil
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
        return operationID
    }

    func isActive(_ operationID: ModelDownloadOperationID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return self.operationID == operationID && continuation != nil
    }
}

@MainActor
final class WhisperModelDownloadClient {
    private let manager: any ModelManaging
    private let continuationOwner = WhisperDownloadContinuationOwner()

    init(manager: any ModelManaging = ModelManager.shared) { self.manager = manager }

    func download(_ spec: ModelSpec, onEvent: @escaping @MainActor (ModelDownloadClientEvent) -> Void) async throws {
        let operationID = ModelDownloadOperationID()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            continuationOwner.install(continuation, operationID: operationID)
            manager.ensureAvailable(spec, operationID: operationID, onState: { [weak self] callbackOperationID, state in
                guard let self,
                      callbackOperationID == operationID,
                      self.continuationOwner.isActive(operationID) else { return }
                switch state {
                case let .running(progress):
                    onEvent(.downloading(fraction: progress, fileIndex: nil, fileCount: nil))
                case .verifying:
                    onEvent(.verifying)
                case .done:
                    guard self.continuationOwner.finish(.success(()), operationID: operationID) else { return }
                    onEvent(.ready)
                case .failed, .idle:
                    break
                }
            }) { [weak self] callbackOperationID, result in
                guard let self, callbackOperationID == operationID else { return }
                if case let .failure(error) = result {
                    _ = self.continuationOwner.finish(.failure(error), operationID: operationID)
                }
            }
        }
    }

    func cancel() {
        // Invalidate the adapter operation before asking ModelManager to
        // cancel. ModelManager performs the same synchronous invalidation
        // before touching ModelDownloader, so a late A callback cannot reach B.
        guard let operationID = continuationOwner.invalidate() else { return }
        manager.cancelDownload(operationID: operationID)
    }
}

@MainActor
final class ParakeetModelDownloadClient {
    private let bootstrap: ParakeetBootstrap
    private var task: Task<Void, Error>?

    init(bootstrap: ParakeetBootstrap = .shared) { self.bootstrap = bootstrap }

    func download(onEvent: @escaping @MainActor (ModelDownloadClientEvent) -> Void) async throws {
        onEvent(.verifying)
        task = Task { @MainActor in
            _ = try await bootstrap.downloadModels()
        }
        try await task!.value
        onEvent(.ready)
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
