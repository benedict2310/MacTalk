import Darwin
import Foundation

/// Coordinates cooperating MacTalk processes while they mutate or snapshot the
/// Parakeet store. This is an advisory kernel lock: it does not protect
/// against a hostile same-UID process that ignores the lock.
public struct ParakeetStoreFileLock: Sendable {
    public enum Mode: Sendable {
        case shared
        case exclusive
    }

    public enum LockError: Error, Equatable, Sendable, CustomStringConvertible {
        case invalidStoreParent
        case storeParentNotDirectory
        case storeParentWrongOwner
        case storeParentWrongPermissions(UInt16)
        case lockPathWrongOwner
        case lockPathWrongPermissions(UInt16)
        case lockPathNotRegular
        case lockPathIsSymlink
        case openFailed(Int32)
        case statFailed(Int32)
        case flockFailed(Int32)

        public var description: String {
            switch self {
            case .invalidStoreParent: return "store parent must be a file URL"
            case .storeParentNotDirectory: return "store parent is not a directory"
            case .storeParentWrongOwner: return "store parent is not owned by the current user"
            case let .storeParentWrongPermissions(mode): return String(format: "store parent permissions are %04o, expected 0700", mode)
            case .lockPathWrongOwner: return "lock file is not owned by the current user"
            case let .lockPathWrongPermissions(mode): return String(format: "lock file permissions are %04o, expected 0600", mode)
            case .lockPathNotRegular: return "lock path is not a regular file"
            case .lockPathIsSymlink: return "lock path is a symlink"
            case let .openFailed(code): return "opening lock file failed with errno \(code)"
            case let .statFailed(code): return "stating lock path failed with errno \(code)"
            case let .flockFailed(code): return "flock failed with errno \(code)"
            }
        }
    }

    public final class Lease: @unchecked Sendable {
        public let mode: Mode
        private let stateLock = NSLock()
        private var fileDescriptor: Int32?

        fileprivate init(fileDescriptor: Int32, mode: Mode) {
            self.fileDescriptor = fileDescriptor
            self.mode = mode
        }

        /// Releases the kernel lease exactly once. Calling this method more than
        /// once is safe; deinitialization also releases an unreleased lease.
        public func release() {
            stateLock.lock()
            guard let fd = fileDescriptor else {
                stateLock.unlock()
                return
            }
            fileDescriptor = nil
            stateLock.unlock()
            _ = flock(fd, LOCK_UN)
            _ = close(fd)
        }

        deinit { release() }
    }

    public let storeParent: URL
    private let lockURL: URL

    public init(storeParent: URL) {
        self.storeParent = storeParent
        self.lockURL = storeParent.appendingPathComponent(".mactalk-store.lock", isDirectory: false)
    }

    public func acquire(_ mode: Mode) async throws -> Lease {
        let parentFD = try openStoreParentDirectory()
        defer { _ = close(parentFD) }
        let fd = try openLockFile(parentFD: parentFD)
        var closeOnExit = true
        defer {
            if closeOnExit { _ = close(fd) }
        }

        let operation: Int32
        switch mode {
        case .shared: operation = LOCK_SH | LOCK_NB
        case .exclusive: operation = LOCK_EX | LOCK_NB
        }
        while true {
            try Task.checkCancellation()
            if flock(fd, operation) == 0 {
                do {
                    try Task.checkCancellation()
                } catch {
                    _ = flock(fd, LOCK_UN)
                    throw error
                }
                closeOnExit = false
                return Lease(fileDescriptor: fd, mode: mode)
            }

            let code = errno
            if code == EINTR {
                continue
            }
            if code == EAGAIN || code == EWOULDBLOCK {
                try await Task.sleep(for: .milliseconds(25))
                continue
            }
            throw LockError.flockFailed(code)
        }
    }

    private func openStoreParentDirectory() throws -> Int32 {
        guard storeParent.isFileURL, storeParent.path.hasPrefix("/") else {
            throw LockError.invalidStoreParent
        }
        try rejectSymlinkedStorePathComponents()
        var info = stat()
        if lstat(storeParent.path, &info) != 0 {
            guard errno == ENOENT else { throw LockError.statFailed(errno) }
            do {
                try FileManager.default.createDirectory(at: storeParent, withIntermediateDirectories: true)
            } catch {
                throw LockError.openFailed(EIO)
            }
        }
        let directoryFD = open(storeParent.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard directoryFD >= 0 else {
            let code = errno
            throw code == ELOOP ? LockError.storeParentNotDirectory : LockError.openFailed(code)
        }

        guard fstat(directoryFD, &info) == 0 else {
            let code = errno
            _ = close(directoryFD)
            throw LockError.statFailed(code)
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else {
            _ = close(directoryFD)
            throw LockError.storeParentNotDirectory
        }
        guard info.st_uid == getuid() else {
            _ = close(directoryFD)
            throw LockError.storeParentWrongOwner
        }
        let permissions = UInt16(info.st_mode & 0o777)
        guard permissions == 0o700 else {
            _ = close(directoryFD)
            throw LockError.storeParentWrongPermissions(permissions)
        }
        return directoryFD
    }

    private func rejectSymlinkedStorePathComponents() throws {
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        let components = storeParent.path.split(separator: "/", omittingEmptySubsequences: true)
        for (index, component) in components.enumerated() {
            current.appendPathComponent(String(component), isDirectory: true)
            var info = stat()
            guard lstat(current.path, &info) == 0 else {
                guard errno == ENOENT else { throw LockError.statFailed(errno) }
                return
            }
            if (info.st_mode & S_IFMT) == S_IFLNK {
                // macOS exposes /var and /tmp as system symlinks to /private;
                // reject all caller-controlled symlink components.
                if index == 0 && (component == "var" || component == "tmp") {
                    continue
                }
                throw LockError.storeParentNotDirectory
            }
        }
    }

    private func openLockFile(parentFD: Int32) throws -> Int32 {
        _ = parentFD
        let fd = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, mode_t(0o600))
        guard fd >= 0 else {
            if errno == ELOOP { throw LockError.lockPathIsSymlink }
            throw LockError.openFailed(errno)
        }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            let code = errno
            _ = close(fd)
            throw LockError.statFailed(code)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            _ = close(fd)
            throw LockError.lockPathNotRegular
        }
        guard info.st_uid == getuid() else {
            _ = close(fd)
            throw LockError.lockPathWrongOwner
        }
        let permissions = UInt16(info.st_mode & 0o777)
        guard permissions == 0o600 else {
            _ = close(fd)
            throw LockError.lockPathWrongPermissions(permissions)
        }
        return fd
    }
}
