//
//  ParakeetModelDownloader.swift
//  MacTalk
//
//  Immutable, manifest-driven Hugging Face downloader for Parakeet v3.
//

import Foundation
import FluidAudio
import Darwin

private actor ParakeetStoreCoordinator {
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !held {
            held = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume()
        } else {
            held = false
        }
    }
}

private enum ParakeetStoreCoordinators {
    static let lock = NSLock()
    nonisolated(unsafe) static var values: [String: ParakeetStoreCoordinator] = [:]

    static func coordinator(for root: URL) -> ParakeetStoreCoordinator {
        let key = root.standardizedFileURL.path
        lock.lock(); defer { lock.unlock() }
        if let value = values[key] { return value }
        let value = ParakeetStoreCoordinator()
        values[key] = value
        return value
    }
}

struct ParakeetManifestEntry: Codable, Hashable, Sendable {
    let path: String
    let size: Int64
    let sha256: String
}

final class ParakeetModelDownloader: @unchecked Sendable {
    typealias DownloadTaskFactory = @Sendable (URLRequest) async throws -> (URL, URLResponse)
    static let repository = GeneratedModelProvenance.parakeetRepository
    static let revision = GeneratedModelProvenance.parakeetRevision
    static let fluidAudioRevision = GeneratedModelProvenance.fluidAudioRevision

    /// Compiled entries remain the active manifest for this behavior-preserving
    /// commit. Generated source entries are intentionally inactive until the
    /// verified in-memory loader migration lands.
    static let manifest: [ParakeetManifestEntry] = GeneratedModelProvenance.parakeetCompiled.map {
        ParakeetManifestEntry(path: $0.path, size: $0.size, sha256: $0.sha256)
    }

