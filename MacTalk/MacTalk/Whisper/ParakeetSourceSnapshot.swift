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
    let parent: URL
    let sourceDirectoryName: String
    let entries: [GeneratedParakeetManifestEntry]
    let identity: ParakeetSourceIdentity

    init(parent: URL, sourceDirectoryName: String = "parakeet-tdt-0.6b-v3-source", entries: [GeneratedParakeetManifestEntry] = GeneratedModelProvenance.parakeetSource, identity: ParakeetSourceIdentity = .production) {
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
    case cancelled
}

final class VerifiedParakeetSourceSnapshotProvider: VerifiedParakeetSourceSnapshotProviding, @unchecked Sendable {
    private let store: ParakeetSourceStore
    private let queue: DispatchQueue
    private let beforeArtifactRead: (@Sendable () -> Void)?

    init(store: ParakeetSourceStore, queue: DispatchQueue? = nil, beforeArtifactRead: (@Sendable () -> Void)? = nil) {
        self.store = store
        self.queue = queue ?? DispatchQueue(label: "com.mactalk.parakeet-source-snapshot", qos: .userInitiated)
        self.beforeArtifactRead = beforeArtifactRead
    }

    func makeVerifiedSnapshot() async throws -> VerifiedParakeetSourceSnapshot {
        let lock = ParakeetStoreFileLock(storeParent: store.parent)
        let lease = try await lock.acquire(.shared)
        let cancellation = SnapshotCancellation()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        try cancellation.check()
                        guard let snapshot = try lease.withStoreParentDescriptorIfAvailable({ parentFD in
                            try self.readSnapshot(parentFD: parentFD, cancellation: cancellation)
                        }) else {
                            throw ParakeetSourceSnapshotError.cancelled
                        }
                        lease.release()
                        continuation.resume(returning: snapshot)
                    } catch {
                        lease.release()
                        continuation.resume(throwing: error)
                    }
                }
            }
        }, onCancel: {
            cancellation.cancel()
            lease.release()
        })
    }

    private func readSnapshot(parentFD: Int32, cancellation: SnapshotCancellation) throws -> VerifiedParakeetSourceSnapshot {
        try cancellation.check()
        guard !store.sourceDirectoryName.isEmpty,
              !store.sourceDirectoryName.contains("/"),
              store.sourceDirectoryName != ".", store.sourceDirectoryName != "..",
              !store.sourceDirectoryName.utf8.contains(0) else {
            throw ParakeetSourceSnapshotError.invalidSourceDirectoryName
        }
        let sourceFD = try openDirectory(named: store.sourceDirectoryName, relativeTo: parentFD)
        defer { _ = close(sourceFD) }
        try validatePrivateDirectory(sourceFD)
        try cancellation.check()
        let markerData = try readMarker(sourceFD: sourceFD, cancellation: cancellation)
        try validateMarker(markerData)
        try enumerateExactTree(sourceFD: sourceFD, cancellation: cancellation)

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
                  let suffix = entry.role == "specification" ? "model.mlmodel" : "weights/weight.bin"
                  return entry.path == "mlpackages/\(component.rawValue).mlpackage/Data/com.apple.CoreML/\(suffix)"
              }) else {
            throw ParakeetSourceSnapshotError.duplicateStructure("manifest")
        }
        let reader = VerifiedArtifactReader(rootFD: sourceFD, cancellationCheck: { cancellation.isCancelled })
        var assets = [ParakeetSourceComponent: VerifiedCoreMLAssetBytes]()
        for component in ParakeetSourceComponent.allCases {
            try cancellation.check()
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

    private func enumerateExactTree(sourceFD: Int32, cancellation: SnapshotCancellation) throws {
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
        try walk(fd: sourceFD, relativePath: "", expectedFiles: expectedFiles, expectedDirectories: expectedDirectories, found: &found, cancellation: cancellation)
        guard found == expectedFiles.union(expectedDirectories) else {
            let missing = expectedFiles.union(expectedDirectories).subtracting(found).sorted().first ?? "unknown"
            throw ParakeetSourceSnapshotError.missingPath(missing)
        }
    }

    private func walk(fd: Int32, relativePath: String, expectedFiles: Set<String>, expectedDirectories: Set<String>, found: inout Set<String>, cancellation: SnapshotCancellation) throws {
        try cancellation.check()
        let listingFD = dup(fd)
        guard listingFD >= 0, let directory = fdopendir(listingFD) else { throw ParakeetSourceSnapshotError.sourceNotDirectory }
        defer { closedir(directory) }
        while let item = readdir(directory) {
            try cancellation.check()
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
                found.insert(path)
                let child = try openDirectory(named: name, relativeTo: fd)
                defer { _ = close(child) }
                try walk(fd: child, relativePath: path, expectedFiles: expectedFiles, expectedDirectories: expectedDirectories, found: &found, cancellation: cancellation)
            } else {
                guard type == S_IFREG else { throw type == S_IFLNK ? ParakeetSourceSnapshotError.symlinkPath(path) : ParakeetSourceSnapshotError.nonRegularPath(path) }
                found.insert(path)
            }
        }
    }

    private func readMarker(sourceFD: Int32, cancellation: SnapshotCancellation) throws -> Data {
        let fd = try openFile(named: ParakeetSourceStore.identityMarkerName, relativeTo: sourceFD)
        defer { _ = close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw ParakeetSourceSnapshotError.markerMissing }
        guard info.st_size >= 0, info.st_size <= 16 * 1024 else { throw ParakeetSourceSnapshotError.markerTooLarge }
        let dataSize = Int(info.st_size)
        var data = Data(count: dataSize)
        var offset = 0
        try data.withUnsafeMutableBytes { raw in
            while offset < dataSize {
                try cancellation.check()
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

private final class SnapshotCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws { if isCancelled { throw ParakeetSourceSnapshotError.cancelled } }
}
