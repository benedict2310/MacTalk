import CryptoKit
import Darwin
import Foundation
import os

struct DownloadArtifactIdentity: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let provider: String
    let modelID: String
    let sourceRepository: String
    let revision: String
    let artifactPath: String
    let filename: String
    let sha256: String
    let sizeBytes: Int64

    /// Canonical JSON with sorted keys is hashed for the partial slot name. Length
    /// framing is implicit in JSON and prevents delimiter/control-character
    /// collisions between otherwise distinct identities.
    var canonicalKey: String {
        let object: [String: Any] = [
            "artifactPath": artifactPath,
            "filename": filename,
            "modelID": modelID,
            "provider": provider,
            "revision": revision,
            "schemaVersion": schemaVersion,
            "sha256": sha256,
            "sizeBytes": sizeBytes,
            "sourceRepository": sourceRepository
        ]
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            preconditionFailure("DownloadArtifactIdentity must be JSON encodable")
        }
        return String(decoding: data, as: UTF8.self)
    }
}

struct BoundedModelDownloadRequest: Sendable {
    let identity: DownloadArtifactIdentity
    let mirrors: [URL]
    let operationID: UUID
    let workspaceRoot: URL
    let aggregateDiskBytesStillRequired: Int64
    let credentialToken: String?
    let progress: (@Sendable (Int64, Int64) -> Void)?

    init(identity: DownloadArtifactIdentity, mirrors: [URL], operationID: UUID = UUID(), workspaceRoot: URL,
         aggregateDiskBytesStillRequired: Int64? = nil, credentialToken: String? = nil,
         progress: (@Sendable (Int64, Int64) -> Void)? = nil) {
        self.identity = identity
        self.mirrors = mirrors
        self.operationID = operationID
        self.workspaceRoot = workspaceRoot
        self.aggregateDiskBytesStillRequired = aggregateDiskBytesStillRequired ?? identity.sizeBytes
        self.credentialToken = credentialToken
        self.progress = progress
    }
}

enum BoundedModelDownloadError: Error, Equatable, Sendable {
    case invalidIdentity
    case invalidMirror
    case insufficientSpace(required: Int64, available: Int64)
    case unexpectedStatus(Int)
    case unexpectedContentLength(Int64)
    case invalidContentEncoding
    case invalidContentRange
    case rangeNotHonored
    case rangeNotSatisfiable
    case downloadTooLarge
    case interrupted
    case cancelled
    case superseded
    case checksumMismatch
    case incomplete
    case invalidResumeState
    case transport(String)
}

protocol VolumeCapacityProviding: Sendable {
    func availableCapacity(for url: URL) throws -> Int64
}

struct SystemVolumeCapacityProvider: VolumeCapacityProviding {
    func availableCapacity(for url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values.volumeAvailableCapacityForImportantUsage else { throw BoundedModelDownloadError.transport("volume capacity unavailable") }
        return Int64(available)
    }
}

final class BoundedModelDownloadTransport: NSObject, @unchecked Sendable {
    private let capacity: VolumeCapacityProviding
    fileprivate let allowInsecureLoopback: Bool
    fileprivate let allowTestCredentialsOnLoopback: Bool
    private let sessionFactory: (@Sendable (URLSessionConfiguration, URLSessionDelegate) -> URLSession)?
    private struct State {
        var nextGeneration: UInt64 = 0
        var activeGeneration: UInt64?
        var generationByCaller: [UUID: UInt64] = [:]
        var cancelledCallers: Set<UUID> = []
        var cancelledGenerations: Set<UInt64> = []
        var supersededGenerations: Set<UInt64> = []
        var claimedGenerations: Set<UInt64> = []
        var activeTasks: [UInt64: URLSessionDataTask] = [:]
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(capacity: VolumeCapacityProviding = SystemVolumeCapacityProvider(),
         allowInsecureLoopback: Bool = false,
         allowTestCredentialsOnLoopback: Bool = false,
         sessionFactory: (@Sendable (URLSessionConfiguration, URLSessionDelegate) -> URLSession)? = nil) {
        self.capacity = capacity
        self.allowInsecureLoopback = allowInsecureLoopback
        self.allowTestCredentialsOnLoopback = allowTestCredentialsOnLoopback
        self.sessionFactory = sessionFactory
    }

    func download(_ request: BoundedModelDownloadRequest) async throws -> URL {
        try await withTaskCancellationHandler(operation: {
            try await downloadImpl(request)
        }, onCancel: { [weak self] in
            self?.cancel(operationID: request.operationID)
        })
    }

