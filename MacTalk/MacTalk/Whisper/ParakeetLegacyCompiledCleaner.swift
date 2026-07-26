import CryptoKit
import Darwin
import Foundation

enum ParakeetLegacyCompiledCleanupError: Error, Equatable, Sendable {
    case invalidCompiledTree
    case io(Int32)
    case cancelled
}

/// Removes only a fully validated legacy compiled generation under the shared
/// inter-process store lock. Validation completes before the first unlink.
final class ParakeetLegacyCompiledCleaner: ParakeetBootstrapLegacyCleaning, @unchecked Sendable {
    private struct ManifestIdentity: Codable, Equatable {
        let repository: String
        let revision: String
        let files: [ParakeetManifestEntry]
    }

    private struct ValidatedTree {
        let info: stat
        let expectedFiles: [String: ParakeetManifestEntry]
        let expectedDirectories: Set<String>
        let expectedManifest: ManifestIdentity
    }

    private static let quarantineName = ".mactalk-legacy-compiled-retired"

    private let parent: URL
    private let entries: [ParakeetManifestEntry]
    private let repository: String
    private let revision: String
    private let beforeRemoval: (@Sendable () -> Void)?

    init(
        parent: URL,
        entries: [ParakeetManifestEntry] = ParakeetModelDownloader.manifest,
        repository: String = ParakeetModelDownloader.repository,
        revision: String = ParakeetModelDownloader.revision,
        beforeRemoval: (@Sendable () -> Void)? = nil
    ) {
        self.parent = parent
        self.entries = entries
        self.repository = repository
        self.revision = revision
        self.beforeRemoval = beforeRemoval
    }

    func removeCompiledGeneration() async throws {
        try checkCancellation()
        let lock = ParakeetStoreFileLock(storeParent: parent)
        let lease: ParakeetStoreFileLock.Lease
        do {
            lease = try await lock.acquire(.exclusive)
        } catch is CancellationError {
            throw ParakeetLegacyCompiledCleanupError.cancelled
        }
        defer { lease.release() }
        try lease.withStoreParentDescriptor { parentFD in
            try checkCancellation()
            try validateConfiguration()

            // Recover a prior interruption only through the one fixed private
            // quarantine name. It must still validate exactly before removal.
            if let quarantined = try validateTreeIfPresent(named: Self.quarantineName, relativeTo: parentFD) {
                try removeValidatedTree(named: Self.quarantineName, relativeTo: parentFD, validated: quarantined)
            }

            let activeName = ParakeetModelDownloader.folderName
            guard let initiallyValidated = try validateTreeIfPresent(named: activeName, relativeTo: parentFD) else { return }
            beforeRemoval?()
            // Catch cooperative/test mutation before the atomic ownership move.
            guard let finalValidated = try validateTreeIfPresent(named: activeName, relativeTo: parentFD),
                  sameIdentity(initiallyValidated.info, finalValidated.info) else {
                throw ParakeetLegacyCompiledCleanupError.invalidCompiledTree
            }
            let renamed = activeName.withCString { source in
                Self.quarantineName.withCString { destination in
                    renameatx_np(parentFD, source, parentFD, destination, UInt32(RENAME_EXCL))
                }
            }
            guard renamed == 0, fsync(parentFD) == 0 else {
                throw ParakeetLegacyCompiledCleanupError.io(errno)
            }
            guard let quarantined = try validateTreeIfPresent(named: Self.quarantineName, relativeTo: parentFD),
                  sameIdentity(finalValidated.info, quarantined.info) else {
                throw ParakeetLegacyCompiledCleanupError.invalidCompiledTree
            }
            try removeValidatedTree(named: Self.quarantineName, relativeTo: parentFD, validated: quarantined)
            guard fsync(parentFD) == 0 else { throw ParakeetLegacyCompiledCleanupError.io(errno) }
        }
    }

