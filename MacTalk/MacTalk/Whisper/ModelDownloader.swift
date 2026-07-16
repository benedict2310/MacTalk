import Foundation

/// Downloader for immutable Whisper artifacts. All cache reads pass through the
/// same verifier used after a download; a path existing is never success.
final class ModelDownloader: @unchecked Sendable {
    typealias DownloadTaskFactory = @Sendable (URLRequest) async throws -> (URL, URLResponse)
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

    var onState: (@MainActor (State) -> Void)?

    private let session: URLSession
    private let modelRoot: URL
    private let downloadsRoot: URL
    private let taskFactory: DownloadTaskFactory?
    private var operation: Task<Void, Never>?
    private var generation = 0
    private var cancelledGeneration: Int?

    /// Roots and URLSession are injectable so tests never touch the user's
    /// model directory or the network. URLSession may use a custom URLProtocol.
    init(session: URLSession? = nil, modelRoot: URL? = nil, downloadsRoot: URL? = nil,
         taskFactory: DownloadTaskFactory? = nil) {
        self.modelRoot = modelRoot ?? ModelStore.modelsDir
        self.downloadsRoot = downloadsRoot ?? self.modelRoot.appendingPathComponent(".downloads", isDirectory: true)
        self.taskFactory = taskFactory
        try? FileManager.default.createDirectory(at: self.modelRoot, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: self.downloadsRoot, withIntermediateDirectories: true)
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.allowsExpensiveNetworkAccess = true
            configuration.waitsForConnectivity = true
            configuration.httpMaximumConnectionsPerHost = 2
            self.session = URLSession(configuration: configuration)
        }
    }

    func start(spec: ModelSpec) {
        operation?.cancel()
        generation += 1
        let currentGeneration = generation
        cancelledGeneration = nil

        guard ModelIntegrityVerifier.isValidDigest(spec.sha256), spec.sizeBytes > 0,
              !spec.revision.isEmpty, !spec.source.isEmpty else {
            notifyState(.failed(ErrorType.badChecksum), generation: currentGeneration)
            return
        }
        guard !spec.urls.isEmpty else {
            notifyState(.failed(ErrorType.noURLs), generation: currentGeneration)
            return
        }

        let destination = modelRoot.appendingPathComponent(spec.filename)
        if FileManager.default.fileExists(atPath: destination.path) {
            do {
                try ModelIntegrityVerifier.validate(source: destination, spec: spec)
                notifyState(.done(destination), generation: currentGeneration)
                return
            } catch {
                // Untrusted corrupt cache is removed, then downloaded afresh.
                try? FileManager.default.removeItem(at: destination)
            }
        }

        notifyState(.running(progress: 0), generation: currentGeneration)
        operation = Task { [weak self] in
            await self?.run(spec: spec, destination: destination, generation: currentGeneration)
        }
    }

    func cancel() {
        guard operation != nil else { return }
        generation += 1
        let cancelled = generation
        cancelledGeneration = cancelled
        operation?.cancel()
        operation = nil
        notifyState(.failed(ErrorType.cancelled), generation: cancelled)
    }

    private func run(spec: ModelSpec, destination: URL, generation: Int) async {
        var lastError: Error?
        for (index, url) in spec.urls.enumerated() {
            guard isCurrent(generation), !Task.isCancelled else { return }
            do {
                // Persist the complete identity before starting a transfer. A
                // future resume may only use state matching every field.
                saveResumeState(for: spec, mirrorURL: url)
                let request = authorizedRequest(url: url)
                let temporaryURL: URL
                let response: URLResponse
                if let taskFactory {
                    (temporaryURL, response) = try await taskFactory(request)
                } else {
                    (temporaryURL, response) = try await session.download(for: request)
                }
                guard isCurrent(generation), !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: temporaryURL)
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    throw ErrorType.network(URLError(.badServerResponse))
                }
                guard (200..<300).contains(http.statusCode) else {
                    throw ErrorType.httpStatus(http.statusCode)
                }

                notifyState(.verifying, generation: generation)
                try ModelIntegrityVerifier.verifyAndMove(source: temporaryURL, destination: destination, spec: spec)
                clearResumeState(for: spec)
                notifyState(.done(destination), generation: generation)
                operation = nil
                return
            } catch {
                lastError = error
                guard isCurrent(generation), !Task.isCancelled else { return }
                // Mirror fallback is only allowed while this generation is live.
                if index + 1 < spec.urls.count {
                    clearResumeState(for: spec)
                    continue
                }
            }
        }
        guard isCurrent(generation) else { return }
        let finalError: ErrorType
        if let lastError {
            finalError = (lastError as? ErrorType) ?? .network(lastError)
        } else {
            finalError = .noURLs
        }
        notifyState(.failed(finalError), generation: generation)
        operation = nil
    }

    private func isCurrent(_ generation: Int) -> Bool {
        self.generation == generation && cancelledGeneration != generation
    }

    private func notifyState(_ state: State, generation: Int) {
        Task { @MainActor [weak self] in
            guard let self, self.generation == generation else { return }
            self.onState?(state)
        }
    }

    private struct ResumeMetadata: Codable {
        let id: String
        let revision: String
        let digest: String
        let size: Int64
        let mirrorURL: String
    }

    /// Resume identity is all artifact identity, not merely a filename or URL.
    private func clearResumeState(for spec: ModelSpec) {
        try? FileManager.default.removeItem(at: resumeURL(for: spec))
        try? FileManager.default.removeItem(at: metadataURL(for: spec))
    }

    private func resumeURL(for spec: ModelSpec) -> URL {
        downloadsRoot.appendingPathComponent("\(spec.id).resume")
    }

    private func metadataURL(for spec: ModelSpec) -> URL {
        downloadsRoot.appendingPathComponent("\(spec.id).resume.json")
    }

    private func saveResumeState(for spec: ModelSpec, mirrorURL: URL) {
        let metadata = ResumeMetadata(id: spec.id, revision: spec.revision, digest: spec.sha256,
                                      size: spec.sizeBytes, mirrorURL: mirrorURL.absoluteString)
        guard let data = try? JSONEncoder().encode(metadata) else { return }
        let url = metadataURL(for: spec)
        let temporary = url.appendingPathExtension("tmp-\(UUID().uuidString)")
        do {
            try data.write(to: temporary, options: .atomic)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            try FileManager.default.moveItem(at: temporary, to: url)
        } catch { try? FileManager.default.removeItem(at: temporary) }
    }

    private func authorizedRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("MacTalk/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        if let token = ProcessInfo.processInfo.environment["HF_TOKEN"]
            ?? ProcessInfo.processInfo.environment["HUGGING_FACE_HUB_TOKEN"]
            ?? ProcessInfo.processInfo.environment["HUGGINGFACEHUB_API_TOKEN"] {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }
}
