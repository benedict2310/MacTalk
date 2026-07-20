//
//  ParakeetModelDownloader.swift
//  MacTalk
//
//  Immutable, manifest-driven Hugging Face downloader for the compiled Parakeet v3 layout.
//

import Foundation
import FluidAudio
import Darwin

struct ParakeetManifestEntry: Codable, Hashable, Sendable {
    let path: String
    let size: Int64
    let sha256: String
}

private final class ParakeetStateLock: @unchecked Sendable {
    private let mutex = NSLock()
    func lock() { mutex.lock() }
    func unlock() { mutex.unlock() }
}

private final class ParakeetTaskStartGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var cancelled = false
    private var waiter: CheckedContinuation<Void, Error>?

    func wait() async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if cancelled || Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else if opened {
                    lock.unlock()
                    continuation.resume()
                } else {
                    waiter = continuation
                    lock.unlock()
                }
            }
        }, onCancel: { [self] in
            cancel()
        })
    }

    func open() {
        lock.lock()
        guard !opened, !cancelled else {
            lock.unlock()
            return
        }
        opened = true
        let waiter = self.waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume()
    }

    func cancel() {
        lock.lock()
        guard !opened, !cancelled else {
            lock.unlock()
            return
        }
        cancelled = true
        let waiter = self.waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume(throwing: CancellationError())
    }
}

final class ParakeetModelDownloader: @unchecked Sendable {
    static let repository = GeneratedModelProvenance.parakeetRepository
    static let revision = GeneratedModelProvenance.parakeetRevision
    static let fluidAudioRevision = GeneratedModelProvenance.fluidAudioRevision
    static let modelID = "parakeet-tdt-0.6b-v3"
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
        case httpStatus(Int)
        case unexpectedContentLength(Int64)
        case downloadTooLarge
        case insufficientSpace
        case downloadFailed(String)
        case corruptFile(String)
        case modelMissing(String)
        case invalidManifest
        case aggregateOverflow
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
            case .httpStatus(let status): return "Model download failed (HTTP \(status))."
            case .unexpectedContentLength(let length): return "Model download had an unexpected content length (\(length))."
            case .downloadTooLarge: return "Model download exceeded its exact bounded size."
            case .insufficientSpace: return "Not enough free disk space for the model download."
            case .downloadFailed(let path): return "Failed to download model file: \(path)"
            case .corruptFile(let path): return "Parakeet model file failed integrity verification: \(path)"
            case .modelMissing(let path): return "Required model file missing: \(path)"
            case .invalidManifest: return "Parakeet model manifest is invalid."
            case .aggregateOverflow: return "Parakeet model manifest byte total overflowed."
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
    static let folderName = Repo.parakeetV3.folderName

    private let root: URL
    private let downloadsRoot: URL
    private let entries: [ParakeetManifestEntry]
    private let transport: any BoundedModelDownloading
    private let storeLock: ParakeetStoreFileLock
    private let activationHook: (@Sendable () async -> Void)?
    private let beforeTaskRegistration: (@Sendable () -> Void)?
    private let beforeStoreLockAcquire: (@Sendable () -> Void)?
    private let stateLock = ParakeetStateLock()
    private let commitLock = ParakeetStateLock()
    private var operation: Task<URL, Error>?
    private var operationID: UUID?
    private var generation = 0
    private var terminalClaimed = false
    private var activationClaimed = false
    private var lastProgress = 0.0

