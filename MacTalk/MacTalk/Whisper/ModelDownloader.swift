import Foundation

protocol BoundedModelDownloading: Sendable {
    func download(_ request: BoundedModelDownloadRequest) async throws -> URL
    func cancel(operationID: UUID)
}

extension BoundedModelDownloadTransport: BoundedModelDownloading {}

/// Downloader for immutable Whisper artifacts. The bounded transport owns all
/// network, partial-file, resume, size, and mirror policy; this type owns the
/// app-facing state machine and final model-store verification.
final class ModelDownloader: @unchecked Sendable {
    enum State: Equatable, Sendable {
        case idle
        case running(progress: Double)
        case verifying
        case done(URL)
        case failed(Error)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.verifying, .verifying): return true
            case (.running(let a), .running(let b)): return a == b
            case (.done(let a), .done(let b)): return a == b
            case (.failed(let a), .failed(let b)): return a.localizedDescription == b.localizedDescription
            default: return false
            }
        }
    }

    enum ErrorType: Swift.Error, LocalizedError, Sendable {
        case noURLs
        case invalidFilename
        case noSpace
        case cancelled
        case network(Swift.Error)
        case badChecksum
        case httpStatus(Int)
        case io(Swift.Error)

        var errorDescription: String? {
            switch self {
            case .noURLs: return "No download URLs are available."
            case .invalidFilename: return "The model filename is invalid."
            case .noSpace: return "Not enough free disk space."
            case .cancelled: return "Download was cancelled."
            case .network(let error): return "Network error: \(error.localizedDescription)"
            case .badChecksum: return "Checksum verification failed."
            case .httpStatus(let status): return "Model download failed (HTTP \(status))."
            case .io(let error): return "File error: \(error.localizedDescription)"
            }
        }
    }

    var onOperationState: (@MainActor @Sendable (UUID, State) -> Void)?
    var onState: (@MainActor (State) -> Void)?

    private let modelRoot: URL
    private let downloadsRoot: URL
    private let transport: any BoundedModelDownloading
    private var operation: Task<Void, Never>?
    private var generation = 0
    private var operationID: UUID?
    private let stateLock = NSLock()
    private let commitLock = NSLock()

    init(modelRoot: URL? = nil, downloadsRoot: URL? = nil,
         transport: any BoundedModelDownloading = BoundedModelDownloadTransport()) {
        self.modelRoot = modelRoot ?? ModelStore.modelsDir
        self.downloadsRoot = downloadsRoot ?? self.modelRoot.appendingPathComponent(".downloads", isDirectory: true)
        self.transport = transport
        try? FileManager.default.createDirectory(at: self.modelRoot, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: self.downloadsRoot, withIntermediateDirectories: true)
    }

    func start(spec: ModelSpec, operationID: UUID = UUID()) {
        let (currentGeneration, previousTask, previousID) = claimReplacingCurrent(with: operationID)
        if !isDirectChildFilename(spec.filename) {
            previousTask?.cancel()
            if let previousID { transport.cancel(operationID: previousID) }
            notifyState(.failed(ErrorType.invalidFilename), generation: currentGeneration, operationID: operationID)
            finishSynchronously(generation: currentGeneration, operationID: operationID)
            return
        }

        removeLegacyResumeState(for: spec)

        guard ModelIntegrityVerifier.isValidDigest(spec.sha256), spec.sizeBytes > 0,
              !spec.revision.isEmpty, !spec.source.isEmpty else {
            notifyState(.failed(ErrorType.badChecksum), generation: currentGeneration, operationID: operationID)
            finishSynchronously(generation: currentGeneration, operationID: operationID)
            return
        }
        guard !spec.urls.isEmpty else {
            notifyState(.failed(ErrorType.noURLs), generation: currentGeneration, operationID: operationID)
            finishSynchronously(generation: currentGeneration, operationID: operationID)
            return
        }

        let destination = modelRoot.appendingPathComponent(spec.filename)
        if FileManager.default.fileExists(atPath: destination.path) {
            do {
                try ModelIntegrityVerifier.validate(source: destination, spec: spec)
                commitLock.lock()
                let ownsCache = isCurrent(generation: currentGeneration, operationID: operationID)
                commitLock.unlock()
                guard ownsCache else { return }
                notifyState(.done(destination), generation: currentGeneration, operationID: operationID)
                finishSynchronously(generation: currentGeneration, operationID: operationID)
                return
            } catch {
                commitLock.lock()
                stateLock.lock()
                let ownsCache = self.generation == currentGeneration && self.operationID == operationID
                if ownsCache { try? FileManager.default.removeItem(at: destination) }
                stateLock.unlock()
                commitLock.unlock()
                guard ownsCache else { return }
            }
        }

        notifyState(.running(progress: 0), generation: currentGeneration, operationID: operationID)
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.run(spec: spec, destination: destination, generation: currentGeneration, operationID: operationID)
        }
        stateLock.lock()
        let ownsTask = self.generation == currentGeneration && self.operationID == operationID
        if ownsTask { operation = task }
        stateLock.unlock()
        if !ownsTask { task.cancel() }
    }

    func cancel() {
        stateLock.lock()
        guard let currentID = operationID else {
            stateLock.unlock()
            return
        }
        let currentTask = operation
        generation += 1
        let cancelledGeneration = generation
        operation = nil
        operationID = nil
        stateLock.unlock()
        currentTask?.cancel()
        transport.cancel(operationID: currentID)
        notifyState(.failed(ErrorType.cancelled), generation: cancelledGeneration, operationID: currentID)
    }

    private func run(spec: ModelSpec, destination: URL, generation: Int, operationID: UUID) async {
        do {
            try requireCurrent(generation)
            let identity = DownloadArtifactIdentity(
                schemaVersion: 1,
                provider: "whisper",
                modelID: spec.id,
                sourceRepository: spec.source,
                revision: spec.revision,
                artifactPath: spec.filename,
                filename: spec.filename,
                sha256: spec.sha256,
                sizeBytes: spec.sizeBytes
            )
            let request = BoundedModelDownloadRequest(
                identity: identity,
                mirrors: spec.urls,
                operationID: operationID,
                workspaceRoot: downloadsRoot,
                aggregateDiskBytesStillRequired: spec.sizeBytes,
                credentialToken: Self.environmentToken,
                progress: { [weak self] received, total in
                    guard total > 0 else { return }
                    self?.notifyState(.running(progress: min(1, Double(received) / Double(total))), generation: generation, operationID: operationID)
                }
            )
            let temporaryURL = try await transport.download(request)
            defer { try? FileManager.default.removeItem(at: temporaryURL) }
            try requireCurrent(generation)
            notifyState(.verifying, generation: generation, operationID: operationID)
            try ModelIntegrityVerifier.validate(source: temporaryURL, spec: spec)
            try commitVerified(source: temporaryURL, destination: destination, spec: spec,
                               generation: generation, operationID: operationID)
            notifyState(.done(destination), generation: generation, operationID: operationID)
            finish(generation: generation, operationID: operationID)
        } catch is CancellationError {
            guard isCurrent(generation) else { return }
            notifyState(.failed(ErrorType.cancelled), generation: generation, operationID: operationID)
            finish(generation: generation, operationID: operationID)
        } catch {
            guard isCurrent(generation) else { return }
            notifyState(.failed(map(error)), generation: generation, operationID: operationID)
            finish(generation: generation, operationID: operationID)
        }
    }

    private func map(_ error: Error) -> ErrorType {
        guard let bounded = error as? BoundedModelDownloadError else {
            return (error as? ErrorType) ?? .network(error)
        }
        switch bounded {
        case .insufficientSpace: return .noSpace
        case .unexpectedStatus(let status): return .httpStatus(status)
        case .cancelled, .superseded: return .cancelled
        case .invalidIdentity, .duplicateOperationID, .unexpectedContentLength, .downloadTooLarge, .checksumMismatch, .incomplete, .invalidResumeState, .metadataTooLarge:
            return .badChecksum
        case .invalidMirror, .invalidContentEncoding, .invalidContentRange, .rangeNotHonored, .rangeNotSatisfiable:
            return .network(bounded)
        case .interrupted: return .network(bounded)
        case .transport: return .network(bounded)
        }
    }

    private func requireCurrent(_ generation: Int) throws {
        guard isCurrent(generation), !Task.isCancelled else { throw ErrorType.cancelled }
    }

    private func isCurrent(_ generation: Int) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return self.generation == generation
    }

    private func isCurrent(generation: Int, operationID: UUID) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return self.generation == generation && self.operationID == operationID
    }

    private func claimReplacingCurrent(with operationID: UUID) -> (Int, Task<Void, Never>?, UUID?) {
        stateLock.lock(); defer { stateLock.unlock() }
        generation += 1
        let previous = (generation, operation, self.operationID)
        operation = nil
        self.operationID = operationID
        return previous
    }

    private func finish(generation: Int, operationID: UUID) {
        stateLock.lock(); defer { stateLock.unlock() }
        guard self.generation == generation, self.operationID == operationID else { return }
        operation = nil
        self.operationID = nil
    }

    private func finishSynchronously(generation: Int, operationID: UUID) {
        // Synchronous validation/cache hits never create a Task, but they still
        // claim the same operation slot as asynchronous downloads. Clear that
        // slot before returning so a later cancel cannot emit a second terminal
        // state for the completed generation.
        stateLock.lock(); defer { stateLock.unlock() }
        guard self.generation == generation, self.operationID == operationID else { return }
        operation = nil
        self.operationID = nil
    }

    private func notifyState(_ state: State, generation: Int, operationID: UUID) {
        Task { @MainActor [weak self] in
            guard let self, self.isCurrent(generation) else { return }
            self.onOperationState?(operationID, state)
            self.onState?(state)
        }
    }

    private func commitVerified(source: URL, destination: URL, spec: ModelSpec,
                                generation: Int, operationID: UUID) throws {
        ModelIntegrityVerifier.runTestBeforeCommitHook(for: spec)
        commitLock.lock()
        stateLock.lock()
        defer {
            stateLock.unlock()
            commitLock.unlock()
        }
        let accepted = self.generation == generation && self.operationID == operationID && !Task.isCancelled
        ModelIntegrityVerifier.runTestCommitDecisionHook(for: spec, accepted: accepted)
        guard accepted else { throw ErrorType.cancelled }
        try ModelIntegrityVerifier.commitVerified(source: source, destination: destination, spec: spec)
    }

    private func removeLegacyResumeState(for spec: ModelSpec) {
        guard isSafeFilename(spec.id) else { return }
        for suffix in [".resume", ".resume.json"] {
            let url = downloadsRoot.appendingPathComponent(spec.id + suffix)
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func isDirectChildFilename(_ value: String) -> Bool {
        guard !value.isEmpty, value != ".", value != "..", !value.contains("/"), !value.utf8.contains(0) else { return false }
        let destination = modelRoot.appendingPathComponent(value)
        return destination.lastPathComponent == value
            && destination.deletingLastPathComponent().standardizedFileURL == modelRoot.standardizedFileURL
    }

    private func isSafeFilename(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.utf8.contains(0)
    }

    private static var environmentToken: String? {
        ProcessInfo.processInfo.environment["HF_TOKEN"]
            ?? ProcessInfo.processInfo.environment["HUGGING_FACE_HUB_TOKEN"]
            ?? ProcessInfo.processInfo.environment["HUGGINGFACEHUB_API_TOKEN"]
    }

    static func request(for url: URL, token: String? = ProcessInfo.processInfo.environment["HF_TOKEN"]
                        ?? ProcessInfo.processInfo.environment["HUGGING_FACE_HUB_TOKEN"]
                        ?? ProcessInfo.processInfo.environment["HUGGINGFACEHUB_API_TOKEN"]) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("MacTalk/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "huggingface.co",
              url.port == nil || url.port == 443 else { return request }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }
}
