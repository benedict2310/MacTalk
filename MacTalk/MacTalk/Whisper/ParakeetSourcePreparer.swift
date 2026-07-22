import CryptoKit
import Darwin
import Foundation

protocol ParakeetSourceArtifactMaterializing: Sendable {
    func materialize(entry: GeneratedParakeetManifestEntry, sink: ParakeetSourceArtifactSink) async throws
}

/// A bounded descriptor opened by the preparer for one exact manifest path.
/// Materializers can write bytes, but cannot select paths or mutate the store.
final class ParakeetSourceArtifactSink: @unchecked Sendable {
    private let descriptor: Int32
    private let expectedSize: Int64
    private let expectedDigest: String
    private var written: Int64 = 0
    private var closed = false

    fileprivate init(descriptor: Int32, entry: GeneratedParakeetManifestEntry) {
        self.descriptor = descriptor
        self.expectedSize = entry.size
        self.expectedDigest = entry.sha256
    }

    func write(_ data: Data) throws {
        guard !closed else { throw ParakeetSourcePreparationError.sinkClosed }
        guard data.count <= expectedSize - written else { throw ParakeetSourcePreparationError.artifactSize }
        var offset = 0
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            while offset < data.count {
                let result = Darwin.write(descriptor, base.advanced(by: offset), data.count - offset)
                if result < 0 {
                    if errno == EINTR { continue }
                    throw ParakeetSourcePreparationError.io(errno)
                }
                guard result > 0 else { throw ParakeetSourcePreparationError.io(EIO) }
                offset += result
            }
        }
        written += Int64(data.count)
    }

    fileprivate func finish() throws {
        guard !closed else { throw ParakeetSourcePreparationError.sinkClosed }
        guard written == expectedSize else { throw ParakeetSourcePreparationError.artifactSize }
        guard fsync(descriptor) == 0 else { throw ParakeetSourcePreparationError.io(errno) }
        guard lseek(descriptor, 0, SEEK_SET) >= 0 else { throw ParakeetSourcePreparationError.io(errno) }
        var digest = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw ParakeetSourcePreparationError.io(errno)
            }
            if count == 0 { break }
            digest.update(data: Data(buffer[0..<count]))
        }
        let actual = digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == expectedDigest else { throw ParakeetSourcePreparationError.artifactDigest }
        closed = true
        _ = Darwin.close(descriptor)
    }

    deinit {
        if !closed { _ = Darwin.close(descriptor) }
    }
}

enum ParakeetSourcePreparationError: Error, Equatable, Sendable {
    case cancelled
    case invalidManifest
    case invalidPath(String)
    case artifactSize
    case artifactDigest
    case sinkClosed
    case io(Int32)
    case collision(String)
    case invalidTree
    case activationFailed
    case validationFailed
}

/// Builds the inactive source generation behind one exclusive store lease.
/// No production caller is installed in Task 10a; materializers are an
/// internal seam for the future source artifact acquisition work.
final class ParakeetSourcePreparer: @unchecked Sendable {
    private let store: ParakeetSourceStore
    private let materializer: any ParakeetSourceArtifactMaterializing
    private let beforeValidation: (@Sendable () -> Void)?
    private let beforeActivation: (@Sendable () -> Void)?

    init(store: ParakeetSourceStore, materializer: any ParakeetSourceArtifactMaterializing,
         beforeValidation: (@Sendable () -> Void)? = nil,
         beforeActivation: (@Sendable () -> Void)? = nil) {
        self.store = store
        self.materializer = materializer
        self.beforeValidation = beforeValidation
        self.beforeActivation = beforeActivation
    }

    convenience init(parent: URL, materializer: any ParakeetSourceArtifactMaterializing,
                     beforeValidation: (@Sendable () -> Void)? = nil,
                     beforeActivation: (@Sendable () -> Void)? = nil) {
        self.init(store: .canonical(parent: parent), materializer: materializer,
                  beforeValidation: beforeValidation, beforeActivation: beforeActivation)
    }

