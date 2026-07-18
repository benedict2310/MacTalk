import Foundation

private final class WhisperDownloadDelegate: NSObject, URLSessionDownloadDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let root: URL
    private let lock = NSLock()
    private var continuations: [Int: CheckedContinuation<(URL, URLResponse, Data?), Error>] = [:]
    private var tasks: [Int: URLSessionDownloadTask] = [:]

    init(root: URL) { self.root = root }

    func download(using session: URLSession, request: URLRequest, resumeData: Data?) async throws -> (URL, URLResponse, Data?) {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(URL, URLResponse, Data?), Error>) in
                let task = resumeData.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: request)
                lock.lock(); continuations[task.taskIdentifier] = continuation; tasks[task.taskIdentifier] = task; lock.unlock()
                task.resume()
            }
        }, onCancel: { [weak self] in
            self?.cancelAll()
        })
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let target = root.appendingPathComponent(".resume-result-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: location, to: target)
            lock.lock(); let continuation = continuations.removeValue(forKey: downloadTask.taskIdentifier); tasks.removeValue(forKey: downloadTask.taskIdentifier); lock.unlock()
            if let continuation, let response = downloadTask.response { continuation.resume(returning: (target, response, nil)) }
        } catch {
            lock.lock(); let continuation = continuations.removeValue(forKey: downloadTask.taskIdentifier); tasks.removeValue(forKey: downloadTask.taskIdentifier); lock.unlock()
            continuation?.resume(throwing: error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        lock.lock(); let continuation = continuations.removeValue(forKey: task.taskIdentifier); tasks.removeValue(forKey: task.taskIdentifier); lock.unlock()
        guard let continuation else { return }
        let nsError = error as NSError
        let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData]
        var info = nsError.userInfo
        if let resumeData { info[NSURLSessionDownloadTaskResumeData] = resumeData }
        continuation.resume(throwing: NSError(domain: nsError.domain, code: nsError.code, userInfo: info))
    }

    func cancelAll() {
        lock.lock(); let active = Array(tasks.values); lock.unlock()
        for task in active {
            task.cancel(byProducingResumeData: { [weak self] data in
                guard let self else { return }
                self.lock.lock()
                let continuation = self.continuations.removeValue(forKey: task.taskIdentifier)
                self.tasks.removeValue(forKey: task.taskIdentifier)
                self.lock.unlock()
                guard let continuation else { return }
                var info: [String: Any] = [:]
                if let data { info[NSURLSessionDownloadTaskResumeData] = data }
                continuation.resume(throwing: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled, userInfo: info))
            })
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        var safe = request
        if safe.url?.scheme?.lowercased() != "https" || safe.url?.host != "huggingface.co" {
            safe.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        completionHandler(safe)
    }
}

/// Downloader for immutable Whisper artifacts. All cache reads pass through the
/// same verifier used after a download; a path existing is never success.
final class ModelDownloader: @unchecked Sendable {
    typealias DownloadTaskFactory = @Sendable (URLRequest) async throws -> (URL, URLResponse)
    /// Test and production adapters may provide URLSession's actual resumeData.
    typealias ResumableDownloadTaskFactory = @Sendable (URLRequest, Data?) async throws -> (URL, URLResponse, Data?)
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
        case noSpace
        case cancelled
        case network(Swift.Error)
        case badChecksum
        case httpStatus(Int)
        case io(Swift.Error)