    private func downloadImpl(_ request: BoundedModelDownloadRequest) async throws -> URL {
        try validate(request)
        let operation = beginOperation(request.operationID)
        defer {
            state.withLock {
                $0.activeTasks[operation] = nil
                if $0.activeGeneration == operation { $0.activeGeneration = nil }
                if $0.generationByCaller[request.operationID] == operation { $0.generationByCaller[request.operationID] = nil }
            }
        }

        let workspace = request.workspaceRoot
        try secureWorkspace(workspace)
        let identityDirectory = try Self.identityDirectoryName(for: request.identity)
        let anchor = try WorkspaceAnchor(root: workspace, slotName: identityDirectory, filename: request.identity.filename)
        let mirrorURLs = request.mirrors
        var lastError: BoundedModelDownloadError?

        for mirror in mirrorURLs {
            try Task.checkCancellation()
            guard isCurrent(operation) else { throw operationError(operation) }
            var resume = try prepareSlot(anchor: anchor, request: request, mirror: mirror, operation: operation)
            var retriedRangeIgnored = false
            do {
                while true {
                    do {
                        try preflight(request, admittedOffset: resume.offset)
                        let result = try await runAttempt(request: request, anchor: anchor, mirror: mirror, offset: resume.offset, validator: resume.validator, operation: operation)
                        try requireCurrent(operation)
                        resume.offset = result
                        guard resume.offset == request.identity.sizeBytes else { throw BoundedModelDownloadError.incomplete }
                        try verifyAndPromote(anchor: anchor, identity: request.identity, operation: operation)
                        return anchor.destinationURL
                    } catch let error as BoundedModelDownloadError
                        where resume.offset > 0 && !retriedRangeIgnored && Self.isResumeRetryable(error) {
                        retriedRangeIgnored = true
                        try clearSlotIfCurrent(anchor: anchor, operation: operation)
                        resume = ResumeState(offset: 0, validator: nil)
                        // A stale or malformed resume response is retried exactly
                        // once without a Range on this same mirror. No bytes from
                        // the rejected response were admitted.
                        continue
                    }
                }
            } catch BoundedModelDownloadError.interrupted {
                throw BoundedModelDownloadError.interrupted
            } catch BoundedModelDownloadError.cancelled {
                try clearSlotIfCurrent(anchor: anchor, operation: operation)
                throw BoundedModelDownloadError.cancelled
            } catch BoundedModelDownloadError.superseded {
                try clearSlotIfCurrent(anchor: anchor, operation: operation)
                throw BoundedModelDownloadError.superseded
            } catch BoundedModelDownloadError.insufficientSpace(let required, let available) {
                throw BoundedModelDownloadError.insufficientSpace(required: required, available: available)
            } catch let error as BoundedModelDownloadError {
                lastError = error
                try clearSlotIfCurrent(anchor: anchor, operation: operation)
                continue
            } catch {
                lastError = .transport(error.localizedDescription)
                try clearSlotIfCurrent(anchor: anchor, operation: operation)
                continue
            }
        }
        throw lastError ?? operationError(operation)
    }

    fileprivate func cancelGeneration(_ generation: UInt64) {
        let task = state.withLock { state -> URLSessionDataTask? in
            state.cancelledGenerations.insert(generation)
            return state.activeTasks[generation]
        }
        task?.cancel()
    }

    func cancel(operationID: UUID) {
        let task: URLSessionDataTask? = state.withLock { state in
            state.cancelledCallers.insert(operationID)
            if let generation = state.generationByCaller[operationID] {
                state.cancelledGenerations.insert(generation)
                return state.activeTasks[generation]
            }
            return nil
        }
        task?.cancel()
    }