    func prepareIfNeeded() async throws -> URL {
        // This validation is deliberately pure: no lock acquisition (which may
        // create the parent) or other filesystem mutation precedes it.
        try validateConfiguration()
        let lock = ParakeetStoreFileLock(storeParent: store.parent)
        let lease: ParakeetStoreFileLock.Lease
        do {
            lease = try await lock.acquire(.exclusive)
        } catch is CancellationError {
            throw ParakeetSourcePreparationError.cancelled
        }
        defer { lease.release() }

        do {
            return try await lease.withStoreParentDescriptor { parentFD in
                try checkCancellation()
                let provider = VerifiedParakeetSourceSnapshotProvider(store: store)
                if (try? await provider.makeVerifiedSnapshot(holding: lease)) != nil {
                    return store.parent.appendingPathComponent(store.sourceDirectoryName, isDirectory: true)
                }

                let stagingName = try uniqueName(prefix: ParakeetSourceStore.stagingPrefix)
                try createDirectory(named: stagingName, relativeTo: parentFD)
                var stagingExists = true
                defer {
                    if stagingExists, isOwnedArtifactName(stagingName, prefix: ParakeetSourceStore.stagingPrefix) {
                        try? removeTree(named: stagingName, relativeTo: parentFD)
                    }
                }

                do {
                    let stagingFD = try openDirectory(named: stagingName, relativeTo: parentFD)
                    defer { _ = Darwin.close(stagingFD) }
                    for entry in store.entries {
                        try checkCancellation()
                        let sinkFD = try openArtifactSink(entry: entry, rootFD: stagingFD)
                        let sink = ParakeetSourceArtifactSink(descriptor: sinkFD, entry: entry)
                        do {
                            try await materializer.materialize(entry: entry, sink: sink)
                            try checkCancellation()
                            try sink.finish()
                        } catch {
                            throw map(error)
                        }
                    }
                    try checkCancellation()
                    try writeMarker(rootFD: stagingFD)
                    try checkCancellation()
                    beforeValidation?()
                    try checkCancellation()
                    do {
                        let stagingStore = ParakeetSourceStore(parent: store.parent, sourceDirectoryName: stagingName,
                                                               entries: store.entries, identity: store.identity)
                        let stagingProvider = VerifiedParakeetSourceSnapshotProvider(store: stagingStore)
                        _ = try await stagingProvider.makeVerifiedSnapshot(holding: lease)
                    } catch {
                        throw ParakeetSourcePreparationError.validationFailed
                    }
                    try checkCancellation()
                    beforeActivation?()
                    try checkCancellation()
                    try activate(stagingName: stagingName, sourceName: store.sourceDirectoryName, parentFD: parentFD)
                    stagingExists = false
                    return store.parent.appendingPathComponent(store.sourceDirectoryName, isDirectory: true)
                } catch is CancellationError {
                    throw ParakeetSourcePreparationError.cancelled
                } catch let error as ParakeetSourcePreparationError {
                    throw error
                } catch {
                    throw map(error)
                }
            }
        } catch is CancellationError {
            throw ParakeetSourcePreparationError.cancelled
        }
    }

    private func checkCancellation() throws {
        guard !Task.isCancelled else { throw ParakeetSourcePreparationError.cancelled }
    }

    private func map(_ error: Error) -> ParakeetSourcePreparationError {
        if error is CancellationError || Task.isCancelled { return .cancelled }
        if let error = error as? ParakeetSourcePreparationError { return error }
        if let error = error as? ParakeetSourceSnapshotError {
            if error == .cancelled { return .cancelled }
            return .validationFailed
        }
        return .activationFailed
    }

