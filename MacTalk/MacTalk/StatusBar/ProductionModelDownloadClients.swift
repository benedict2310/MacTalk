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

@MainActor
final class WhisperModelDownloadClient {
    private let manager: ModelManager
    private var completed = false

    init(manager: ModelManager = .shared) { self.manager = manager }

    func download(_ spec: ModelSpec, onEvent: @escaping @MainActor (ModelDownloadClientEvent) -> Void) async throws {
        completed = false
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.onDownloadState = { [weak self] state in
                guard let self, !self.completed else { return }
                switch state {
                case let .running(progress): onEvent(.downloading(fraction: progress, fileIndex: nil, fileCount: nil))
                case .verifying: onEvent(.verifying)
                case .done:
                    self.completed = true
                    onEvent(.ready)
                    continuation.resume()
                case let .failed(error):
                    self.completed = true
                    continuation.resume(throwing: error)
                case .idle: break
                }
            }
            manager.ensureAvailable(spec) { [weak self] result in
                guard let self, !self.completed else { return }
                if case let .failure(error) = result {
                    self.completed = true
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func cancel() {
        manager.cancelDownload()
        completed = true
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