    private func runAttempt(request: BoundedModelDownloadRequest, anchor: WorkspaceAnchor, mirror: URL, offset: Int64, validator: String?, operation: UInt64) async throws -> Int64 {
        let delegate = AttemptDelegate(transport: self, request: request, anchor: anchor, mirror: mirror, initialOffset: offset, operation: operation, capacity: capacity)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpAdditionalHeaders = ["Accept-Encoding": "identity"]
        let session = sessionFactory?(configuration, delegate) ?? URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var urlRequest = URLRequest(url: mirror)
        urlRequest.httpMethod = "GET"
        urlRequest.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if offset > 0 {
            urlRequest.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
            if let validator { urlRequest.setValue(validator, forHTTPHeaderField: "If-Range") }
        }
        if let token = request.credentialToken,
           isOfficialCredentialURL(mirror) || (allowTestCredentialsOnLoopback && isLoopbackHTTPURL(mirror)) {
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let task = session.dataTask(with: urlRequest)
        guard register(task: task, for: operation) else {
            task.cancel()
            throw BoundedModelDownloadError.superseded
        }
        delegate.attach(task: task)
        task.resume()
        let result = try await delegate.result()
        try requireCurrent(operation)
        return result
    }

    private func validate(_ request: BoundedModelDownloadRequest) throws {
        let i = request.identity
        guard i.schemaVersion > 0, i.sizeBytes > 0, i.sizeBytes <= 671_088_640,
              request.aggregateDiskBytesStillRequired > 0,
              request.aggregateDiskBytesStillRequired >= i.sizeBytes,
              !request.aggregateDiskBytesStillRequired.addingReportingOverflow(64 * 1024 * 1024).overflow,
              i.sha256.utf8.count == 64, i.sha256.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }),
              isSafeFilename(i.filename), isSafeRelativePath(i.artifactPath),
              !request.mirrors.isEmpty, request.mirrors.count <= 16 else { throw BoundedModelDownloadError.invalidIdentity }
        let mirrorKeys = request.mirrors.map(\.absoluteString)
        guard Set(mirrorKeys).count == mirrorKeys.count,
              request.mirrors.allSatisfy({ mirror in
                  guard mirror.scheme != nil, mirror.host != nil, mirror.user == nil else { return false }
                  if mirror.scheme?.lowercased() == "https" { return true }
                  return allowInsecureLoopback && mirror.scheme?.lowercased() == "http" && (mirror.host?.lowercased() == "localhost" || mirror.host == "127.0.0.1")
              }) else { throw BoundedModelDownloadError.invalidMirror }
    }

    private func preflight(_ request: BoundedModelDownloadRequest, admittedOffset: Int64) throws {
        let required = try requiredCapacity(aggregate: request.aggregateDiskBytesStillRequired, admittedOffset: admittedOffset)
        let available = try capacity.availableCapacity(for: request.workspaceRoot)
        guard available >= required else { throw BoundedModelDownloadError.insufficientSpace(required: required, available: available) }
    }

    fileprivate func requiredCapacity(aggregate: Int64, admittedOffset: Int64) throws -> Int64 {
        guard aggregate > 0, admittedOffset >= 0, admittedOffset <= aggregate else { throw BoundedModelDownloadError.invalidIdentity }
        let (remaining, subtractionOverflow) = aggregate.subtractingReportingOverflow(admittedOffset)
        let (required, additionOverflow) = remaining.addingReportingOverflow(64 * 1024 * 1024)
        guard !subtractionOverflow, !additionOverflow else { throw BoundedModelDownloadError.invalidIdentity }
        return required
    }

    private func isCurrent(_ operation: UInt64) -> Bool {
        state.withLock { $0.activeGeneration == operation && !$0.cancelledGenerations.contains(operation) }
    }

    private func operationError(_ operation: UInt64) -> BoundedModelDownloadError {
        state.withLock { $0.supersededGenerations.contains(operation) ? .superseded : .cancelled }
    }

    private func beginOperation(_ caller: UUID) -> UInt64 {
        let result: (UInt64, URLSessionDataTask?) = state.withLock { state in
            state.nextGeneration &+= 1
            let generation = state.nextGeneration
            let oldTask = state.activeGeneration.flatMap { state.activeTasks[$0] }
            if let old = state.activeGeneration { state.supersededGenerations.insert(old) }
            state.activeGeneration = generation
            let wasCancelledBeforeRegistration = state.cancelledCallers.remove(caller) != nil
            state.generationByCaller[caller] = generation
            if wasCancelledBeforeRegistration { state.cancelledGenerations.insert(generation) }
            return (generation, oldTask)
        }
        result.1?.cancel()
        return result.0
    }

    private func register(task: URLSessionDataTask, for operation: UInt64) -> Bool {
        let accepted = state.withLock { state -> Bool in
            guard state.activeGeneration == operation,
                  !state.cancelledGenerations.contains(operation) else { return false }
            state.activeTasks[operation] = task
            return true
        }
        if !accepted { task.cancel() }
        return accepted
    }

    private func requireCurrent(_ operation: UInt64) throws {
        guard isCurrent(operation) else { throw operationError(operation) }
    }