    private func validateConfiguration() throws {
        guard !store.sourceDirectoryName.isEmpty,
              !store.sourceDirectoryName.contains("/"),
              store.sourceDirectoryName != ".", store.sourceDirectoryName != "..",
              !store.sourceDirectoryName.utf8.contains(0),
              store.sourceDirectoryName != ParakeetModelDownloader.folderName,
              !store.sourceDirectoryName.hasPrefix(ParakeetSourceStore.stagingPrefix),
              !store.sourceDirectoryName.hasPrefix(ParakeetSourceStore.backupPrefix) else {
            throw ParakeetSourcePreparationError.invalidPath(store.sourceDirectoryName)
        }
        guard store.entries.count == 9, Set(store.entries.map(\.path)).count == store.entries.count else {
            throw ParakeetSourcePreparationError.invalidManifest
        }
        var aggregate: Int64 = 0
        for entry in store.entries {
            guard entry.size > 0, entry.sha256.count == 64,
                  entry.sha256.allSatisfy({ $0.isNumber || ("a"..."f").contains($0) }) else {
                throw ParakeetSourcePreparationError.invalidManifest
            }
            _ = try pathComponents(entry.path)
            let result = aggregate.addingReportingOverflow(entry.size)
            guard !result.overflow else { throw ParakeetSourcePreparationError.invalidManifest }
            aggregate = result.partialValue
        }
        let sourceEntries = store.entries.filter { $0.role == "specification" || $0.role == "weights" }
        let vocabularyEntries = store.entries.filter { $0.role == "vocabulary" }
        guard sourceEntries.count == 8, vocabularyEntries.count == 1,
              vocabularyEntries[0].component == "Vocabulary",
              vocabularyEntries[0].path == "parakeet_vocab.json",
              sourceEntries.allSatisfy({ entry in
                  guard let component = ParakeetSourceComponent(rawValue: entry.component),
                        entry.role == "specification" || entry.role == "weights" else { return false }
                  let suffix = entry.role == "specification" ? "model.mlmodel" : "weights/weight.bin"
                  return entry.path == "mlpackages/\(component.rawValue).mlpackage/Data/com.apple.CoreML/\(suffix)"
              }) else { throw ParakeetSourcePreparationError.invalidManifest }
    }

