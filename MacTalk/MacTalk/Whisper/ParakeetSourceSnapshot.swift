import CryptoKit
import Darwin
import Foundation

struct ParakeetSourceIdentity: Codable, Hashable, Sendable {
    let formatVersion: Int
    let repository: String
    let revision: String
    let fluidAudioRevision: String
    let canonicalProvenanceSHA256: String

    static let production = ParakeetSourceIdentity(
        formatVersion: 1,
        repository: GeneratedModelProvenance.parakeetRepository,
        revision: GeneratedModelProvenance.parakeetRevision,
        fluidAudioRevision: GeneratedModelProvenance.fluidAudioRevision,
        canonicalProvenanceSHA256: GeneratedModelProvenance.canonicalProvenanceSHA256
    )
}

enum ParakeetSourceComponent: String, Codable, Hashable, Sendable, CaseIterable {
    case preprocessor = "Preprocessor"
    case encoder = "Encoder"
    case decoder = "Decoder"
    case joint = "JointDecisionv3"
}

enum ParakeetSourceArtifactKind: String, Codable, Hashable, Sendable {
    case specification
    case weights
    case vocabulary
}

/// The generated source manifest is authoritative: package placement is part
/// of each component/role contract, not a traversable directory convention.
enum ParakeetSourcePathContract {
    private static let paths: [ParakeetSourceComponent: [ParakeetSourceArtifactKind: String]] = [
        .preprocessor: [
            .specification: "mlpackages/Preprocessor.mlpackage/Data/com.apple.CoreML/model.mlmodel",
            .weights: "mlpackages/Preprocessor.mlpackage/Data/com.apple.CoreML/weights/weight.bin"
        ],
        .encoder: [
            .specification: "mlpackages/Encoder.mlpackage/Data/com.apple.CoreML/model.mlmodel",
            .weights: "mlpackages/Encoder.mlpackage/Data/com.apple.CoreML/weights/weight.bin"
        ],
        .decoder: [
            .specification: "mlpackages/Decoder.mlpackage/Data/com.apple.CoreML/model.mlmodel",
            .weights: "mlpackages/Decoder.mlpackage/Data/com.apple.CoreML/weights/weight.bin"
        ],
        .joint: [
            .specification: "JointDecisionv3.mlpackage/Data/com.apple.CoreML/model.mlmodel",
            .weights: "JointDecisionv3.mlpackage/Data/com.apple.CoreML/weights/weight.bin"
        ]
    ]

    static func expectedPath(component: ParakeetSourceComponent, role: String) -> String? {
        guard let kind = ParakeetSourceArtifactKind(rawValue: role), kind != .vocabulary else { return nil }
        return paths[component]?[kind]
    }
}

struct VerifiedCoreMLAssetBytes: Sendable {
    let component: ParakeetSourceComponent
    let specification: VerifiedArtifactBytes
    let weights: VerifiedArtifactBytes
}

struct VerifiedParakeetSourceSnapshot: Sendable {
    let identity: ParakeetSourceIdentity
    let assets: [ParakeetSourceComponent: VerifiedCoreMLAssetBytes]
    let vocabulary: VerifiedArtifactBytes
}

struct ParakeetSourceStore: Sendable {
    static let identityMarkerName = ".mactalk-source-identity.json"
    static let canonicalDirectoryName = "parakeet-tdt-0.6b-v3-source"
    static let stagingPrefix = ".mactalk-source-staging-"
    static let backupPrefix = ".mactalk-source-backup-"

    let parent: URL
    let sourceDirectoryName: String
    let entries: [GeneratedParakeetManifestEntry]
    let identity: ParakeetSourceIdentity

    /// The only production construction path. Its manifest and identity are
    /// generated constants; no filesystem work occurs here.
    static func canonical(parent: URL) -> ParakeetSourceStore {
        ParakeetSourceStore(parent: parent, sourceDirectoryName: canonicalDirectoryName,
                            entries: GeneratedModelProvenance.parakeetSource, identity: .production)
    }

    /// Fully explicit so hermetic tests cannot accidentally inherit production
    /// paths, manifests, or provenance.
    init(parent: URL, sourceDirectoryName: String, entries: [GeneratedParakeetManifestEntry], identity: ParakeetSourceIdentity) {
        self.parent = parent
        self.sourceDirectoryName = sourceDirectoryName
        self.entries = entries
        self.identity = identity
    }
}

protocol VerifiedParakeetSourceSnapshotProviding: Sendable {
    func makeVerifiedSnapshot() async throws -> VerifiedParakeetSourceSnapshot
}