        var errorDescription: String? {
            switch self {
            case .noURLs: return "No download URLs are available."
            case .noSpace: return "Not enough free disk space."
            case .cancelled: return "Download was cancelled."
            case .network(let error): return "Network error: \(error.localizedDescription)"
            case .badChecksum: return "Checksum verification failed."
            case .httpStatus(let status): return "Model download failed (HTTP \(status))."
            case .io(let error): return "File error: \(error.localizedDescription)"
            }
        }
    }

    /// Every state emitted through this callback carries the operation that
    /// produced it. Consumers must not infer ownership from callback order.
    var onOperationState: (@MainActor @Sendable (UUID, State) -> Void)?

    /// Legacy untagged callback retained for direct downloader users. Model
    /// management adapters use `onOperationState` exclusively.
    var onState: (@MainActor (State) -> Void)?

    private let session: URLSession
    private let modelRoot: URL
    private let downloadsRoot: URL
    private let taskFactory: DownloadTaskFactory?
    private let resumableTaskFactory: ResumableDownloadTaskFactory?
    private let delegate: WhisperDownloadDelegate?
    private var operation: Task<Void, Never>?
    private var generation = 0
    private var cancelledGeneration: Int?
    private var operationID: UUID?

    /// Roots and URLSession are injectable so tests never touch the user's
    /// model directory or the network. URLSession may use a custom URLProtocol.
    init(session: URLSession? = nil, modelRoot: URL? = nil, downloadsRoot: URL? = nil,
         taskFactory: DownloadTaskFactory? = nil,
         resumableTaskFactory: ResumableDownloadTaskFactory? = nil) {
        self.modelRoot = modelRoot ?? ModelStore.modelsDir
        self.downloadsRoot = downloadsRoot ?? self.modelRoot.appendingPathComponent(".downloads", isDirectory: true)
        self.taskFactory = taskFactory
        self.resumableTaskFactory = resumableTaskFactory
        try? FileManager.default.createDirectory(at: self.modelRoot, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: self.downloadsRoot, withIntermediateDirectories: true)
        if let session {
            self.session = session
            self.delegate = nil
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.allowsExpensiveNetworkAccess = true
            configuration.waitsForConnectivity = true
            configuration.httpMaximumConnectionsPerHost = 2
            let delegate = WhisperDownloadDelegate(root: self.downloadsRoot)
            self.delegate = delegate
            self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        }
    }

    func start(spec: ModelSpec, operationID: UUID = UUID()) {
        // URLSession's transfer is owned by this downloader, so replacing an
        // operation must cancel it rather than merely suppressing its result.
        operation?.cancel()
        generation += 1
        self.operationID = operationID
        // Invalidate the old generation before URLSession invokes its
        // cancellation continuation, preventing stale resume bytes/state.
        delegate?.cancelAll()
        let currentGeneration = generation
        cancelledGeneration = nil

        guard ModelIntegrityVerifier.isValidDigest(spec.sha256), spec.sizeBytes > 0,
              !spec.revision.isEmpty, !spec.source.isEmpty else {
            notifyState(.failed(ErrorType.badChecksum), generation: currentGeneration, operationID: operationID)
            return
        }
        guard !spec.urls.isEmpty else {
            notifyState(.failed(ErrorType.noURLs), generation: currentGeneration, operationID: operationID)
            return
        }

        let destination = modelRoot.appendingPathComponent(spec.filename)
        if FileManager.default.fileExists(atPath: destination.path) {
            do {
                try ModelIntegrityVerifier.validate(source: destination, spec: spec)
                notifyState(.done(destination), generation: currentGeneration, operationID: operationID)
                return
            } catch {
                // Untrusted corrupt cache is removed, then downloaded afresh.
                try? FileManager.default.removeItem(at: destination)
            }
        }

        notifyState(.running(progress: 0), generation: currentGeneration, operationID: operationID)
        operation = Task { [weak self] in
            await self?.run(spec: spec, destination: destination, generation: currentGeneration, operationID: operationID)
        }
    }

    func cancel() {
        guard let operationID else { return }
        generation += 1
        let cancelled = generation
        delegate?.cancelAll()
        cancelledGeneration = cancelled
        operation?.cancel()
        operation = nil
        self.operationID = nil
        notifyState(.failed(ErrorType.cancelled), generation: cancelled, operationID: operationID)
    }

    private func run(spec: ModelSpec, destination: URL, generation: Int, operationID: UUID) async {
        var lastError: Error?
        for (index, url) in spec.urls.enumerated() {
            guard isCurrent(generation), !Task.isCancelled else { return }

            // Read and validate the old envelope before writing anything. In
            // particular, never pair opaque resume bytes with a newly written
            // identity (the opaque request may still target the old mirror).
            var resumeData = loadResumeData(for: spec, mirrorURL: url)
            var retriedWithoutResume = false
            while true {
                guard isCurrent(generation), !Task.isCancelled else { return }
                do {
                    let request = authorizedRequest(url: url)
                    let temporaryURL: URL
                    let response: URLResponse
                    if let resumableTaskFactory {
                        let result = try await resumableTaskFactory(request, resumeData)
                        temporaryURL = result.0
                        response = result.1
                        if let data = result.2 {
                            saveResumeData(data, for: spec, mirrorURL: url)
                        }
                    } else if let taskFactory {
                        (temporaryURL, response) = try await taskFactory(request)
                    } else if let delegate {
                        let result = try await delegate.download(using: session, request: request, resumeData: resumeData)
                        temporaryURL = result.0
                        response = result.1
                        if let data = result.2 {
                            saveResumeData(data, for: spec, mirrorURL: url)
                        }
                    } else {
                        (temporaryURL, response) = try await session.download(for: request)
                    }

                    // URLSession hands ownership of this temporary file to us.
                    // Install cleanup immediately, before inspecting response or
                    // generation, so every HTTP/invalid/cancel/error path cleans it.
                    defer { try? FileManager.default.removeItem(at: temporaryURL) }
                    guard isCurrent(generation), !Task.isCancelled else { return }
                    guard let http = response as? HTTPURLResponse else {
                        throw ErrorType.network(URLError(.badServerResponse))
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        throw ErrorType.httpStatus(http.statusCode)
                    }

                    notifyState(.verifying, generation: generation, operationID: operationID)
                    try ModelIntegrityVerifier.verifyAndMove(source: temporaryURL, destination: destination, spec: spec)
                    clearResumeState(for: spec)
                    notifyState(.done(destination), generation: generation, operationID: operationID)
                    operation = nil
                    self.operationID = nil
                    return
                } catch {
                    lastError = error
                    if isCurrent(generation), !Task.isCancelled,
                       let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                        saveResumeData(data, for: spec, mirrorURL: url)
                    }
                    guard isCurrent(generation), !Task.isCancelled else { return }

                    // Resume data is opaque and can be malformed, truncated,
                    // or internally bound to a retired request. A failed
                    // resumed transfer gets exactly one clean attempt on this
                    // same mirror before fallback is considered.
                    if resumeData != nil, !retriedWithoutResume {
                        clearResumeState(for: spec)
                        resumeData = nil
                        retriedWithoutResume = true
                        continue
                    }
                    break
                }
            }

            guard isCurrent(generation), !Task.isCancelled else { return }
            if index + 1 < spec.urls.count {
                clearResumeState(for: spec)
                continue
            }
        }
        guard isCurrent(generation) else { return }
        let finalError: ErrorType
        if let lastError {
            finalError = (lastError as? ErrorType) ?? .network(lastError)
        } else {
            finalError = .noURLs
        }
        notifyState(.failed(finalError), generation: generation, operationID: operationID)
        operation = nil
        self.operationID = nil
    }

    private func isCurrent(_ generation: Int) -> Bool {
        self.generation == generation && cancelledGeneration != generation
    }

    private func notifyState(_ state: State, generation: Int, operationID: UUID) {
        Task { @MainActor [weak self] in
            guard let self, self.generation == generation else { return }
            self.onOperationState?(operationID, state)
            self.onState?(state)
        }
    }

    private struct ResumeMetadata: Codable, Equatable {
        let id: String
        let source: String
        let revision: String
        let digest: String
        let size: Int64
        let mirrorURL: String
    }

    /// Metadata and opaque URLSession bytes are one atomic envelope. Keeping
    /// them in separate files permits a crash to pair identity A with bytes B.
    private struct ResumeEnvelope: Codable {
        let metadata: ResumeMetadata
        let resumeData: Data
    }

    /// Resume identity is all artifact identity, not merely a filename or URL.
    private func clearResumeState(for spec: ModelSpec) {
        try? FileManager.default.removeItem(at: resumeURL(for: spec))
        // Remove the pre-envelope sidecar too, so old crash-skewed state can
        // never be interpreted as current resume state.
        try? FileManager.default.removeItem(at: downloadsRoot.appendingPathComponent("\(spec.id).resume.json"))
    }

    private func resumeURL(for spec: ModelSpec) -> URL {
        downloadsRoot.appendingPathComponent("\(spec.id).resume")
    }

    private func saveResumeData(_ data: Data, for spec: ModelSpec, mirrorURL: URL) {
        let metadata = ResumeMetadata(id: spec.id, source: spec.source, revision: spec.revision,
                                      digest: spec.sha256, size: spec.sizeBytes,
                                      mirrorURL: mirrorURL.absoluteString)
        let envelope = ResumeEnvelope(metadata: metadata, resumeData: data)
        guard let encoded = try? JSONEncoder().encode(envelope) else { return }
        // Data.write(.atomic) replaces the single envelope, never exposing a
        // metadata/bytes pair assembled by two independent writes.
        try? encoded.write(to: resumeURL(for: spec), options: .atomic)
    }

    private func loadResumeData(for spec: ModelSpec, mirrorURL: URL) -> Data? {
        guard let raw = try? Data(contentsOf: resumeURL(for: spec)),
              let envelope = try? JSONDecoder().decode(ResumeEnvelope.self, from: raw),
              envelope.metadata.id == spec.id,
              envelope.metadata.source == spec.source,
              envelope.metadata.revision == spec.revision,
              envelope.metadata.digest == spec.sha256,
              envelope.metadata.size == spec.sizeBytes,
              envelope.metadata.mirrorURL == mirrorURL.absoluteString,
              !envelope.resumeData.isEmpty else {
            clearResumeState(for: spec)
            return nil
        }
        return envelope.resumeData
    }

    static func request(for url: URL, token: String? = ProcessInfo.processInfo.environment["HF_TOKEN"]
                        ?? ProcessInfo.processInfo.environment["HUGGING_FACE_HUB_TOKEN"]
                        ?? ProcessInfo.processInfo.environment["HUGGINGFACEHUB_API_TOKEN"]) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("MacTalk/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        guard url.scheme?.lowercased() == "https", url.host == "huggingface.co" else { return request }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    private func authorizedRequest(url: URL) -> URLRequest {
        Self.request(for: url)
    }
}
