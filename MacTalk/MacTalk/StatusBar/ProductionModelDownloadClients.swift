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
    private var continuation: CheckedContinuation<Void, Error>?

    func install(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        let previous = self.continuation
        self.continuation = continuation
        lock.unlock()

        // A direct adapter user can start a replacement download before the
        // prior manager operation reports its terminal state. Do not leave the
        // prior waiter suspended while handing ownership to the replacement.
        previous?.resume(throwing: CancellationError())
    }

    @discardableResult
    func finish(_ result: Result<Void, Error>) -> Bool {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return false
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
        return true
    }

    func cancel() {
        _ = finish(.failure(CancellationError()))
    }

    func isActive() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return continuation != nil
    }
}

@MainActor
final class WhisperModelDownloadClient {
    private let manager: any ModelManaging
    private let continuationOwner = WhisperDownloadContinuationOwner()

    init(manager: any ModelManaging = ModelManager.shared) { self.manager = manager }

    func download(_ spec: ModelSpec, onEvent: @escaping @MainActor (ModelDownloadClientEvent) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            continuationOwner.install(continuation)
            manager.onDownloadState = { [weak self] state in
                guard let self, self.continuationOwner.isActive() else { return }
                switch state {
                case let .running(progress):
                    onEvent(.downloading(fraction: progress, fileIndex: nil, fileCount: nil))
                case .verifying:
                    onEvent(.verifying)
                case .done:
                    guard self.continuationOwner.finish(.success(())) else { return }
                    onEvent(.ready)
                case let .failed(error):
                    _ = self.continuationOwner.finish(.failure(error))
                case .idle:
                    break
                }
            }
            manager.ensureAvailable(spec) { [weak self] result in
                guard let self else { return }
                if case let .failure(error) = result {
                    _ = self.continuationOwner.finish(.failure(error))
                }
            }
        }
    }

    func cancel() {
        // Claim and resume the continuation before asking ModelManager to
        // cancel. Its cancellation callback may race or arrive synchronously;
        // the owner makes every later result a no-op.
        continuationOwner.cancel()
        manager.cancelDownload()
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