enum ParakeetSourceSnapshotError: Error, Equatable, Sendable {
    case invalidSourceDirectoryName
    case sourceNotDirectory
    case sourceWrongOwner
    case sourceWrongPermissions(UInt16)
    case pathWrongOwner(String)
    case pathWrongPermissions(String, UInt16)
    case markerMissing
    case markerTooLarge
    case markerMalformed
    case markerDuplicateKey(String)
    case markerKeysMismatch
    case markerMismatch
    case unexpectedPath(String)
    case missingPath(String)
    case symlinkPath(String)
    case nonRegularPath(String)
    case duplicateStructure(String)
    case missingComponent(String)
    case missingArtifact(String, String)
    case duplicateArtifact(String, String)
    case leaseStoreParentMismatch
    case cancelled
}

final class VerifiedParakeetSourceSnapshotProvider: VerifiedParakeetSourceSnapshotProviding, @unchecked Sendable {
    private let store: ParakeetSourceStore
    private let queue: DispatchQueue
    private let beforeArtifactRead: (@Sendable () -> Void)?
    private let beforeCompletion: (@Sendable () -> Void)?
    private let forceFdopendirFailure: Bool

    convenience init(store: ParakeetSourceStore, queue: DispatchQueue? = nil, beforeArtifactRead: (@Sendable () -> Void)? = nil, beforeCompletion: (@Sendable () -> Void)? = nil) {
        self.init(store: store, queue: queue, beforeArtifactRead: beforeArtifactRead, beforeCompletion: beforeCompletion, forceFdopendirFailure: false)
    }

    init(store: ParakeetSourceStore, queue: DispatchQueue? = nil, beforeArtifactRead: (@Sendable () -> Void)? = nil, beforeCompletion: (@Sendable () -> Void)? = nil, forceFdopendirFailure: Bool = false) {
        self.store = store
        self.queue = queue ?? DispatchQueue(label: "com.mactalk.parakeet-source-snapshot", qos: .userInitiated)
        self.beforeArtifactRead = beforeArtifactRead
        self.beforeCompletion = beforeCompletion
        self.forceFdopendirFailure = forceFdopendirFailure
    }

    func makeVerifiedSnapshot() async throws -> VerifiedParakeetSourceSnapshot {
        let lock = ParakeetStoreFileLock(storeParent: store.parent)
        let lease: ParakeetStoreFileLock.Lease
        do {
            lease = try await lock.acquire(.shared)
        } catch is CancellationError {
            throw ParakeetSourceSnapshotError.cancelled
        }
        return try await makeVerifiedSnapshot(lease: lease, releaseLease: true)
    }

    /// Validates through a caller-owned exclusive lease. This overload never
    /// acquires or releases a lease; cancellation only cancels this read.
    func makeVerifiedSnapshot(holding lease: ParakeetStoreFileLock.Lease) async throws -> VerifiedParakeetSourceSnapshot {
        // The caller-owned descriptor is authoritative only for the store it
        // was acquired for. Never let a provider for parent A read via B.
        guard lease.authorizesStoreParent(store.parent) else {
            throw ParakeetSourceSnapshotError.leaseStoreParentMismatch
        }
        return try await makeVerifiedSnapshot(lease: lease, releaseLease: false)
    }