    init(modelsRoot: URL? = nil, repoDirectory: URL? = nil,
         manifest: [ParakeetManifestEntry] = ParakeetModelDownloader.manifest,
         transport: any BoundedModelDownloading = BoundedModelDownloadTransport(),
         activationHook: (@Sendable () async -> Void)? = nil,
         beforeTaskRegistration: (@Sendable () -> Void)? = nil,
         beforeStoreLockAcquire: (@Sendable () -> Void)? = nil,
         afterStoreLockContention: (@Sendable () -> Void)? = nil) {
        self.root = modelsRoot ?? Self.modelsDirectory
        self.repoDirectory = repoDirectory ?? self.root.appendingPathComponent(Self.folderName, isDirectory: true)
        self.downloadsRoot = self.root.appendingPathComponent(".downloads", isDirectory: true)
        self.entries = manifest
        self.transport = transport
        self.storeLock = ParakeetStoreFileLock(storeParent: self.root, afterParentValidation: nil,
                                               afterContention: afterStoreLockContention)
        self.activationHook = activationHook
        self.beforeTaskRegistration = beforeTaskRegistration
        self.beforeStoreLockAcquire = beforeStoreLockAcquire
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: self.downloadsRoot, withIntermediateDirectories: true)
        // Construction-time recovery is exclusive. If another process owns the
        // store, that owner must finish before a later availability check retries.
        if let lease = try? storeLock.tryAcquire(.exclusive) {
            recoverInterruptedActivation()
            lease.release()
        }
    }

    static var modelsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MacTalk/Parakeet", isDirectory: true)
    }

    static var repoDirectory: URL { modelsDirectory.appendingPathComponent(folderName, isDirectory: true) }

    func modelsAvailable() -> Bool {
        guard FileManager.default.fileExists(atPath: root.path) else { return false }
        let lock = ParakeetStoreFileLock(storeParent: root)
        guard let lease = try? lock.tryAcquire(.shared) else { return false }
        defer { lease.release() }
        return (try? Self.validateActiveSet(at: repoDirectory, entries: entries)) != nil
    }

    static func modelsAvailable(at root: URL = modelsDirectory) -> Bool {
        guard FileManager.default.fileExists(atPath: root.path) else { return false }
        let lock = ParakeetStoreFileLock(storeParent: root)
        guard let lease = try? lock.tryAcquire(.shared) else { return false }
        defer { lease.release() }
        let directory = root.appendingPathComponent(folderName, isDirectory: true)
        return (try? validateActiveSet(at: directory, entries: manifest)) != nil
    }

    /// Returns a shared lease after validating the complete active compiled
    /// generation. Callers hold it through the path-based native load.
    func acquireValidatedSharedLease() async throws -> ParakeetStoreFileLock.Lease {
        let lease = try await storeLock.acquire(.shared)
        do {
            try Self.validateActiveSet(at: repoDirectory, entries: entries)
            return lease
        } catch {
            lease.release()
            throw error
        }
    }

    /// Executes a path-based compiled load while the complete active tree is
    /// protected by one validated shared store lease. The closure is the only
    /// narrow seam needed by Bootstrap and hermetic ownership tests.
    func withValidatedSharedLease<T>(_ body: (URL) async throws -> T) async throws -> T {
        let lease = try await acquireValidatedSharedLease()
        defer { lease.release() }
        return try await body(repoDirectory)
    }

    @discardableResult
    func downloadIfNeeded() async throws -> URL {
        try Self.validateManifest(entries)
        let operationID = UUID()
        let (currentGeneration, previous, previousID) = claimNewOperation(operationID)
        previous?.cancel()
        if let previousID { transport.cancel(operationID: previousID) }
        let startGate = ParakeetTaskStartGate()
        let task = Task { [weak self] () throws -> URL in
            guard let self else { throw ErrorType.cancelled }
            do {
                try await startGate.wait()
                try Task.checkCancellation()
                try self.check(currentGeneration, operationID)
                return try await self.performDownload(generation: currentGeneration, operationID: operationID)
            } catch is CancellationError {
                throw ErrorType.cancelled
            }
        }
        // This seam deliberately runs after child creation but before
        // registration, outside both ownership and state locks.
        beforeTaskRegistration?()
        let registered: Bool
        stateLock.lock()
        if generation == currentGeneration && self.operationID == operationID {
            operation = task
            registered = true
        } else {
            registered = false
        }
        stateLock.unlock()
        if registered {
            startGate.open()
        } else {
            task.cancel()
            startGate.open()
        }
        do {
            return try await task.value
        } catch {
            throw error
        }
    }

    func cancel() {
        commitLock.lock()
        stateLock.lock()
        guard let currentID = operationID, !terminalClaimed else {
            stateLock.unlock()
            commitLock.unlock()
            return
        }
        let task = operation
        generation += 1
        let cancelledGeneration = generation
        operation = nil
        operationID = nil
        terminalClaimed = true
        stateLock.unlock()
        commitLock.unlock()
        // Cancellation is intentionally outside both ownership and state
        // locks; transports may perform arbitrary I/O or callbacks.
        task?.cancel()
        transport.cancel(operationID: currentID)
        publish(.failed(ErrorType.cancelled), generation: cancelledGeneration)
    }

    private func claimNewOperation(_ id: UUID) -> (Int, Task<URL, Error>?, UUID?) {
        commitLock.lock()
        stateLock.lock()
        generation += 1
        let current = generation
        let previous = operation
        let previousID = operationID
        operation = nil
        operationID = id
        terminalClaimed = false
        activationClaimed = false
        lastProgress = 0
        stateLock.unlock()
        commitLock.unlock()
        return (current, previous, previousID)
    }

    private func performDownload(generation: Int, operationID: UUID) async throws -> URL {
        var currentArtifactPath: String?
        do {
            beforeStoreLockAcquire?()
            let lease = try await storeLock.acquire(.exclusive)
            defer { lease.release() }
            try check(generation, operationID)
            cleanupStaleArtifacts()
            recoverInterruptedActivation()
            if Self.modelsAvailableUnderExclusiveLock(at: root, entries: entries) {
                guard claimDone(generation: generation, operationID: operationID) else { throw ErrorType.cancelled }
                return repoDirectory
            }
            let staging = root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            var activated = false
            defer { if !activated { try? FileManager.default.removeItem(at: staging) } }
            publish(.running(progress: 0, fileIndex: 0, fileCount: entries.count, currentFile: nil), generation: generation)
            let total = try Self.remainingBytes(from: 0, entries: entries)
            var completed: Int64 = 0

            for (index, entry) in entries.enumerated() {
                currentArtifactPath = entry.path
                try check(generation, operationID)
                let target = try safeURL(entry.path, under: staging)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                let identity = try Self.downloadIdentity(for: entry)
                let remaining = try Self.remainingBytes(from: index, entries: entries)
                let completedBefore = completed
                let request = BoundedModelDownloadRequest(
                    identity: identity,
                    mirrors: [try Self.mirrorURL(for: entry)],
                    operationID: operationID,
                    workspaceRoot: downloadsRoot,
                    aggregateDiskBytesStillRequired: remaining,
                    credentialToken: environmentToken,
                    progress: { [weak self] received, fileTotal in
                        guard let self, fileTotal > 0 else { return }
                        let aggregate = min(total, completedBefore + max(0, received))
                        self.publishProgress(aggregate: aggregate, total: total, index: index, path: entry.path, generation: generation)
                    })
                let source = try await transport.download(request)
                defer { try? FileManager.default.removeItem(at: source) }
                try check(generation, operationID)
                try verify(source: source, entry: entry)
                try check(generation, operationID)
                try FileManager.default.moveItem(at: source, to: target)
                completed = try Self.checkedAdd(completed, entry.size)
                publishProgress(aggregate: completed, total: total, index: index + 1, path: entry.path, generation: generation)
            }

            try check(generation, operationID)
            publish(.verifying, generation: generation)
            try writeManifest(nextTo: staging)
            try validateSet(at: staging)
            // Arbitrary hooks stay outside the state lock. The short claim
            // below is the linearization point that owns every activation
            // rename and its rollback against supersession/cancellation.
            if let activationHook { await activationHook() }
            try check(generation, operationID)
            try commitActivation(staging: staging, generation: generation, operationID: operationID, artifactPath: currentArtifactPath)
            activated = true
            return repoDirectory
        } catch is CancellationError {
            let mapped = ErrorType.cancelled
            if claimFailure(mapped, generation: generation, operationID: operationID) {
                throw mapped
            }
            throw ErrorType.cancelled
        } catch let error as ActivationCommitError {
            switch error {
            case .failed(let underlying): throw underlying
            case .cancelled: throw ErrorType.cancelled
            }
        } catch {
            let mapped = map(error, artifactPath: currentArtifactPath)
            if claimFailure(mapped, generation: generation, operationID: operationID) {
                throw mapped
            }
            throw ErrorType.cancelled
        }
    }

    private func check(_ expectedGeneration: Int, _ expectedID: UUID) throws {
        guard !Task.isCancelled else { throw ErrorType.cancelled }
        stateLock.lock(); defer { stateLock.unlock() }
        guard generation == expectedGeneration, operationID == expectedID, !terminalClaimed else { throw ErrorType.cancelled }
    }

    private enum ActivationCommitError: Error {
        case failed(Error)
        case cancelled
    }

    /// Synchronous activation commit. The commit lock covers only the state
    /// claim and filesystem renames; no await, callback, or observer executes
    /// while either lock is held. Terminal ownership is provisional until the
    /// exact success/failure claim below.
    private func commitActivation(staging: URL, generation: Int, operationID: UUID, artifactPath: String?) throws {
        commitLock.lock()
        do {
            try claimActivationLocked(generation: generation, operationID: operationID)
            try activate(staging: staging)
            guard claimDoneLocked(generation: generation, operationID: operationID) else {
                throw ErrorType.cancelled
            }
            commitLock.unlock()
            publish(.done(repoDirectory), generation: generation)
        } catch {
            let mapped = map(error, artifactPath: artifactPath)
            let claimed = claimFailureLocked(mapped, generation: generation, operationID: operationID)
            commitLock.unlock()
            guard claimed else { throw ActivationCommitError.cancelled }
            publish(.failed(mapped), generation: generation)
            throw ActivationCommitError.failed(mapped)
        }
    }

    // Caller holds commitLock. This is the terminal activation linearization
    // point and remains held through every destination rename and rollback.
    private func claimActivationLocked(generation: Int, operationID: UUID) throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard self.generation == generation, self.operationID == operationID, !terminalClaimed else {
            throw ErrorType.cancelled
        }
        activationClaimed = true
        terminalClaimed = true
    }

    private func claimDone(generation: Int, operationID: UUID) -> Bool {
        commitLock.lock()
        let claimed = claimDoneLocked(generation: generation, operationID: operationID)
        commitLock.unlock()
        if claimed { publish(.done(repoDirectory), generation: generation) }
        return claimed
    }

    // Caller holds commitLock. Success owns the terminal before releasing it.
    private func claimDoneLocked(generation: Int, operationID: UUID) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard self.generation == generation, self.operationID == operationID,
              (!terminalClaimed || activationClaimed) else {
            return false
        }
        operation = nil
        self.operationID = nil
        return true
    }

    private func claimFailure(_ error: Error, generation: Int, operationID: UUID) -> Bool {
        commitLock.lock()
        let claimed = claimFailureLocked(error, generation: generation, operationID: operationID)
        commitLock.unlock()
        if claimed { publish(.failed(error), generation: generation) }
        return claimed
    }

    // Caller holds commitLock. A provisional activation owner may convert its
    // terminal claim into the one exact failure terminal.
    private func claimFailureLocked(_ error: Error, generation: Int, operationID: UUID) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard self.generation == generation, self.operationID == operationID,
              (!terminalClaimed || activationClaimed) else {
            return false
        }
        terminalClaimed = true
        operation = nil
        self.operationID = nil
        return true
    }

    private func publishProgress(aggregate: Int64, total: Int64, index: Int, path: String, generation: Int) {
        let progress = total > 0 ? min(1, max(0, Double(aggregate) / Double(total))) : 0
        stateLock.lock()
        guard self.generation == generation, !terminalClaimed else { stateLock.unlock(); return }
        lastProgress = max(lastProgress, progress)
        let value = lastProgress
        stateLock.unlock()
        publish(.running(progress: value, fileIndex: index, fileCount: entries.count, currentFile: path), generation: generation)
    }

    private func publish(_ state: State, generation: Int?) {
        stateLock.lock()
        if let generation, self.generation != generation { stateLock.unlock(); return }
        let callback = onState
        stateLock.unlock()
        Task { @MainActor in
            guard let callback else { return }
            if let generation {
                self.stateLock.lock()
                let current = self.generation == generation && (!self.terminalClaimed || state.isTerminal)
                self.stateLock.unlock()
                guard current else { return }
            }
            callback(state)
        }
    }


    private func map(_ error: Error, artifactPath: String? = nil) -> Error {
        guard let bounded = error as? BoundedModelDownloadError else { return error }
        switch bounded {
        case .cancelled, .superseded: return ErrorType.cancelled
        case .insufficientSpace: return ErrorType.insufficientSpace
        case .unexpectedContentLength(let length): return ErrorType.unexpectedContentLength(length)
        case .downloadTooLarge: return ErrorType.downloadTooLarge
        case .unexpectedStatus(let status):
            if status == 401 || status == 403 { return ErrorType.unauthorized }
            if status == 429 || status == 503 { return ErrorType.rateLimited(status) }
            return ErrorType.httpStatus(status)
        case .invalidIdentity, .duplicateOperationID, .checksumMismatch, .incomplete, .invalidResumeState, .metadataTooLarge:
            return ErrorType.corruptFile(artifactPath ?? "")
        default: return ErrorType.downloadFailed(artifactPath ?? "")
        }
    }

    static func downloadIdentity(for entry: ParakeetManifestEntry) throws -> DownloadArtifactIdentity {
        try validateManifest([entry])
        guard let filename = entry.path.split(separator: "/").last.map(String.init),
              !filename.isEmpty, filename != ".", filename != "..", !filename.contains("/"), !filename.utf8.contains(0) else {
            throw ErrorType.invalidManifest
        }
        return DownloadArtifactIdentity(schemaVersion: 1, provider: "parakeet", modelID: modelID,
                                        sourceRepository: repository, revision: revision,
                                        artifactPath: entry.path, filename: filename,
                                        sha256: entry.sha256, sizeBytes: entry.size)
    }

    static func mirrorURL(for entry: ParakeetManifestEntry) throws -> URL {
        try validateManifest([entry])
        return URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(entry.path)")!
    }

    static func remainingBytes(from index: Int, entries: [ParakeetManifestEntry] = manifest) throws -> Int64 {
        guard index >= 0, index <= entries.count else { throw ErrorType.invalidManifest }
        var total: Int64 = 0
        for entry in entries.dropFirst(index) {
            guard entry.size >= 0 else { throw ErrorType.invalidManifest }
            let result = total.addingReportingOverflow(entry.size)
            guard !result.overflow else { throw ErrorType.aggregateOverflow }
            total = result.partialValue
        }
        return total
    }

    private static func checkedAdd(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow else { throw ErrorType.aggregateOverflow }
        return result.partialValue
    }

    static func validateManifest() throws { try validateManifest(manifest) }
    static func validateManifest(_ entries: [ParakeetManifestEntry]) throws {
        var seen = Set<String>()
        for entry in entries {
            guard seen.insert(entry.path).inserted else { throw ErrorType.duplicatePath(entry.path) }
            try validatePath(entry.path)
            guard entry.size > 0, entry.sha256.count == 64,
                  entry.sha256.allSatisfy({ $0.isNumber || ("a"..."f").contains($0) }) else { throw ErrorType.invalidManifest }
        }
    }

    static func validatePath(_ path: String) throws {
        if path.hasPrefix("/") { throw ErrorType.absolutePath(path) }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if components.contains("..") { throw ErrorType.pathTraversal(path) }
        if components.contains(".") { throw ErrorType.dotPath(path) }
        if components.contains(where: { $0.isEmpty || $0.utf8.contains(0) }) { throw ErrorType.pathTraversal(path) }
    }

    private func safeURL(_ path: String, under root: URL) throws -> URL {
        try Self.validatePath(path)
        let url = root.appendingPathComponent(path)
        let prefix = root.standardizedFileURL.path.hasSuffix("/") ? root.standardizedFileURL.path : root.standardizedFileURL.path + "/"
        guard url.standardizedFileURL.path.hasPrefix(prefix) else { throw ErrorType.pathTraversal(path) }
        return url
    }

    private static func validateActiveSet(at directory: URL, entries: [ParakeetManifestEntry]) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { throw ErrorType.modelMissing(directory.path) }
        guard let raw = try? Data(contentsOf: directory.appendingPathComponent(".mactalk-manifest.json")),
              let identity = try? JSONDecoder().decode(ManifestIdentity.self, from: raw),
              identity.repository == repository, identity.revision == revision, identity.files == entries else {
            throw ErrorType.invalidManifest
        }
        var expected = Set<String>()
        for entry in entries {
            let file = directory.appendingPathComponent(entry.path)
            try validatePath(entry.path)
            expected.insert(entry.path)
            guard isRegularFileAt(file), !isSymlinkAt(file) else { throw ErrorType.symlink(entry.path) }
            try verify(source: file, entry: entry)
        }
        expected.insert(".mactalk-manifest.json")
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { throw ErrorType.invalidManifest }
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

    private static func modelsAvailableUnderExclusiveLock(at root: URL, entries: [ParakeetManifestEntry]) -> Bool { (try? validateActiveSet(at: root.appendingPathComponent(folderName, isDirectory: true), entries: entries)) != nil }
    private func validateSet(at directory: URL) throws { try Self.validateActiveSet(at: directory, entries: entries) }

    private static func verify(source: URL, entry: ParakeetManifestEntry) throws {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: source.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value, size == entry.size,
              let digest = try? SHA256Streamer.hashFile(at: source), digest == entry.sha256 else { throw ErrorType.corruptFile(entry.path) }
    }
    private func verify(source: URL, entry: ParakeetManifestEntry) throws { try Self.verify(source: source, entry: entry) }

    private struct ManifestIdentity: Codable, Equatable { let repository: String; let revision: String; let files: [ParakeetManifestEntry] }
    private let manifestFileName = ".mactalk-manifest.json"
    private func writeManifest(nextTo directory: URL) throws {
        let data = try JSONEncoder().encode(ManifestIdentity(repository: Self.repository, revision: Self.revision, files: entries))
        try data.write(to: directory.appendingPathComponent(manifestFileName), options: .atomic)
    }

    private func activate(staging: URL) throws {
        let manager = FileManager.default
        let backup = root.appendingPathComponent(".backup-\(UUID().uuidString)")
        var movedOld = false
        if manager.fileExists(atPath: repoDirectory.path) { try manager.moveItem(at: repoDirectory, to: backup); movedOld = true }
        do { try manager.moveItem(at: staging, to: repoDirectory) }
        catch {
            if movedOld { try? manager.removeItem(at: repoDirectory); try? manager.moveItem(at: backup, to: repoDirectory) }
            throw error
        }
        if movedOld { try? manager.removeItem(at: backup) }
    }

    private func recoverInterruptedActivation() {
        guard !FileManager.default.fileExists(atPath: repoDirectory.path),
              let items = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        let backups = items.filter { $0.lastPathComponent.hasPrefix(".backup-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for backup in backups {
            do {
                try Self.validateActiveSet(at: backup, entries: entries)
            } catch {
                try? FileManager.default.removeItem(at: backup)
                continue
            }
            do {
                try FileManager.default.moveItem(at: backup, to: repoDirectory)
            } catch {
                // A validated backup remains a recovery option if activation
                // cannot restore it yet.
                continue
            }
            for remaining in backups where remaining != backup {
                try? FileManager.default.removeItem(at: remaining)
            }
            break
        }
    }

    private func cleanupStaleArtifacts() {
        guard let items = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for item in items where item.lastPathComponent.hasPrefix(".staging-") {
            let lease = item.appendingPathComponent(".lease")
            guard let data = try? Data(contentsOf: lease), let text = String(data: data, encoding: .utf8),
                  let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { try? FileManager.default.removeItem(at: item); continue }
            if pid != ProcessInfo.processInfo.processIdentifier && kill(pid, 0) == 0 { continue }
            try? FileManager.default.removeItem(at: item)
        }
        if FileManager.default.fileExists(atPath: repoDirectory.path) {
            for item in items where item.lastPathComponent.hasPrefix(".backup-") { try? FileManager.default.removeItem(at: item) }
        }
    }

    private var environmentToken: String? {
        ProcessInfo.processInfo.environment["HF_TOKEN"] ?? ProcessInfo.processInfo.environment["HUGGING_FACE_HUB_TOKEN"] ?? ProcessInfo.processInfo.environment["HUGGINGFACEHUB_API_TOKEN"]
    }

    private static func isRegularFileAt(_ url: URL) -> Bool { (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true }
    private static func isSymlinkAt(_ url: URL) -> Bool { (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true }
}

private extension ParakeetModelDownloader.State {
    var isTerminal: Bool {
        switch self { case .done, .failed: return true; default: return false }
    }
}
