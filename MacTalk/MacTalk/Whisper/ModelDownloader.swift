import Foundation

/// Model downloader handling URLSession delegate callbacks.
/// Marked @unchecked Sendable because NSObject is not Sendable, but we ensure
/// thread safety by dispatching all state callbacks to the main actor.
final class ModelDownloader: NSObject, @unchecked Sendable {
    /// Download state enumeration
    enum State: Equatable, Sendable {
        case idle
        case running(progress: Double)   // 0…1
        case verifying
        case done(URL)
        case failed(Error)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle): return true
            case (.running(let p1), .running(let p2)): return p1 == p2
            case (.verifying, .verifying): return true
            case (.done(let u1), .done(let u2)): return u1 == u2
            case (.failed(let e1), .failed(let e2)): return e1.localizedDescription == e2.localizedDescription
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
        case io(Swift.Error)

        var errorDescription: String? {
            switch self {
            case .noURLs: return "No download URLs are available."
            case .noSpace: return "Not enough free disk space."
            case .cancelled: return "Download was cancelled."
            case .network(let error): return "Network error: \(error.localizedDescription)"
            case .badChecksum: return "Checksum verification failed."
            case .io(let error): return "File error: \(error.localizedDescription)"
            }
        }
    }

    private var session: URLSession!
    private var task: URLSessionDownloadTask?
    private var currentURLIndex = 0
    private var spec: ModelSpec!
    private var resumeURL: URL!
    private var tempFileURL: URL?

    /// State callback - always dispatched to main actor
    var onState: (@MainActor (State) -> Void)?

    /// Helper to notify state changes on main actor
    private func notifyState(_ state: State) {
        Task { @MainActor in
            self.onState?(state)
        }
    }

    override init() {
        super.init()
        let cfg = URLSessionConfiguration.default
        cfg.allowsExpensiveNetworkAccess = true
        cfg.waitsForConnectivity = true
        cfg.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }

    func start(spec: ModelSpec) {
        self.spec = spec
        self.resumeURL = ModelStore.downloadsDir.appendingPathComponent("\(spec.id).resume")

        if ModelStore.exists(spec) {
            notifyState(.done(ModelStore.path(for: spec)))
            return
        }

        if let free = ModelStore.freeSpaceBytes(), free < spec.sizeBytes + 200_000_000 {
            notifyState(.failed(ErrorType.noSpace))
            return
        }

        currentURLIndex = 0
        kick()
    }

    func cancel() {
        task?.cancel()
        notifyState(.failed(ErrorType.cancelled))
    }

    private func kick() {
        guard currentURLIndex < spec.urls.count else {
            notifyState(.failed(ErrorType.noURLs))
            return
        }

        let url = spec.urls[currentURLIndex]

        if let resumeData = try? Data(contentsOf: resumeURL) {
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            var req = URLRequest(url: url)
            req.setValue("MacTalk/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
            task = session.downloadTask(with: req)
        }

        notifyState(.running(progress: 0))
        task?.resume()
    }

    private func tryNextMirror(_ err: Error) {
        currentURLIndex += 1
        if currentURLIndex < spec.urls.count {
            // Clear resume data when switching mirrors since it contains the old URL
            try? FileManager.default.removeItem(at: resumeURL)
            kick()
        } else {
            notifyState(.failed(ErrorType.network(err)))
        }
    }

    private func verifyAndMove(tempURL: URL) {
        notifyState(.verifying)

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }

            do {
                // Optional size sanity-check (very lenient - 10% tolerance or 10MB)
                // This catches obviously wrong files while allowing for approximate sizes
                if self.spec.sizeBytes > 0 {
                    let attr = try FileManager.default.attributesOfItem(atPath: tempURL.path)
                    if let sz = (attr[.size] as? NSNumber)?.int64Value {
                        let tolerance = max(self.spec.sizeBytes / 10, 10_000_000) // 10% or 10MB
                        if abs(sz - self.spec.sizeBytes) > tolerance {
                            throw ErrorType.badChecksum
                        }
                    }
                }

                // SHA-256 verification (skip if checksum not provided)
                if !self.spec.sha256.isEmpty && self.spec.sha256.count == 64 {
                    let hash = try SHA256Streamer.hashFile(at: tempURL)
                    guard hash == self.spec.sha256 else {
                        throw ErrorType.badChecksum
                    }
                }

                // Atomic move into place
                let dest = ModelStore.path(for: self.spec)
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.moveItem(at: tempURL, to: dest)
                try? FileManager.default.removeItem(at: self.resumeURL)

                self.notifyState(.done(dest))
            } catch {
                self.notifyState(.failed(error))
            }
        }
    }
}

extension ModelDownloader: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // Keep file around until verify finishes
        let tmp = ModelStore.downloadsDir.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: tmp)
            self.tempFileURL = tmp
            verifyAndMove(tempURL: tmp)
        } catch {
            notifyState(.failed(ErrorType.io(error)))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let progress = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
        notifyState(.running(progress: progress))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        guard let error else { return } // success path handled in didFinishDownloadingTo

        if let urlError = error as? URLError,
           let resumeData = urlError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            try? resumeData.write(to: resumeURL)
        }

        tryNextMirror(error)
    }
}