    /// Checks state without holding the lock while doing filesystem or hashing I/O.
    fileprivate func withCurrentOperation<T: Sendable>(_ operation: UInt64, _ body: @Sendable () throws -> T) throws -> T {
        try requireCurrent(operation)
        let value = try body()
        try requireCurrent(operation)
        return value
    }

    private func isSafeFilename(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.utf8.contains(0)
    }

    private func isSafeRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty, !value.hasPrefix("/"), !value.utf8.contains(0) else { return false }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty && components.allSatisfy { component in
            !component.isEmpty && component != "." && component != ".."
        }
    }

    private static func isResumeRetryable(_ error: BoundedModelDownloadError) -> Bool {
        switch error {
        case .rangeNotHonored, .invalidContentRange, .rangeNotSatisfiable:
            return true
        default:
            return false
        }
    }

    static func identityDirectoryName(for identity: DownloadArtifactIdentity) throws -> String {
        guard identity.sizeBytes > 0 else { throw BoundedModelDownloadError.invalidIdentity }
        let digest = SHA256.hash(data: Data(identity.canonicalKey.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func secureWorkspace(_ root: URL) throws {
        guard root.isFileURL, root.path.hasPrefix("/"), !root.path.contains("..") else { throw BoundedModelDownloadError.invalidIdentity }
        try secureDirectory(root)
    }

    private func secureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw BoundedModelDownloadError.invalidIdentity }
        defer { close(fd) }
        var st = stat(); guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == getuid() else { throw BoundedModelDownloadError.invalidIdentity }
        guard fchmod(fd, 0o700) == 0, fstat(fd, &st) == 0, UInt16(st.st_mode & 0o777) == 0o700 else { throw BoundedModelDownloadError.invalidIdentity }
    }

    private struct ResumeState { var offset: Int64; var validator: String? }

    private func prepareSlot(anchor: WorkspaceAnchor, request: BoundedModelDownloadRequest, mirror: URL, operation: UInt64) throws -> ResumeState {
        _ = try withCurrentOperation(operation) {
            if !anchor.existsPart || !anchor.existsMetadata { try anchor.clear() }
        }
        do {
            let metadata = try JSONDecoder().decode(PartialMetadata.self, from: try anchor.readMetadata(maxBytes: 1 << 20))
            guard metadata.identity == request.identity, metadata.mirror == mirror.absoluteString else { throw BoundedModelDownloadError.invalidResumeState }
            let fd = anchor.openPart(readOnly: true)
            guard fd >= 0 else { throw BoundedModelDownloadError.invalidResumeState }
            defer { close(fd) }
            var st = stat(); guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid(), (st.st_mode & 0o777) == 0o600, st.st_nlink == 1 else { throw BoundedModelDownloadError.invalidResumeState }
            guard st.st_size >= 0, st.st_size <= request.identity.sizeBytes else { throw BoundedModelDownloadError.invalidResumeState }
            try requireCurrent(operation)
            let validator = metadata.validator.flatMap { value in
                value.hasPrefix("\"") && value.hasSuffix("\"") && !value.hasPrefix("W/") ? value : nil
            }
            return ResumeState(offset: Int64(st.st_size), validator: validator)
        } catch {
            try clearSlotIfCurrent(anchor: anchor, operation: operation)
            return ResumeState(offset: 0, validator: nil)
        }
    }

    private func clearSlotIfCurrent(anchor: WorkspaceAnchor, operation: UInt64) throws {
        // A canceled operation owns cleanup until a newer generation replaces it.
        let permitted = state.withLock { $0.activeGeneration == operation }
        guard permitted else { return }
        try anchor.clear()
    }

    private func verify(fd: Int32, identity: DownloadArtifactIdentity) throws {
        guard fd >= 0 else { throw BoundedModelDownloadError.incomplete }; defer { close(fd) }
        var st = stat(); guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid(), (st.st_mode & 0o777) == 0o600, st.st_nlink == 1, Int64(st.st_size) == identity.sizeBytes else { throw BoundedModelDownloadError.incomplete }
        var hasher = SHA256(); var buffer = [UInt8](repeating: 0, count: 64 * 1024); var total: Int64 = 0
        while true { let n = read(fd, &buffer, buffer.count); if n < 0 { throw BoundedModelDownloadError.incomplete }; if n == 0 { break }; hasher.update(data: Data(buffer[0..<n])); total += Int64(n) }
        let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard total == identity.sizeBytes, hash == identity.sha256 else { throw BoundedModelDownloadError.checksumMismatch }
    }

    private func verifyAndPromote(anchor: WorkspaceAnchor, identity: DownloadArtifactIdentity, operation: UInt64) throws {
        try requireCurrent(operation)
        try verify(fd: anchor.openPart(readOnly: true), identity: identity)
        try requireCurrent(operation)
        let claimed = state.withLock { state -> Bool in
            guard state.activeGeneration == operation, !state.cancelledGenerations.contains(operation), !state.supersededGenerations.contains(operation) else { return false }
            state.claimedGenerations.insert(operation); return true
        }
        guard claimed else { throw operationError(operation) }
        try anchor.promote()
        try anchor.removeMetadata()
    }

    fileprivate func isOperationCurrent(_ operation: UInt64) -> Bool { isCurrent(operation) }

    fileprivate func admit(_ data: Data, anchor: WorkspaceAnchor, to fd: Int32, offset: Int64, expected: Int64, operation: UInt64) throws -> Int64 {
        try anchor.ioQueue.sync {
            try withCurrentOperation(operation) {
                try write(data, to: fd, offset: offset, expected: expected)
            }
        }
    }

    fileprivate func write(_ data: Data, to fd: Int32, offset: Int64, expected: Int64) throws -> Int64 {
        guard offset >= 0, offset <= expected, Int64(data.count) <= expected - offset else { throw BoundedModelDownloadError.downloadTooLarge }
        var written = 0
        while written < data.count {
            let n = data.withUnsafeBytes { raw -> Int in
                pwrite(fd, raw.baseAddress!.advanced(by: written), min(64 * 1024, data.count - written), off_t(offset) + off_t(written))
            }
            guard n > 0 else { throw BoundedModelDownloadError.transport("pwrite failed") }
            written += n
        }
        return offset + Int64(written)
    }

    func persist(_ metadata: PartialMetadata, at url: URL) throws {
        let data = try JSONEncoder().encode(metadata)
        let parent = url.deletingLastPathComponent()
        let parentFD = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentFD >= 0 else { throw BoundedModelDownloadError.transport("cannot open metadata parent") }
        defer { _ = close(parentFD) }
        let temporaryName = ".payload.part.json.tmp-\(UUID().uuidString)"
        let temporaryFD = openat(parentFD, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard temporaryFD >= 0 else { throw BoundedModelDownloadError.transport("cannot create metadata temporary") }
        var keepTemporary = true
        defer {
            _ = close(temporaryFD)
            if keepTemporary { _ = unlinkat(parentFD, temporaryName, 0) }
        }
        try data.withUnsafeBytes { raw in
            var written = 0
            while written < data.count {
                let count = Darwin.write(temporaryFD, raw.baseAddress!.advanced(by: written), data.count - written)
                guard count > 0 else { throw BoundedModelDownloadError.transport("cannot write metadata temporary") }
                written += count
            }
        }
        guard fchmod(temporaryFD, mode_t(0o600)) == 0, fsync(temporaryFD) == 0 else { throw BoundedModelDownloadError.transport("cannot finalize metadata temporary") }
        guard renameat(parentFD, temporaryName, parentFD, url.lastPathComponent) == 0 else { throw BoundedModelDownloadError.transport("cannot atomically replace metadata") }
        keepTemporary = false
    }

    private func readSecureFile(_ url: URL, maxBytes: Int) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw BoundedModelDownloadError.invalidResumeState }
        defer { _ = close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0, info.st_size <= maxBytes else { throw BoundedModelDownloadError.invalidResumeState }
        var data = Data(capacity: Int(info.st_size))
        var buffer = [UInt8](repeating: 0, count: min(64 * 1024, maxBytes))
        while true {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count < 0 { throw BoundedModelDownloadError.invalidResumeState }
            if count == 0 { break }
            data.append(contentsOf: buffer[0..<count])
            guard data.count <= maxBytes else { throw BoundedModelDownloadError.invalidResumeState }
        }
        return data
    }

    struct PartialMetadata: Codable, Equatable {
        let identity: DownloadArtifactIdentity
        let mirror: String
        let validator: String?
    }

    private func isOfficialCredentialURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == "huggingface.co" && url.user == nil
    }

    private func isLoopbackHTTPURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "http" && (url.host?.lowercased() == "localhost" || url.host == "127.0.0.1") && url.user == nil
    }
}

