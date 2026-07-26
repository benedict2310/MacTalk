import Darwin
import Foundation

/// Errors are intentionally narrow: cleanup is post-publication and callers
/// may report/ retry it, but must never revoke a verified source manager.
enum ParakeetLegacyCompiledCleanupError: Error, Equatable, Sendable {
    case invalidCompiledTree
    case io(Int32)
    case cancelled
}

/// Removes only MacTalk's exact legacy compiled generation under the same
/// inter-process store lock used by source activation. Every traversal is
/// descriptor-relative, no links are followed, and pathname identity is
/// rechecked immediately before unlinking.
final class ParakeetLegacyCompiledCleaner: ParakeetBootstrapLegacyCleaning, @unchecked Sendable {
    private let parent: URL

    init(parent: URL) {
        self.parent = parent
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
            try removeTreeIfPresent(named: ParakeetModelDownloader.folderName, relativeTo: parentFD)
        }
    }

    private func removeTreeIfPresent(named name: String, relativeTo parentFD: Int32) throws {
        var pathInfo = stat()
        let status = name.withCString { fstatat(parentFD, $0, &pathInfo, AT_SYMLINK_NOFOLLOW) }
        if status != 0 {
            if errno == ENOENT { return }
            throw ParakeetLegacyCompiledCleanupError.io(errno)
        }
        guard (pathInfo.st_mode & S_IFMT) == S_IFDIR, pathInfo.st_uid == getuid() else {
            throw ParakeetLegacyCompiledCleanupError.invalidCompiledTree
        }

        let directoryFD = name.withCString {
            openat(parentFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard directoryFD >= 0 else { throw ParakeetLegacyCompiledCleanupError.invalidCompiledTree }
        defer { _ = Darwin.close(directoryFD) }
        var openedInfo = stat()
        guard fstat(directoryFD, &openedInfo) == 0,
              sameIdentity(pathInfo, openedInfo),
              openedInfo.st_uid == getuid() else {
            throw ParakeetLegacyCompiledCleanupError.invalidCompiledTree
        }

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
            try removeEntry(named: child, relativeTo: directoryFD)
        }

        var finalInfo = stat()
        guard name.withCString({ fstatat(parentFD, $0, &finalInfo, AT_SYMLINK_NOFOLLOW) == 0 }),
              sameIdentity(openedInfo, finalInfo),
              name.withCString({ unlinkat(parentFD, $0, AT_REMOVEDIR) == 0 }) else {
            throw ParakeetLegacyCompiledCleanupError.invalidCompiledTree
        }
    }

    private func removeEntry(named name: String, relativeTo parentFD: Int32) throws {
        var info = stat()
        guard name.withCString({ fstatat(parentFD, $0, &info, AT_SYMLINK_NOFOLLOW) == 0 }),
              info.st_uid == getuid() else {
            throw ParakeetLegacyCompiledCleanupError.invalidCompiledTree
        }
        switch info.st_mode & S_IFMT {
        case S_IFDIR:
            try removeTreeIfPresent(named: name, relativeTo: parentFD)
        case S_IFREG:
            let fd = name.withCString { openat(parentFD, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK) }
            guard fd >= 0 else { throw ParakeetLegacyCompiledCleanupError.invalidCompiledTree }
            defer { _ = Darwin.close(fd) }
            var opened = stat()
            var final = stat()
            guard fstat(fd, &opened) == 0,
                  sameIdentity(info, opened),
                  opened.st_uid == getuid(),
                  name.withCString({ fstatat(parentFD, $0, &final, AT_SYMLINK_NOFOLLOW) == 0 }),
                  sameIdentity(opened, final),
                  name.withCString({ unlinkat(parentFD, $0, 0) == 0 }) else {
                throw ParakeetLegacyCompiledCleanupError.invalidCompiledTree
            }
        default:
            throw ParakeetLegacyCompiledCleanupError.invalidCompiledTree
        }
    }

    private func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && (lhs.st_mode & S_IFMT) == (rhs.st_mode & S_IFMT)
    }

    private func checkCancellation() throws {
        if Task.isCancelled { throw ParakeetLegacyCompiledCleanupError.cancelled }
    }
}