    private func makeVerifiedSnapshot(lease: ParakeetStoreFileLock.Lease, releaseLease: Bool) async throws -> VerifiedParakeetSourceSnapshot {
        let operation = SnapshotOperationState()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        try operation.check()
                        guard let snapshot = try lease.withStoreParentDescriptorIfAvailable({ parentFD in
                            try self.readSnapshot(parentFD: parentFD, operation: operation)
                        }) else {
                            throw ParakeetSourceSnapshotError.cancelled
                        }
                        self.beforeCompletion?()
                        let result: Result<VerifiedParakeetSourceSnapshot, Error>
                        if operation.claimCompletion() {
                            result = .success(snapshot)
                        } else {
                            result = .failure(ParakeetSourceSnapshotError.cancelled)
                        }
                        if releaseLease { lease.release() }
                        continuation.resume(with: result)
                    } catch {
                        if releaseLease { lease.release() }
                        let mappedError: Error = error is VerifiedArtifactReaderError && operation.isCancelled
                            ? ParakeetSourceSnapshotError.cancelled
                            : error
                        let result: Result<VerifiedParakeetSourceSnapshot, Error>
                        if operation.claimCompletion() {
                            result = .failure(mappedError)
                        } else {
                            result = .failure(ParakeetSourceSnapshotError.cancelled)
                        }
                        continuation.resume(with: result)
                    }
                }
            }
        }, onCancel: {
            operation.cancel()
            if releaseLease { lease.release() }
        })
    }

    private func readSnapshot(parentFD: Int32, operation: SnapshotOperationState) throws -> VerifiedParakeetSourceSnapshot {
        try operation.check()
        guard !store.sourceDirectoryName.isEmpty,
              !store.sourceDirectoryName.contains("/"),
              store.sourceDirectoryName != ".", store.sourceDirectoryName != "..",
              !store.sourceDirectoryName.utf8.contains(0) else {
            throw ParakeetSourceSnapshotError.invalidSourceDirectoryName
        }
        let sourceFD = try openDirectory(named: store.sourceDirectoryName, relativeTo: parentFD)
        defer { _ = close(sourceFD) }
        try validatePrivateDirectory(sourceFD)
        try operation.check()
        let markerData = try readMarker(sourceFD: sourceFD, operation: operation)
        try validateMarker(markerData)
        try enumerateExactTree(sourceFD: sourceFD, operation: operation)

        let sourceEntries = store.entries.filter { $0.role == "specification" || $0.role == "weights" }
        let vocabularyEntries = store.entries.filter { $0.role == "vocabulary" }
        let uniquePaths = Set(store.entries.map(\.path))
        guard store.entries.count == 9, uniquePaths.count == store.entries.count,
              sourceEntries.count == 8, vocabularyEntries.count == 1,
              vocabularyEntries[0].component == "Vocabulary",
              vocabularyEntries[0].path == "parakeet_vocab.json",
              sourceEntries.allSatisfy({ entry in
                  guard let component = ParakeetSourceComponent(rawValue: entry.component),
                        entry.role == "specification" || entry.role == "weights" else { return false }
                  return ParakeetSourcePathContract.expectedPath(component: component, role: entry.role) == entry.path
              }) else {
            throw ParakeetSourceSnapshotError.duplicateStructure("manifest")
        }
        let reader = VerifiedArtifactReader(rootFD: sourceFD, cancellationCheck: { operation.isCancelled })
        var assets = [ParakeetSourceComponent: VerifiedCoreMLAssetBytes]()
        for component in ParakeetSourceComponent.allCases {
            try operation.check()
            let entries = sourceEntries.filter { $0.component == component.rawValue }
            guard entries.count == 2 else { throw ParakeetSourceSnapshotError.missingComponent(component.rawValue) }
            guard let specification = entries.first(where: { $0.role == "specification" }),
                  let weights = entries.first(where: { $0.role == "weights" }) else {
                throw ParakeetSourceSnapshotError.missingArtifact(component.rawValue, "specification/weights")
            }
            beforeArtifactRead?()
            let specBytes = try reader.read(specification)
            let weightBytes = try reader.read(weights)
            assets[component] = VerifiedCoreMLAssetBytes(component: component, specification: specBytes, weights: weightBytes)
        }
        guard let vocabularyEntry = vocabularyEntries.first else {
            throw ParakeetSourceSnapshotError.missingArtifact("Vocabulary", "vocabulary")
        }
        let vocabulary = try reader.read(vocabularyEntry)
        return VerifiedParakeetSourceSnapshot(identity: store.identity, assets: assets, vocabulary: vocabulary)
    }

    private func validateMarker(_ data: Data) throws {
        guard data.count <= 16 * 1024 else { throw ParakeetSourceSnapshotError.markerTooLarge }
        let expectedKeys: Set<String> = ["formatVersion", "repository", "revision", "fluidAudioRevision", "canonicalProvenanceSHA256"]
        let keys = try topLevelJSONKeys(data)
        guard keys.count == expectedKeys.count else { throw ParakeetSourceSnapshotError.markerKeysMismatch }
        guard Set(keys) == expectedKeys else { throw ParakeetSourceSnapshotError.markerKeysMismatch }
        do {
            let marker = try JSONDecoder().decode(ParakeetSourceIdentity.self, from: data)
            guard marker == store.identity else { throw ParakeetSourceSnapshotError.markerMismatch }
        } catch let error as ParakeetSourceSnapshotError {
            throw error
        } catch {
            throw ParakeetSourceSnapshotError.markerMalformed
        }
    }

    private func topLevelJSONKeys(_ data: Data) throws -> [String] {
        let bytes = Array(data)
        var index = 0
        func skipWhitespace() { while index < bytes.count && (bytes[index] == 32 || bytes[index] == 9 || bytes[index] == 10 || bytes[index] == 13) { index += 1 } }
        func parseString() throws -> String {
            guard index < bytes.count, bytes[index] == 34 else { throw ParakeetSourceSnapshotError.markerMalformed }
            let start = index
            index += 1
            var escaped = false
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                if escaped { escaped = false; continue }
                if byte == 92 { escaped = true; continue }
                if byte == 34 {
                    let stringData = Data(bytes[start..<index])
                    guard let value = String(data: stringData, encoding: .utf8), let decoded = try? JSONDecoder().decode(String.self, from: stringData) else { throw ParakeetSourceSnapshotError.markerMalformed }
                    return decoded
                }
            }
            throw ParakeetSourceSnapshotError.markerMalformed
        }
        skipWhitespace()
        guard index < bytes.count, bytes[index] == 123 else { throw ParakeetSourceSnapshotError.markerMalformed }
        index += 1
        var keys = [String]()
        while true {
            skipWhitespace()
            if index < bytes.count, bytes[index] == 125 { index += 1; break }
            let key = try parseString()
            skipWhitespace()
            guard index < bytes.count, bytes[index] == 58 else { throw ParakeetSourceSnapshotError.markerMalformed }
            index += 1
            skipWhitespace()
            guard index < bytes.count else { throw ParakeetSourceSnapshotError.markerMalformed }
            if bytes[index] == 34 { _ = try parseString() }
            else {
                let start = index
                while index < bytes.count && bytes[index] != 44 && bytes[index] != 125 { index += 1 }
                guard !Data(bytes[start..<index]).isEmpty else { throw ParakeetSourceSnapshotError.markerMalformed }
            }
            if keys.contains(key) { throw ParakeetSourceSnapshotError.markerDuplicateKey(key) }
            keys.append(key)
            skipWhitespace()
            guard index < bytes.count else { throw ParakeetSourceSnapshotError.markerMalformed }
            if bytes[index] == 44 { index += 1; continue }
            if bytes[index] == 125 { index += 1; break }
            throw ParakeetSourceSnapshotError.markerMalformed
        }
        skipWhitespace()
        guard index == bytes.count else { throw ParakeetSourceSnapshotError.markerMalformed }
        return keys
    }

    private func enumerateExactTree(sourceFD: Int32, operation: SnapshotOperationState) throws {
        var expectedFiles = Set([ParakeetSourceStore.identityMarkerName])
        for entry in store.entries { expectedFiles.insert(entry.path) }
        var expectedDirectories = Set<String>()
        for path in expectedFiles where path != ParakeetSourceStore.identityMarkerName {
            var prefix = ""
            let components = path.split(separator: "/").map(String.init)
            for component in components.dropLast() {
                prefix = prefix.isEmpty ? component : "\(prefix)/\(component)"
                expectedDirectories.insert(prefix)
            }
        }
        var found = Set<String>()
        try walk(fd: sourceFD, relativePath: "", expectedFiles: expectedFiles, expectedDirectories: expectedDirectories, found: &found, operation: operation)
        guard found == expectedFiles.union(expectedDirectories) else {
            let missing = expectedFiles.union(expectedDirectories).subtracting(found).sorted().first ?? "unknown"
            throw ParakeetSourceSnapshotError.missingPath(missing)
        }
    }

    private func walk(fd: Int32, relativePath: String, expectedFiles: Set<String>, expectedDirectories: Set<String>, found: inout Set<String>, operation: SnapshotOperationState) throws {
        try operation.check()
        let listingFD = dup(fd)
        guard listingFD >= 0 else { throw ParakeetSourceSnapshotError.sourceNotDirectory }
        if forceFdopendirFailure {
            _ = close(listingFD)
            throw ParakeetSourceSnapshotError.sourceNotDirectory
        }
        guard let directory = fdopendir(listingFD) else {
            _ = close(listingFD)
            throw ParakeetSourceSnapshotError.sourceNotDirectory
        }
        defer { closedir(directory) }
        while let item = readdir(directory) {
            try operation.check()
            let name = withUnsafePointer(to: item.pointee.d_name) { pointer in String(cString: UnsafeRawPointer(pointer).assumingMemoryBound(to: CChar.self)) }
            guard name != ".", name != ".." else { continue }
            let path = relativePath.isEmpty ? name : "\(relativePath)/\(name)"
            guard expectedFiles.contains(path) || expectedDirectories.contains(path) else { throw ParakeetSourceSnapshotError.unexpectedPath(path) }
            var info = stat()
            let result = name.withCString { fstatat(fd, $0, &info, AT_SYMLINK_NOFOLLOW) }
            guard result == 0 else { throw ParakeetSourceSnapshotError.unexpectedPath(path) }
            let type = info.st_mode & S_IFMT
            if expectedDirectories.contains(path) {
                guard type == S_IFDIR else { throw type == S_IFLNK ? ParakeetSourceSnapshotError.symlinkPath(path) : ParakeetSourceSnapshotError.nonRegularPath(path) }
                try validatePrivateDirectory(info, path: path)
                found.insert(path)
                let child = try openDirectory(named: name, relativeTo: fd)
                defer { _ = close(child) }
                try walk(fd: child, relativePath: path, expectedFiles: expectedFiles, expectedDirectories: expectedDirectories, found: &found, operation: operation)
            } else {
                guard type == S_IFREG else { throw type == S_IFLNK ? ParakeetSourceSnapshotError.symlinkPath(path) : ParakeetSourceSnapshotError.nonRegularPath(path) }
                try validatePrivateFile(info, path: path)
                found.insert(path)
            }
        }
    }

    private func readMarker(sourceFD: Int32, operation: SnapshotOperationState) throws -> Data {
        let fd = try openFile(named: ParakeetSourceStore.identityMarkerName, relativeTo: sourceFD)
        defer { _ = close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw ParakeetSourceSnapshotError.markerMissing }
        try validatePrivateFile(info, path: ParakeetSourceStore.identityMarkerName)
        guard info.st_size >= 0, info.st_size <= 16 * 1024 else { throw ParakeetSourceSnapshotError.markerTooLarge }
        let dataSize = Int(info.st_size)
        var data = Data(count: dataSize)
        var offset = 0
        try data.withUnsafeMutableBytes { raw in
            while offset < dataSize {
                try operation.check()
                let count = Darwin.read(fd, raw.baseAddress!.advanced(by: offset), dataSize - offset)
                if count < 0 { if errno == EINTR { continue }; throw ParakeetSourceSnapshotError.markerMalformed }
                if count == 0 { throw ParakeetSourceSnapshotError.markerMalformed }
                offset += count
            }
        }
        return data
    }

    private func validatePrivateDirectory(_ fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw ParakeetSourceSnapshotError.sourceNotDirectory }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { throw ParakeetSourceSnapshotError.sourceNotDirectory }
        guard info.st_uid == getuid() else { throw ParakeetSourceSnapshotError.sourceWrongOwner }
        guard UInt16(info.st_mode & 0o777) == 0o700 else { throw ParakeetSourceSnapshotError.sourceWrongPermissions(UInt16(info.st_mode & 0o777)) }
    }

    private func validatePrivateDirectory(_ info: stat, path: String) throws {
        guard info.st_uid == getuid() else { throw ParakeetSourceSnapshotError.pathWrongOwner(path) }
        let permissions = UInt16(info.st_mode & 0o777)
        guard permissions == 0o700 else { throw ParakeetSourceSnapshotError.pathWrongPermissions(path, permissions) }
    }

    private func validatePrivateFile(_ info: stat, path: String) throws {
        guard info.st_uid == getuid() else { throw ParakeetSourceSnapshotError.pathWrongOwner(path) }
        let permissions = UInt16(info.st_mode & 0o777)
        guard permissions == 0o600 else { throw ParakeetSourceSnapshotError.pathWrongPermissions(path, permissions) }
    }

    private func openDirectory(named name: String, relativeTo fd: Int32) throws -> Int32 {
        let child = name.withCString { openat(fd, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard child >= 0 else { throw ParakeetSourceSnapshotError.sourceNotDirectory }
        return child
    }

    private func openFile(named name: String, relativeTo fd: Int32) throws -> Int32 {
        let child = name.withCString { openat(fd, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK) }
        guard child >= 0 else { throw ParakeetSourceSnapshotError.markerMissing }
        return child
    }
}

private final class SnapshotOperationState: @unchecked Sendable {
    private enum State {
        case pending
        case cancelled
        case completed
    }

    private let lock = NSLock()
    private var state = State.pending

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        if case .cancelled = state { return true }
        return false
    }

    func cancel() {
        lock.lock()
        if case .pending = state { state = .cancelled }
        lock.unlock()
    }

    func check() throws {
        guard isCancelled == false else { throw ParakeetSourceSnapshotError.cancelled }
    }

    /// Claims the single completion linearization point. Once claimed, a later
    /// cancellation cannot rewrite the result that the queue is about to resume.
    func claimCompletion() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard case .pending = state else { return false }
        state = .completed
        return true
    }
}