private final class WorkspaceAnchor: @unchecked Sendable {
    private static let queueLock = NSLock()
    private nonisolated(unsafe) static var queues: [String: DispatchQueue] = [:]
    let ioQueue: DispatchQueue
    let rootURL: URL
    let partURL: URL
    let metadataURL: URL
    let destinationURL: URL
    private let slotFD: Int32
    private let completedFD: Int32

    var existsPart: Bool { accessAt(slotFD, name: "payload.part") }
    var existsMetadata: Bool { accessAt(slotFD, name: "payload.part.json") }

    init(root: URL, slotName: String, filename: String) throws {
        rootURL = root
        ioQueue = Self.queue(for: root.appendingPathComponent("partials", isDirectory: true).appendingPathComponent(slotName).path)
        let rootFD = try Self.openRoot(root)
        let partialsFD = try Self.openOrCreateDirectory("partials", relativeTo: rootFD)
        slotFD = try Self.openOrCreateDirectory(slotName, relativeTo: partialsFD)
        completedFD = try Self.openOrCreateDirectory("completed", relativeTo: rootFD)
        close(rootFD); close(partialsFD)
        partURL = root.appendingPathComponent("partials", isDirectory: true).appendingPathComponent(slotName, isDirectory: true).appendingPathComponent("payload.part")
        metadataURL = partURL.deletingLastPathComponent().appendingPathComponent("payload.part.json")
        destinationURL = root.appendingPathComponent("completed", isDirectory: true).appendingPathComponent(filename)
    }