    enum State: Equatable, Sendable {
        case idle
        case running(progress: Double, fileIndex: Int, fileCount: Int, currentFile: String?)
        case verifying
        case done(URL)
        case failed(Error)
        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.verifying, .verifying): return true
            case let (.running(a,b,c,d), .running(e,f,g,h)): return a == e && b == f && c == g && d == h
            case let (.done(a), .done(b)): return a == b
            case let (.failed(a), .failed(b)): return a.localizedDescription == b.localizedDescription
            default: return false
            }
        }
    }

    enum ErrorType: LocalizedError, Sendable {
        case invalidResponse
        case cancelled
        case rateLimited(Int)
        case unauthorized
        case downloadFailed(String)
        case corruptFile(String)
        case modelMissing(String)
        case invalidManifest
        case pathTraversal(String)
        case absolutePath(String)
        case dotPath(String)
        case symlink(String)
        case unexpectedFile(String)
        case duplicatePath(String)

        var errorDescription: String? {
            switch self {
            case .invalidResponse: return "Invalid response from model registry."
            case .cancelled: return "Model download was cancelled."
            case .rateLimited(let status): return "Model download was rate limited (HTTP \(status))."
            case .unauthorized: return "Model download authorization failed."
            case .downloadFailed(let path): return "Failed to download model file: \(path)"
            case .corruptFile(let path): return "Parakeet model file failed integrity verification: \(path)"
            case .modelMissing(let path): return "Required model file missing: \(path)"
            case .invalidManifest: return "Parakeet model manifest is invalid."
            case .pathTraversal(let path): return "Unsafe model path: \(path)"
            case .absolutePath(let path): return "Absolute model path is not allowed: \(path)"
            case .dotPath(let path): return "Dot path is not allowed: \(path)"
            case .symlink(let path): return "Symlink model path is not allowed: \(path)"
            case .unexpectedFile(let path): return "Unexpected model file: \(path)"
            case .duplicatePath(let path): return "Duplicate model path: \(path)"
            }
        }
    }

    var onState: (@MainActor (State) -> Void)?
    let repoDirectory: URL
    /// Must stay in lockstep with FluidAudio's Repo.parakeetV3.folderName.
    static let folderName = Repo.parakeetV3.folderName
    private let session: URLSession
    private let taskFactory: DownloadTaskFactory?
    private let root: URL
    private var operation: Task<URL, Error>?
    private var generation = 0

    init(session: URLSession = .shared, modelsRoot: URL? = nil, repoDirectory: URL? = nil,
         taskFactory: DownloadTaskFactory? = nil) {
        self.session = session
        self.taskFactory = taskFactory
        self.root = modelsRoot ?? Self.modelsDirectory
        self.repoDirectory = repoDirectory ?? self.root.appendingPathComponent(Self.folderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        // Initializers are also used by menu availability checks. They may
        // recover an interrupted activation, but must never remove another
        // instance's live staging tree.
        recoverInterruptedActivation()
    }

    static var modelsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MacTalk/Parakeet", isDirectory: true)
    }

    static var repoDirectory: URL { modelsDirectory.appendingPathComponent(folderName, isDirectory: true) }

    func modelsAvailable() -> Bool {
        Self.modelsAvailable(at: root)
    }

    /// Side-effect-free availability for status/menu paths. Do not construct a
    /// downloader merely to answer whether a verified cache exists.
    static func modelsAvailable(at root: URL = modelsDirectory) -> Bool {
        let directory = root.appendingPathComponent(folderName, isDirectory: true)
        guard let raw = try? Data(contentsOf: directory.appendingPathComponent(".mactalk-manifest.json")),
              let identity = try? JSONDecoder().decode(ManifestIdentity.self, from: raw),
              identity.repository == repository, identity.revision == revision,
              identity.files == manifest else { return false }
        do {
            try validateSet(at: directory)
            return true
        } catch { return false }
    }

    @discardableResult
    func downloadIfNeeded() async throws -> URL {
        try Self.validateManifest()
        if modelsAvailable() {
            notifyState(.done(repoDirectory))
            return repoDirectory
        }
        operation?.cancel()
        generation += 1
        let currentGeneration = generation
        let task = Task { [weak self] () throws -> URL in
            guard let self else { throw ErrorType.cancelled }
            return try await self.performDownload(generation: currentGeneration)
        }
        operation = task
        defer { if self.generation == currentGeneration { self.operation = nil } }
        return try await task.value
    }

    func cancel() {
        generation += 1
        operation?.cancel()
        operation = nil
        notifyState(.failed(ErrorType.cancelled))
    }

    private func performDownload(generation: Int) async throws -> URL {
        let coordinator = ParakeetStoreCoordinators.coordinator(for: root)
        await coordinator.acquire()
        do {
            // The lock makes this cleanup safe: no live in-process staging tree
            // can be mistaken for stale work. It also lets a later process
            // reclaim abandoned trees left by a crash.
            cleanupStaleArtifacts()
            if modelsAvailable() {
                notifyState(.done(repoDirectory))
                await coordinator.release()
                return repoDirectory
            }
            let staging = root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let lease = staging.appendingPathComponent(".lease")
            try Data(ProcessInfo.processInfo.processIdentifier.description.utf8).write(to: lease, options: .atomic)
            var activated = false
            defer { if !activated { try? FileManager.default.removeItem(at: staging) } }
            defer { try? FileManager.default.removeItem(at: lease) }
            do {
            notifyState(.running(progress: 0, fileIndex: 0, fileCount: Self.manifest.count, currentFile: nil))
            for (index, entry) in Self.manifest.enumerated() {
                try check(generation)
                let target = try safeURL(entry.path, under: staging)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                let url = URL(string: "https://huggingface.co/\(Self.repository)/resolve/\(Self.revision)/\(entry.path)")!
                let request = authorizedRequest(url: url)
                let (temporary, response): (URL, URLResponse)
                if let taskFactory {
                    (temporary, response) = try await taskFactory(request)
                } else {
                    (temporary, response) = try await session.download(for: request)
                }
                // The temporary URL is owned by this downloader immediately;
                // cleanup must cover cancellation and response validation too.
                defer { try? FileManager.default.removeItem(at: temporary) }
                try check(generation)
                guard let http = response as? HTTPURLResponse else { throw ErrorType.invalidResponse }
                switch http.statusCode {
                case 401, 403: throw ErrorType.unauthorized
                case 429, 503: throw ErrorType.rateLimited(http.statusCode)
                case 200..<300: break
                default: throw ErrorType.downloadFailed(entry.path)
                }
                try verify(source: temporary, entry: entry)
                try check(generation)
                try FileManager.default.moveItem(at: temporary, to: target)
                notifyState(.running(progress: Double(index + 1) / Double(Self.manifest.count), fileIndex: index + 1, fileCount: Self.manifest.count, currentFile: entry.path))
            }
            try check(generation)
            notifyState(.verifying)
            try FileManager.default.removeItem(at: lease)
            try validateSet(at: staging)
            try writeManifest(nextTo: staging)
            try check(generation)
            try activate(staging: staging)
            activated = true
            notifyState(.done(repoDirectory))
            await coordinator.release()
            return repoDirectory
            } catch {
                let wasCancelled = Task.isCancelled || self.generation != generation
                let finalError: Error = wasCancelled ? ErrorType.cancelled : error
                // cancel() already emitted the terminal state for an invalidated
                // generation; stale work must not emit a second terminal event.
                if self.generation == generation { notifyState(.failed(finalError)) }
                throw finalError
            }
        } catch {
            // Errors before staging creation still own the coordinator lease.
            await coordinator.release()
            throw error
        }
    }

    private func check(_ expectedGeneration: Int) throws {
        guard !Task.isCancelled, self.generation == expectedGeneration else { throw ErrorType.cancelled }
    }

    /// Validates the fixed manifest itself, including path safety and duplicate rejection.
    static func validateManifest() throws { try validateManifest(manifest) }

    /// Kept internal for hermetic tests of path and duplicate handling.
    static func validateManifest(_ entries: [ParakeetManifestEntry]) throws {
        var seen = Set<String>()
        for entry in entries {
            guard seen.insert(entry.path).inserted else { throw ErrorType.duplicatePath(entry.path) }
            if entry.path.hasPrefix("/") { throw ErrorType.absolutePath(entry.path) }
            let components = entry.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard !components.contains("..") else { throw ErrorType.pathTraversal(entry.path) }
            guard !components.contains(".") else { throw ErrorType.dotPath(entry.path) }
            guard components.allSatisfy({ !$0.isEmpty }) else { throw ErrorType.pathTraversal(entry.path) }
            guard entry.size >= 0, entry.sha256.count == 64,
                  entry.sha256.allSatisfy({ $0.isNumber || ("a"..."f").contains($0) }) else { throw ErrorType.invalidManifest }
        }
    }

    private func validateActive() throws {
        guard Self.modelsAvailable(at: root) else { throw ErrorType.invalidManifest }
    }

    private static func validateSet(at directory: URL) throws {
        var expected = Set<String>()
        for entry in manifest {
            let file = directory.appendingPathComponent(entry.path)
            try validatePath(entry.path)
            expected.insert(entry.path)
            guard isRegularFileAt(file), !isSymlinkAt(file) else { throw ErrorType.symlink(entry.path) }
            try verify(source: file, entry: entry)
        }
        expected.insert(".mactalk-manifest.json")
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: []) else { throw ErrorType.invalidManifest }
        for case let file as URL in enumerator {
            if isSymlinkAt(file) { throw ErrorType.symlink(file.path) }
            let values = try file.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == false {
                let prefix = directory.standardizedFileURL.path + "/"
                let path = String(file.standardizedFileURL.path.dropFirst(prefix.count))
                guard expected.contains(path) else { throw ErrorType.unexpectedFile(path) }
            }
        }
    }

    private func validateSet(at directory: URL) throws { try Self.validateSet(at: directory) }

    private static func verify(source: URL, entry: ParakeetManifestEntry) throws {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: source.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value, size == entry.size,
              let digest = try? SHA256Streamer.hashFile(at: source), digest == entry.sha256 else {
            throw ErrorType.corruptFile(entry.path)
        }
    }

    private func verify(source: URL, entry: ParakeetManifestEntry) throws { try Self.verify(source: source, entry: entry) }

    private struct ManifestIdentity: Codable, Equatable {
        let repository: String
        let revision: String
        let files: [ParakeetManifestEntry]
    }

    private func writeManifest(nextTo directory: URL) throws {
        let data = try JSONEncoder().encode(ManifestIdentity(repository: Self.repository, revision: Self.revision, files: Self.manifest))
        let url = manifestURL(for: directory)
        try data.write(to: url, options: .atomic)
    }

    private let manifestFileName = ".mactalk-manifest.json"

    private func manifestURL(for directory: URL) -> URL { directory.appendingPathComponent(manifestFileName) }

    private func activate(staging: URL) throws {
        let manager = FileManager.default
        let backup = root.appendingPathComponent(".backup-\(UUID().uuidString)")
        var movedOld = false
        if manager.fileExists(atPath: repoDirectory.path) {
            try manager.moveItem(at: repoDirectory, to: backup)
            movedOld = true
        }
        do {
            try manager.moveItem(at: staging, to: repoDirectory)
        } catch {
            // The old tree is the rollback boundary. If an activation race
            // left anything at the active path, remove that failed new tree
            // and restore the previously verified backup.
            if movedOld {
                try? manager.removeItem(at: repoDirectory)
                try? manager.moveItem(at: backup, to: repoDirectory)
            }
            throw error
        }
        // A verified active tree now exists. The backup is no longer needed.
        if movedOld { try? manager.removeItem(at: backup) }
    }

    private func safeURL(_ path: String, under root: URL) throws -> URL {
        try Self.validatePath(path)
        let url = root.appendingPathComponent(path)
        let rootPath = root.standardizedFileURL.path.hasSuffix("/") ? root.standardizedFileURL.path : root.standardizedFileURL.path + "/"
        guard url.standardizedFileURL.path.hasPrefix(rootPath) else { throw ErrorType.pathTraversal(path) }
        return url
    }

    static func validatePath(_ path: String) throws {
        if path.hasPrefix("/") { throw ErrorType.absolutePath(path) }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if components.contains("..") { throw ErrorType.pathTraversal(path) }
        if components.contains(".") { throw ErrorType.dotPath(path) }
        if components.contains(where: { $0.isEmpty }) { throw ErrorType.pathTraversal(path) }
    }

    private static func isRegularFileAt(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]) else { return false }
        return values.isRegularFile == true
    }

    private static func isSymlinkAt(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]) else { return false }
        return values.isSymbolicLink == true
    }

    private func isRegularFile(_ url: URL) -> Bool { Self.isRegularFileAt(url) }
    private func isSymlink(_ url: URL) -> Bool { Self.isSymlinkAt(url) }

    private func relative(_ url: URL, from root: URL) -> String {
        let prefix = root.standardizedFileURL.path + "/"
        return String(url.standardizedFileURL.path.dropFirst(prefix.count))
    }

    private func authorizedRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        guard url.scheme?.lowercased() == "https", url.host == "huggingface.co" else { return request }
        if let token = ProcessInfo.processInfo.environment["HF_TOKEN"]
            ?? ProcessInfo.processInfo.environment["HUGGING_FACE_HUB_TOKEN"]
            ?? ProcessInfo.processInfo.environment["HUGGINGFACEHUB_API_TOKEN"] {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func recoverInterruptedActivation() {
        guard !FileManager.default.fileExists(atPath: repoDirectory.path),
              let items = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        let backups = items.filter { $0.lastPathComponent.hasPrefix(".backup-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for backup in backups {
            do {
                try Self.validateSet(at: backup)
                try FileManager.default.moveItem(at: backup, to: repoDirectory)
                break
            } catch {
                try? FileManager.default.removeItem(at: backup)
            }
        }
    }

    private func cleanupStaleArtifacts() {
        guard let items = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        // This runs only while the per-root coordinator is held. Constructors
        // intentionally do not call it, so availability checks cannot delete a
        // transfer owned by another instance. A live lease from another
        // process is retained; only an owner whose process has disappeared is
        // reclaimable.
        for item in items where item.lastPathComponent.hasPrefix(".staging-") {
            let lease = item.appendingPathComponent(".lease")
            guard let data = try? Data(contentsOf: lease),
                  let text = String(data: data, encoding: .utf8),
                  let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                try? FileManager.default.removeItem(at: item)
                continue
            }
            if pid != ProcessInfo.processInfo.processIdentifier && kill(pid, 0) == 0 {
                continue
            }
            try? FileManager.default.removeItem(at: item)
        }
        // Never discard a backup while the active tree is absent: it is the
        // recovery boundary for a crash between the two activation renames.
        if FileManager.default.fileExists(atPath: repoDirectory.path) {
            for item in items where item.lastPathComponent.hasPrefix(".backup-") {
                try? FileManager.default.removeItem(at: item)
            }
        }
    }

    private func notifyState(_ state: State) {
        Task { @MainActor in self.onState?(state) }
    }
}
