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

    enum FileOperation: Equatable, Sendable {
        case inspect(URL)
        case remove(URL)
        case replace(source: URL, destination: URL)
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
    private let fileOperationObserver: (@Sendable (FileOperation) -> Void)?
    private let beforeTaskRegistration: (@Sendable (UUID) -> Void)?
    private let afterTaskRegistration: (@Sendable (UUID) -> Void)?
    private let beforeCommitHook: (@Sendable (ModelSpec) -> Void)?
    private let commitDecisionHook: (@Sendable (ModelSpec, Bool) -> Void)?
    private var operation: Task<Void, Never>?
    private var generation = 0
    private var operationID: UUID?
    private let stateLock = NSLock()
    private let commitLock = NSLock()

    init(modelRoot: URL? = nil, downloadsRoot: URL? = nil,
         transport: any BoundedModelDownloading = BoundedModelDownloadTransport(),
         fileOperationObserver: (@Sendable (FileOperation) -> Void)? = nil,
         beforeTaskRegistration: (@Sendable (UUID) -> Void)? = nil,
         afterTaskRegistration: (@Sendable (UUID) -> Void)? = nil,
         beforeCommitHook: (@Sendable (ModelSpec) -> Void)? = nil,
         commitDecisionHook: (@Sendable (ModelSpec, Bool) -> Void)? = nil) {
        self.modelRoot = modelRoot ?? ModelStore.modelsDir
        self.downloadsRoot = downloadsRoot ?? self.modelRoot.appendingPathComponent(".downloads", isDirectory: true)
        self.transport = transport
        self.fileOperationObserver = fileOperationObserver
        self.beforeTaskRegistration = beforeTaskRegistration
        self.afterTaskRegistration = afterTaskRegistration
        self.beforeCommitHook = beforeCommitHook
        self.commitDecisionHook = commitDecisionHook
        try? FileManager.default.createDirectory(at: self.modelRoot, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: self.downloadsRoot, withIntermediateDirectories: true)
    }

    func start(spec: ModelSpec, operationID: UUID = UUID()) {
        let (currentGeneration, previousTask, previousID) = claimReplacingCurrent(with: operationID)
        previousTask?.cancel()
        if let previousID { transport.cancel(operationID: previousID) }

        if !isDirectChildFilename(spec.filename) {
            publishTerminal(.failed(ErrorType.invalidFilename), generation: currentGeneration, operationID: operationID)
            return
        }

        removeLegacyResumeState(for: spec, generation: currentGeneration, operationID: operationID)

        guard ModelIntegrityVerifier.isValidDigest(spec.sha256), spec.sizeBytes > 0,
              !spec.revision.isEmpty, !spec.source.isEmpty else {
            publishTerminal(.failed(ErrorType.badChecksum), generation: currentGeneration, operationID: operationID)
            return
        }
        guard !spec.urls.isEmpty else {
            publishTerminal(.failed(ErrorType.noURLs), generation: currentGeneration, operationID: operationID)
            return
        }

        let destination = modelRoot.appendingPathComponent(spec.filename)
        let cacheExists = FileManager.default.fileExists(atPath: destination.path)
        observe(.inspect(destination))
        if cacheExists {
            do {
                try ModelIntegrityVerifier.validate(source: destination, spec: spec)
                publishTerminal(.done(destination), generation: currentGeneration, operationID: operationID)
                return
            } catch {
                commitLock.lock()
                stateLock.lock()
                let ownsCache = self.generation == currentGeneration && self.operationID == operationID
                if ownsCache { try? FileManager.default.removeItem(at: destination) }
                stateLock.unlock()
                commitLock.unlock()
                if ownsCache { observe(.remove(destination)) }
                guard ownsCache else { return }
            }
        }

        notifyState(.running(progress: 0), generation: currentGeneration, operationID: operationID)
        beforeTaskRegistration?(operationID)
        stateLock.lock()
        guard self.generation == currentGeneration, self.operationID == operationID else {
            stateLock.unlock()
            return
        }
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.run(spec: spec, destination: destination, generation: currentGeneration, operationID: operationID)
        }
        operation = task
        stateLock.unlock()
        afterTaskRegistration?(operationID)
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
            beforeCommitHook?(spec)
            switch commitVerified(source: temporaryURL, destination: destination, spec: spec,
                                   generation: generation, operationID: operationID) {
            case .committed:
                notifyState(.done(destination), generation: generation, operationID: operationID)
            case .stale:
                return
            case .failed(let error):
                notifyState(.failed(map(error)), generation: generation, operationID: operationID)
            }
        } catch is CancellationError {
            publishTerminal(.failed(ErrorType.cancelled), generation: generation, operationID: operationID)
        } catch {
            publishTerminal(.failed(map(error)), generation: generation, operationID: operationID)
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

    /// Claims terminal ownership before scheduling its notification. Once this
    /// succeeds, cancellation cannot publish a competing terminal state.
    private func claimTerminal(generation: Int, operationID: UUID) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        guard self.generation == generation, self.operationID == operationID else { return false }
        operation = nil
        self.operationID = nil
        return true
    }

    private func publishTerminal(_ state: State, generation: Int, operationID: UUID) {
        guard claimTerminal(generation: generation, operationID: operationID) else { return }
        notifyState(state, generation: generation, operationID: operationID)
    }

    private func notifyState(_ state: State, generation: Int, operationID: UUID) {
        Task { @MainActor [weak self] in
            guard let self, self.isCurrent(generation) else { return }
            self.onOperationState?(operationID, state)
            self.onState?(state)
        }
    }

    private enum CommitResult {
        case committed
        case stale
        case failed(Error)
    }

    private func commitVerified(source: URL, destination: URL, spec: ModelSpec,
                                generation: Int, operationID: UUID) -> CommitResult {
        commitLock.lock()
        stateLock.lock()
        let accepted = self.generation == generation && self.operationID == operationID && !Task.isCancelled
        var replacementAttempted = false
        let result: CommitResult
        if accepted {
            replacementAttempted = true
            do {
                try ModelIntegrityVerifier.commitVerified(source: source, destination: destination, spec: spec)
                // Successful destination mutation and terminal ownership are one
                // linearization point. Cancellation after this point is a no-op.
                operation = nil
                self.operationID = nil
                result = .committed
            } catch {
                // A failed destination mutation is also terminal. Claim its
                // ownership before releasing the lock so cancellation cannot
                // replace the real I/O failure with .cancelled.
                operation = nil
                self.operationID = nil
                result = .failed(error)
            }
        } else {
            result = .stale
        }
        stateLock.unlock()
        commitLock.unlock()

        // Observational seams deliberately run after both locks. They must be
        // able to coordinate cancellation and replacement without becoming
        // part of the commit critical section.
        if replacementAttempted {
            observe(.replace(source: source, destination: destination))
        }
        commitDecisionHook?(spec, accepted)
        return result
    }

    private func removeLegacyResumeState(for spec: ModelSpec, generation: Int, operationID: UUID) {
        guard isSafeFilename(spec.id) else { return }
        for suffix in [".resume", ".resume.json"] {
            let url = downloadsRoot.appendingPathComponent(spec.id + suffix)
            commitLock.lock()
            stateLock.lock()
            let owns = self.generation == generation && self.operationID == operationID
            if owns { try? FileManager.default.removeItem(at: url) }
            stateLock.unlock()
            commitLock.unlock()
            if owns { observe(.remove(url)) }
            if !owns { return }
        }
    }

    private func observe(_ operation: FileOperation) {
        fileOperationObserver?(operation)
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