    deinit { close(slotFD); close(completedFD) }

    func openPart(readOnly: Bool) -> Int32 {
        openat(slotFD, "payload.part", (readOnly ? O_RDONLY : O_RDWR | O_CREAT) | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
    }

    func clear() throws {
        try ioQueue.sync {
            guard unlinkat(slotFD, "payload.part", 0) == 0 || errno == ENOENT else { throw BoundedModelDownloadError.transport("cannot remove partial") }
            guard unlinkat(slotFD, "payload.part.json", 0) == 0 || errno == ENOENT else { throw BoundedModelDownloadError.transport("cannot remove metadata") }
        }
    }

    func removeMetadata() throws {
        try ioQueue.sync {
            guard unlinkat(slotFD, "payload.part.json", 0) == 0 || errno == ENOENT else { throw BoundedModelDownloadError.transport("cannot remove metadata") }
        }
    }

    func readMetadata(maxBytes: Int) throws -> Data {
        let fd = openat(slotFD, "payload.part.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw BoundedModelDownloadError.invalidResumeState }
        defer { close(fd) }
        var st = stat(); guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid(), (st.st_mode & 0o777) == 0o600, st.st_nlink == 1, st.st_size >= 0, st.st_size <= maxBytes else { throw BoundedModelDownloadError.invalidResumeState }
        var data = Data(capacity: Int(st.st_size)); var bytes = [UInt8](repeating: 0, count: min(65536, maxBytes))
        while true { let n = read(fd, &bytes, bytes.count); if n < 0 { throw BoundedModelDownloadError.invalidResumeState }; if n == 0 { break }; data.append(contentsOf: bytes[0..<n]); if data.count > maxBytes { throw BoundedModelDownloadError.invalidResumeState } }
        return data
    }

    func persistMetadata(_ metadata: BoundedModelDownloadTransport.PartialMetadata) throws {
        let data = try JSONEncoder().encode(metadata)
        let temp = ".payload.part.json.tmp-\(UUID().uuidString)"
        let fd = openat(slotFD, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw BoundedModelDownloadError.transport("cannot create metadata") }
        var keep = true; defer { close(fd); if keep { _ = unlinkat(slotFD, temp, 0) } }
        try data.withUnsafeBytes { raw in
            var written = 0
            while written < data.count { let n = Darwin.write(fd, raw.baseAddress!.advanced(by: written), data.count - written); guard n > 0 else { throw BoundedModelDownloadError.transport("cannot write metadata") }; written += n }
        }
        guard fchmod(fd, mode_t(0o600)) == 0, fsync(fd) == 0, renameat(slotFD, temp, slotFD, "payload.part.json") == 0 else { throw BoundedModelDownloadError.transport("cannot install metadata") }
        keep = false
    }

    func promote() throws {
        try ioQueue.sync {
            try promoteUnlocked()
        }
    }

    private func promoteUnlocked() throws {
        let existing = openat(completedFD, destinationURL.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if existing >= 0 { var st = stat(); guard fstat(existing, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid(), (st.st_mode & 0o777) == 0o600, st.st_nlink == 1 else { close(existing); throw BoundedModelDownloadError.transport("existing destination invalid") }; close(existing) }
        guard renameat(slotFD, "payload.part", completedFD, destinationURL.lastPathComponent) == 0 else { throw BoundedModelDownloadError.transport("cannot promote payload") }
    }

    private static func queue(for key: String) -> DispatchQueue {
        queueLock.lock(); defer { queueLock.unlock() }
        if let queue = queues[key] { return queue }
        let queue = DispatchQueue(label: "com.mactalk.download-slot.\(SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined())")
        queues[key] = queue
        return queue
    }

    private static func openRoot(_ url: URL) throws -> Int32 {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw BoundedModelDownloadError.invalidIdentity }
        var st = stat(); guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == getuid(), (st.st_mode & 0o777) == 0o700 else { close(fd); throw BoundedModelDownloadError.invalidIdentity }
        return fd
    }

    private static func openOrCreateDirectory(_ name: String, relativeTo parent: Int32) throws -> Int32 {
        var fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 && errno == ENOENT { guard mkdirat(parent, name, mode_t(0o700)) == 0 || errno == EEXIST else { throw BoundedModelDownloadError.invalidIdentity }; fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else { throw BoundedModelDownloadError.invalidIdentity }
        var st = stat(); guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == getuid() else { close(fd); throw BoundedModelDownloadError.invalidIdentity }
        if (st.st_mode & 0o777) != 0o700, fchmod(fd, mode_t(0o700)) != 0 { close(fd); throw BoundedModelDownloadError.invalidIdentity }
        guard fstat(fd, &st) == 0, (st.st_mode & 0o777) == 0o700 else { close(fd); throw BoundedModelDownloadError.invalidIdentity }
        return fd
    }

    private func accessAt(_ parent: Int32, name: String) -> Bool { let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC); if fd >= 0 { close(fd); return true }; return false }
}


private final class AttemptDelegate: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private weak var transport: BoundedModelDownloadTransport?
    private let request: BoundedModelDownloadRequest
    private let mirror: URL
    private let anchor: WorkspaceAnchor
    private let initialOffset: Int64
    private let operation: UInt64
    private let capacity: VolumeCapacityProviding
    private let allowInsecureLoopback: Bool
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Int64, Error>?
    private var response: HTTPURLResponse?
    private var fd: Int32 = -1
    private var offset: Int64
    private var finished = false
    private var terminalError: Error?
    private var task: URLSessionTask?
    private var redirectCount = 0

    init(transport: BoundedModelDownloadTransport, request: BoundedModelDownloadRequest, anchor: WorkspaceAnchor, mirror: URL, initialOffset: Int64, operation: UInt64, capacity: VolumeCapacityProviding) {
        self.transport = transport; self.request = request; self.anchor = anchor; self.mirror = mirror; self.initialOffset = initialOffset; self.operation = operation; self.capacity = capacity; self.allowInsecureLoopback = transport.allowInsecureLoopback; self.offset = initialOffset
    }

    func result() async throws -> Int64 {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int64, Error>) in
                lock.lock(); self.continuation = continuation; let done = finished; let error = terminalError; let finalOffset = offset; lock.unlock()
                if done {
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: finalOffset) }
                }
            }
        }, onCancel: { [weak self] in self?.cancel() })
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else { completionHandler(.cancel); fail(BoundedModelDownloadError.transport("non-http response")); return }
        self.response = http
        let status = http.statusCode
        if initialOffset > 0 {
            guard status != 416 else { completionHandler(.cancel); fail(BoundedModelDownloadError.rangeNotSatisfiable); return }
            guard status == 206 else { completionHandler(.cancel); fail(status == 200 ? BoundedModelDownloadError.rangeNotHonored : BoundedModelDownloadError.unexpectedStatus(status)); return }
            guard let range = http.value(forHTTPHeaderField: "Content-Range"), range == "bytes \(initialOffset)-\(request.identity.sizeBytes - 1)/\(request.identity.sizeBytes)" else { completionHandler(.cancel); fail(BoundedModelDownloadError.invalidContentRange); return }
        } else if status != 200 { completionHandler(.cancel); fail(BoundedModelDownloadError.unexpectedStatus(status)); return }
        if let encoding = http.value(forHTTPHeaderField: "Content-Encoding"), !encoding.isEmpty && encoding.lowercased() != "identity" { completionHandler(.cancel); fail(BoundedModelDownloadError.invalidContentEncoding); return }
        if let lengthString = http.value(forHTTPHeaderField: "Content-Length"), let length = Int64(lengthString) {
            let expected = request.identity.sizeBytes - initialOffset
            guard length == expected else { completionHandler(.cancel); fail(BoundedModelDownloadError.unexpectedContentLength(length)); return }
        }
        guard let transport else { completionHandler(.cancel); fail(BoundedModelDownloadError.superseded); return }
        let validator = Self.strongValidator(from: http)
        do {
            let opened = try transport.withCurrentOperation(operation) {
                let opened = anchor.openPart(readOnly: false)
                guard opened >= 0 else { throw BoundedModelDownloadError.transport("cannot open partial") }
                do {
                    try anchor.persistMetadata(.init(identity: request.identity, mirror: mirror.absoluteString, validator: validator))
                } catch {
                    _ = close(opened)
                    throw error
                }
                return opened
            }
            lock.lock(); fd = opened; lock.unlock()
        } catch {
            completionHandler(.cancel); fail(error); return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let transport else { fail(BoundedModelDownloadError.cancelled); return }
        guard transport.isOperationCurrent(operation) else { fail(BoundedModelDownloadError.superseded); return }
        lock.lock(); let current = offset; lock.unlock()
        do {
            let required = try transport.requiredCapacity(aggregate: request.aggregateDiskBytesStillRequired, admittedOffset: current)
            let available = try capacity.availableCapacity(for: request.workspaceRoot)
            guard available >= required else { throw BoundedModelDownloadError.insufficientSpace(required: required, available: available) }
            lock.lock(); let currentOperation = offset; lock.unlock()
            let next = try transport.admit(data, anchor: anchor, to: fd, offset: currentOperation, expected: request.identity.sizeBytes, operation: operation)
            lock.lock(); offset = next; lock.unlock()
            request.progress?(next, request.identity.sizeBytes)
        } catch { fail(error) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        lock.lock(); redirectCount += 1; let redirects = redirectCount; lock.unlock()
        guard redirects <= 10, response.statusCode >= 300 && response.statusCode < 400, let destination = newRequest.url, destination.user == nil,
              destination.scheme?.lowercased() == "https" || (allowInsecureLoopback && destination.scheme?.lowercased() == "http" && (destination.host?.lowercased() == "localhost" || destination.host == "127.0.0.1")) else { completionHandler(nil); fail(BoundedModelDownloadError.invalidMirror); return }
        var redirected = newRequest
        redirected.setValue(nil, forHTTPHeaderField: "Authorization")
        completionHandler(redirected)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let currentFD = fd; fd = -1; let wasFinished = finished; lock.unlock()
        if currentFD >= 0 { close(currentFD) }
        if wasFinished { return }
        guard let transport, transport.isOperationCurrent(operation) else {
            fail(BoundedModelDownloadError.superseded)
            return
        }
        if let error {
            if (error as NSError).code == NSURLErrorCancelled { fail(BoundedModelDownloadError.cancelled) }
            else { fail(BoundedModelDownloadError.interrupted) }
        } else {
            lock.lock(); let end = offset; lock.unlock()
            if end != request.identity.sizeBytes {
                // A clean close before the exact body size is still a resumable
                // interruption; the bounded prefix and identity metadata remain.
                fail(BoundedModelDownloadError.interrupted)
            } else {
                finish(error: nil)
            }
        }
    }

    private static func strongValidator(from response: HTTPURLResponse) -> String? {
        guard let value = response.value(forHTTPHeaderField: "ETag"),
              value.hasPrefix("\"") && value.hasSuffix("\"") && !value.hasPrefix("W/") else { return nil }
        return value
    }

    func attach(task: URLSessionTask) { lock.lock(); self.task = task; lock.unlock() }
    private func cancel() { lock.lock(); let task = self.task; lock.unlock(); task?.cancel(); transport?.cancelGeneration(operation); fail(BoundedModelDownloadError.cancelled) }
    private func fail(_ error: Error) { finish(error: error) }
    private func finish(error: Error?) {
        lock.lock(); guard !finished else { lock.unlock(); return }; finished = true; terminalError = error; let continuation = self.continuation; self.continuation = nil; lock.unlock()
        if let continuation { if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: offset) } }
    }
}