    private func pathComponents(_ path: String) throws -> [String] {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.utf8.contains(0) else {
            throw ParakeetSourcePreparationError.invalidPath(path)
        }
        let result = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard result.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.utf8.contains(0) }) else {
            throw ParakeetSourcePreparationError.invalidPath(path)
        }
        return result
    }

    private func uniqueName(prefix: String) throws -> String {
        let uuid = UUID().uuidString
        guard UUID(uuidString: uuid) != nil else { throw ParakeetSourcePreparationError.invalidManifest }
        return prefix + uuid
    }

    private func createDirectory(named name: String, relativeTo parentFD: Int32) throws {
        guard mkdirat(parentFD, name, mode_t(0o700)) == 0 else {
            throw errno == EEXIST ? ParakeetSourcePreparationError.collision(name) : .io(errno)
        }
        let fd = try openDirectory(named: name, relativeTo: parentFD)
        guard fchmod(fd, mode_t(0o700)) == 0 else {
            let code = errno
            _ = Darwin.close(fd)
            throw ParakeetSourcePreparationError.io(code)
        }
        _ = Darwin.close(fd)
    }

    private func openDirectory(named name: String, relativeTo parentFD: Int32) throws -> Int32 {
        let fd = name.withCString { openat(parentFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else { throw ParakeetSourcePreparationError.io(errno) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(), UInt16(info.st_mode & 0o777) == 0o700 else {
            _ = Darwin.close(fd)
            throw ParakeetSourcePreparationError.invalidTree
        }
        return fd
    }

    private func openArtifactSink(entry: GeneratedParakeetManifestEntry, rootFD: Int32) throws -> Int32 {
        let components = try pathComponents(entry.path)
        var currentFD = rootFD
        var opened: [Int32] = []
        defer { for fd in opened.reversed() { _ = Darwin.close(fd) } }
        for component in components.dropLast() {
            let child: Int32
            if mkdirat(currentFD, component, mode_t(0o700)) == 0 {
                child = try openDirectory(named: component, relativeTo: currentFD)
                _ = fchmod(child, mode_t(0o700))
            } else if errno == EEXIST {
                child = try openDirectory(named: component, relativeTo: currentFD)
            } else {
                throw ParakeetSourcePreparationError.io(errno)
            }
            guard fchmod(child, mode_t(0o700)) == 0 else {
                let code = errno
                _ = Darwin.close(child)
                throw ParakeetSourcePreparationError.io(code)
            }
            opened.append(child)
            currentFD = child
        }
        let filename = components.last!
        let fd = filename.withCString { openat(currentFD, $0, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600)) }
        guard fd >= 0 else { throw errno == EEXIST ? ParakeetSourcePreparationError.collision(entry.path) : .io(errno) }
        guard fchmod(fd, mode_t(0o600)) == 0 else {
            let code = errno
            _ = Darwin.close(fd)
            throw ParakeetSourcePreparationError.io(code)
        }
        return fd
    }

    private func writeMarker(rootFD: Int32) throws {
        let data = try markerData()
        let fd = ParakeetSourceStore.identityMarkerName.withCString {
            openat(rootFD, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        }
        guard fd >= 0 else { throw ParakeetSourcePreparationError.io(errno) }
        guard fchmod(fd, mode_t(0o600)) == 0 else {
            let code = errno
            _ = Darwin.close(fd)
            throw ParakeetSourcePreparationError.io(code)
        }
        defer { _ = Darwin.close(fd) }
        var offset = 0
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            while offset < data.count {
                let count = Darwin.write(fd, base.advanced(by: offset), data.count - offset)
                if count < 0 { if errno == EINTR { continue }; throw ParakeetSourcePreparationError.io(errno) }
                guard count > 0 else { throw ParakeetSourcePreparationError.io(EIO) }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw ParakeetSourcePreparationError.io(errno) }
    }

    private func markerData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(store.identity)
        guard data.count <= 16 * 1024 else { throw ParakeetSourcePreparationError.invalidManifest }
        return data
    }

    private func activate(stagingName: String, sourceName: String, parentFD: Int32) throws {
        let backupName = try uniqueName(prefix: ParakeetSourceStore.backupPrefix)
        let sourceExists = entryExists(named: sourceName, relativeTo: parentFD)
        if sourceExists {
            try renameExclusively(from: sourceName, to: backupName, relativeTo: parentFD)
        }
        guard !entryExists(named: sourceName, relativeTo: parentFD) else {
            throw ParakeetSourcePreparationError.collision(sourceName)
        }
        do {
            try renameExclusively(from: stagingName, to: sourceName, relativeTo: parentFD)
        } catch {
            if sourceExists { try? renameExclusively(from: backupName, to: sourceName, relativeTo: parentFD) }
            throw ParakeetSourcePreparationError.activationFailed
        }
        if sourceExists {
            // Activation is committed. Cleanup failure is intentionally
            // non-fatal; stale backup recovery belongs to the next writer.
            try? removeTree(named: backupName, relativeTo: parentFD)
        }
    }

    private func renameExclusively(from: String, to: String, relativeTo parentFD: Int32) throws {
        let result = from.withCString { source in
            to.withCString { destination in
                renameatx_np(parentFD, source, parentFD, destination, UInt32(RENAME_EXCL))
            }
        }
        guard result == 0 else {
            if errno == EEXIST { throw ParakeetSourcePreparationError.collision(to) }
            throw ParakeetSourcePreparationError.activationFailed
        }
    }

    private func isOwnedArtifactName(_ name: String, prefix: String) -> Bool {
        guard name.hasPrefix(prefix) else { return false }
        return UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
    }

    private func ensureAbsent(named name: String, relativeTo fd: Int32) throws {
        guard !entryExists(named: name, relativeTo: fd) else { throw ParakeetSourcePreparationError.collision(name) }
    }

    private func entryExists(named name: String, relativeTo fd: Int32) -> Bool {
        var info = stat()
        return name.withCString { fstatat(fd, $0, &info, AT_SYMLINK_NOFOLLOW) == 0 }
    }

    private func removeTree(named name: String, relativeTo parentFD: Int32) throws {
        guard entryExists(named: name, relativeTo: parentFD) else { return }
        let fd = try openDirectory(named: name, relativeTo: parentFD)
        defer { _ = Darwin.close(fd) }
        let listingFD = dup(fd)
        guard listingFD >= 0, let directory = fdopendir(listingFD) else { throw ParakeetSourcePreparationError.io(errno) }
        defer { closedir(directory) }
        while let item = readdir(directory) {
            let child = withUnsafePointer(to: item.pointee.d_name) { String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) }
            guard child != ".", child != ".." else { continue }
            var info = stat()
            guard child.withCString({ fstatat(fd, $0, &info, AT_SYMLINK_NOFOLLOW) == 0 }) else { throw ParakeetSourcePreparationError.io(errno) }
            if (info.st_mode & S_IFMT) == S_IFDIR {
                try removeTree(named: child, relativeTo: fd)
            } else {
                let type = info.st_mode & S_IFMT
                guard type == S_IFREG || type == S_IFLNK else { throw ParakeetSourcePreparationError.invalidTree }
                guard child.withCString({ unlinkat(fd, $0, 0) == 0 }) else { throw ParakeetSourcePreparationError.io(errno) }
            }
        }
        guard name.withCString({ unlinkat(parentFD, $0, AT_REMOVEDIR) == 0 }) else { throw ParakeetSourcePreparationError.io(errno) }
    }
}