    private func validateTreeIfPresent(named name: String, relativeTo parentFD: Int32) throws -> ValidatedTree? {
        var pathInfo = stat()
        let status = name.withCString { fstatat(parentFD, $0, &pathInfo, AT_SYMLINK_NOFOLLOW) }
        if status != 0 {
            if errno == ENOENT { return nil }
            throw ParakeetLegacyCompiledCleanupError.io(errno)
        }
        guard (pathInfo.st_mode & S_IFMT) == S_IFDIR, pathInfo.st_uid == getuid() else {
            throw ParakeetLegacyCompiledCleanupError.invalidCompiledTree
        }
        let directoryFD = try openValidatedDirectory(named: name, relativeTo: parentFD, expected: pathInfo)
        defer { _ = Darwin.close(directoryFD) }
        let expectedFiles = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) })
        let expectedDirectories = Set(entries.flatMap { entry -> [String] in
            let components = entry.path.split(separator: "/").dropLast()
            return components.indices.map { index in components[...index].joined(separator: "/") }
        })
        var seen = Set<String>()
        let marker = try validateTree(directoryFD: directoryFD, prefix: "", expectedFiles: expectedFiles,
                                      expectedDirectories: expectedDirectories, seen: &seen)
        let expectedManifest = ManifestIdentity(repository: repository, revision: revision, files: entries)
        guard marker == expectedManifest,
              seen == Set(expectedFiles.keys).union([".mactalk-manifest.json"]) else {
            throw ParakeetLegacyCompiledCleanupError.invalidCompiledTree
        }
        return ValidatedTree(info: pathInfo, expectedFiles: expectedFiles,
                             expectedDirectories: expectedDirectories, expectedManifest: expectedManifest)
    }

    private func validateConfiguration() throws {
        guard !entries.isEmpty, Set(entries.map(\.path)).count == entries.count else {
            throw ParakeetLegacyCompiledCleanupError.invalidCompiledTree
        }
        for entry in entries {
            let components = entry.path.split(separator: "/", omittingEmptySubsequences: false)
            guard !entry.path.hasPrefix("/"), !components.isEmpty,
                  components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  entry.size >= 0, entry.sha256.count == 64 else {
                throw ParakeetLegacyCompiledCleanupError.invalidCompiledTree
            }
        }
    }

    private func validateTree(
        directoryFD: Int32,
        prefix: String,
        expectedFiles: [String: ParakeetManifestEntry],
        expectedDirectories: Set<String>,
        seen: inout Set<String>
    ) throws -> ManifestIdentity? {
        var marker: ManifestIdentity?
        let listingFD = dup(directoryFD)
        guard listingFD >= 0, let directory = fdopendir(listingFD) else {
            if listingFD >= 0 { _ = Darwin.close(listingFD) }
            throw ParakeetLegacyCompiledCleanupError.io(errno)
        }
        defer { closedir(directory) }
        while let item = readdir(directory) {
            try checkCancellation()
            let name = withUnsafePointer(to: item.pointee.d_name) {
                String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
            }
            guard name != ".", name != ".." else { continue }
            let path = prefix.isEmpty ? name : "\(prefix)/\(name)"
            var info = stat()
            guard name.withCString({ fstatat(directoryFD, $0, &info, AT_SYMLINK_NOFOLLOW) == 0 }),
                  info.st_uid == getuid() else {
                throw ParakeetLegacyCompiledCleanupError.invalidCompiledTree
            }
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                guard expectedDirectories.contains(path) else { throw ParakeetLegacyCompiledCleanupError.invalidCompiledTree }
                let childFD = try openValidatedDirectory(named: name, relativeTo: directoryFD, expected: info)
                defer { _ = Darwin.close(childFD) }
                if let nestedMarker = try validateTree(directoryFD: childFD, prefix: path, expectedFiles: expectedFiles, expectedDirectories: expectedDirectories, seen: &seen) {
                    guard marker == nil else { throw ParakeetLegacyCompiledCleanupError.invalidCompiledTree }
                    marker = nestedMarker
                }
            case S_IFREG:
                guard info.st_nlink == 1, seen.insert(path).inserted else {
                    throw ParakeetLegacyCompiledCleanupError.invalidCompiledTree
                }
                if path == ".mactalk-manifest.json" {
                    let data = try readValidatedFile(named: name, relativeTo: directoryFD, expected: info, maximumSize: 64 * 1024)
                    guard marker == nil, let decoded = try? JSONDecoder().decode(ManifestIdentity.self, from: data) else {
                        throw ParakeetLegacyCompiledCleanupError.invalidCompiledTree
                    }
                    marker = decoded
                } else {
                    guard let entry = expectedFiles[path] else { throw ParakeetLegacyCompiledCleanupError.invalidCompiledTree }
                    try validateArtifactFile(named: name, relativeTo: directoryFD, expected: info, entry: entry)
                }
            default:
                throw ParakeetLegacyCompiledCleanupError.invalidCompiledTree
            }
        }
        return marker
    }

    private func readValidatedFile(named name: String, relativeTo parentFD: Int32, expected: stat, maximumSize: Int) throws -> Data {
        guard expected.st_size >= 0, expected.st_size <= maximumSize else { throw ParakeetLegacyCompiledCleanupError.invalidCompiledTree }
        let fd = name.withCString { openat(parentFD, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK) }
        guard fd >= 0 else { throw ParakeetLegacyCompiledCleanupError.invalidCompiledTree }
        defer { _ = Darwin.close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0, sameIdentity(expected, opened), opened.st_uid == getuid(), opened.st_nlink == 1 else {
            throw ParakeetLegacyCompiledCleanupError.invalidCompiledTree
        }
        let fileSize = Int(opened.st_size)
        var data = Data(count: fileSize)
        var offset = 0
        while offset < fileSize {
            let count = data.withUnsafeMutableBytes { bytes in Darwin.read(fd, bytes.baseAddress!.advanced(by: offset), fileSize - offset) }
            if count < 0 { if errno == EINTR { continue }; throw ParakeetLegacyCompiledCleanupError.io(errno) }
            guard count > 0 else { throw ParakeetLegacyCompiledCleanupError.invalidCompiledTree }
            offset += count
        }
        var trailing: UInt8 = 0
        guard Darwin.read(fd, &trailing, 1) == 0 else { throw ParakeetLegacyCompiledCleanupError.invalidCompiledTree }
        return data
    }

    private func validateArtifactFile(named name: String, relativeTo parentFD: Int32, expected: stat, entry: ParakeetManifestEntry) throws {
        guard expected.st_size == entry.size else { throw ParakeetLegacyCompiledCleanupError.invalidCompiledTree }
        let fd = name.withCString { openat(parentFD, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK) }
        guard fd >= 0 else { throw ParakeetLegacyCompiledCleanupError.invalidCompiledTree }
        defer { _ = Darwin.close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0, sameIdentity(expected, opened), opened.st_uid == getuid(), opened.st_nlink == 1 else {
            throw ParakeetLegacyCompiledCleanupError.invalidCompiledTree
        }
        var hasher = SHA256()
        var total: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while total < entry.size {
            try checkCancellation()
            let count = Darwin.read(fd, &buffer, min(buffer.count, Int(entry.size - total)))
            if count < 0 { if errno == EINTR { continue }; throw ParakeetLegacyCompiledCleanupError.io(errno) }
            guard count > 0 else { throw ParakeetLegacyCompiledCleanupError.invalidCompiledTree }
            hasher.update(data: Data(buffer[0..<count]))
            total += Int64(count)
        }
        var trailing: UInt8 = 0
        guard Darwin.read(fd, &trailing, 1) == 0,
              hasher.finalize().map({ String(format: "%02x", $0) }).joined() == entry.sha256 else {
            throw ParakeetLegacyCompiledCleanupError.invalidCompiledTree
        }
    }

    private func removeValidatedTree(named name: String, relativeTo parentFD: Int32, validated: ValidatedTree) throws {
        try removeValidatedTree(named: name, relativeTo: parentFD, expected: validated.info, prefix: "",
                                expectedFiles: validated.expectedFiles, expectedDirectories: validated.expectedDirectories,
                                expectedManifest: validated.expectedManifest)
    }

    private func removeValidatedTree(
        named name: String,
        relativeTo parentFD: Int32,
        expected: stat,
        prefix: String,
        expectedFiles: [String: ParakeetManifestEntry],
        expectedDirectories: Set<String>,
        expectedManifest: ManifestIdentity
    ) throws {
        let directoryFD = try openValidatedDirectory(named: name, relativeTo: parentFD, expected: expected)
        defer { _ = Darwin.close(directoryFD) }
        let listingFD = dup(directoryFD)
        guard listingFD >= 0, let directory = fdopendir(listingFD) else {
            if listingFD >= 0 { _ = Darwin.close(listingFD) }
            throw ParakeetLegacyCompiledCleanupError.io(errno)
        }
        defer { closedir(directory) }
        while let item = readdir(directory) {
            try checkCancellation()
            let child = withUnsafePointer(to: item.pointee.d_name) {
                String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
            }
            guard child != ".", child != ".." else { continue }
            let path = prefix.isEmpty ? child : "\(prefix)/\(child)"
            var info = stat()
            guard child.withCString({ fstatat(directoryFD, $0, &info, AT_SYMLINK_NOFOLLOW) == 0 }), info.st_uid == getuid() else {
                throw ParakeetLegacyCompiledCleanupError.invalidCompiledTree
            }
            if (info.st_mode & S_IFMT) == S_IFDIR {
                guard expectedDirectories.contains(path) else { throw ParakeetLegacyCompiledCleanupError.invalidCompiledTree }
                try removeValidatedTree(
                    named: child,
                    relativeTo: directoryFD,
                    expected: info,
                    prefix: path,
                    expectedFiles: expectedFiles,
                    expectedDirectories: expectedDirectories,
                    expectedManifest: expectedManifest
                )
            } else {
                guard (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1 else {
                    throw ParakeetLegacyCompiledCleanupError.invalidCompiledTree
                }
                if path == ".mactalk-manifest.json" {
                    let data = try readValidatedFile(named: child, relativeTo: directoryFD, expected: info, maximumSize: 64 * 1024)
                    guard (try? JSONDecoder().decode(ManifestIdentity.self, from: data)) == expectedManifest else {
                        throw ParakeetLegacyCompiledCleanupError.invalidCompiledTree
                    }
                } else {
                    guard let entry = expectedFiles[path] else { throw ParakeetLegacyCompiledCleanupError.invalidCompiledTree }
                    try validateArtifactFile(named: child, relativeTo: directoryFD, expected: info, entry: entry)
                }
                let fd = child.withCString { openat(directoryFD, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK) }
                guard fd >= 0 else { throw ParakeetLegacyCompiledCleanupError.invalidCompiledTree }
                var opened = stat(); var final = stat()
                let valid = fstat(fd, &opened) == 0 && sameIdentity(info, opened) && opened.st_uid == getuid() && opened.st_nlink == 1 &&
                    child.withCString({ fstatat(directoryFD, $0, &final, AT_SYMLINK_NOFOLLOW) == 0 }) && sameIdentity(opened, final)
                _ = Darwin.close(fd)
                guard valid, child.withCString({ unlinkat(directoryFD, $0, 0) == 0 }) else {
                    throw ParakeetLegacyCompiledCleanupError.invalidCompiledTree
                }
            }
        }
        var final = stat()
        guard name.withCString({ fstatat(parentFD, $0, &final, AT_SYMLINK_NOFOLLOW) == 0 }),
              sameIdentity(expected, final),
              name.withCString({ unlinkat(parentFD, $0, AT_REMOVEDIR) == 0 }) else {
            throw ParakeetLegacyCompiledCleanupError.invalidCompiledTree
        }
    }

    private func openValidatedDirectory(named name: String, relativeTo parentFD: Int32, expected: stat) throws -> Int32 {
        let fd = name.withCString { openat(parentFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else { throw ParakeetLegacyCompiledCleanupError.invalidCompiledTree }
        var opened = stat()
        guard fstat(fd, &opened) == 0, sameIdentity(expected, opened), opened.st_uid == getuid() else {
            _ = Darwin.close(fd)
            throw ParakeetLegacyCompiledCleanupError.invalidCompiledTree
        }
        return fd
    }

    private func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && (lhs.st_mode & S_IFMT) == (rhs.st_mode & S_IFMT)
    }

    private func checkCancellation() throws {
        if Task.isCancelled { throw ParakeetLegacyCompiledCleanupError.cancelled }
    }
}
