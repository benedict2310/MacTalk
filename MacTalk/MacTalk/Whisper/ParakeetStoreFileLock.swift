import Darwin
import Foundation

/// Coordinates cooperating MacTalk processes while they mutate or snapshot the
/// Parakeet store. This is an advisory kernel lock: it does not protect
/// against a hostile same-UID process that ignores the lock.
struct ParakeetStoreFileLock: Sendable {
    enum Mode: Sendable {
        case shared
        case exclusive
    }

    enum LockError: Error, Equatable, Sendable, CustomStringConvertible {
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

        var description: String {
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

    final class Lease: @unchecked Sendable {
        let mode: Mode
        private let stateLock = NSLock()
        private var fileDescriptor: Int32?
        private var storeParentDescriptor: Int32?

        fileprivate init(fileDescriptor: Int32, storeParentDescriptor: Int32, mode: Mode) {
            self.fileDescriptor = fileDescriptor
            self.storeParentDescriptor = storeParentDescriptor
            self.mode = mode
        }

        /// Borrows the validated parent directory descriptor while holding the
        /// lease state lock. Release cannot close the descriptor until this
        /// synchronous borrow returns.
        func withStoreParentDescriptor<T>(_ body: (Int32) throws -> T) rethrows -> T {
            stateLock.lock()
            defer { stateLock.unlock() }
            guard let descriptor = storeParentDescriptor else {
                preconditionFailure("store lock lease has been released")
            }
            return try body(descriptor)
        }

        /// Releases the kernel lease exactly once. Calling this method more than
        /// once is safe; deinitialization also releases an unreleased lease.
        func release() {
            stateLock.lock()
            guard let fd = fileDescriptor else {
                stateLock.unlock()
                return
            }
            fileDescriptor = nil
            let parentFD = storeParentDescriptor
            storeParentDescriptor = nil
            stateLock.unlock()
            _ = flock(fd, LOCK_UN)
            _ = close(fd)
            if let parentFD { _ = close(parentFD) }
        }

        deinit { release() }
    }

    let storeParent: URL
    private let afterParentValidation: (@Sendable () -> Void)?
    private let afterComponentOpened: (@Sendable (String) -> Void)?

    init(storeParent: URL) {
        self.storeParent = storeParent
        self.afterParentValidation = nil
        self.afterComponentOpened = nil
    }

    init(storeParent: URL, afterParentValidation: (@Sendable () -> Void)?, afterComponentOpened: (@Sendable (String) -> Void)? = nil) {
        self.storeParent = storeParent
        self.afterParentValidation = afterParentValidation
        self.afterComponentOpened = afterComponentOpened
    }

    /// Attempts one nonblocking acquisition. A nil result proves that the
    /// kernel rejected this exact lock descriptor with EAGAIN/EWOULDBLOCK.
    func tryAcquire(_ mode: Mode) throws -> Lease? {
        let descriptors = try openValidatedLockDescriptor()
        let parentFD = descriptors.0
        let fd = descriptors.1
        let operation: Int32 = mode == .shared ? LOCK_SH | LOCK_NB : LOCK_EX | LOCK_NB
        while true {
            guard flock(fd, operation) != 0 else {
                return Lease(fileDescriptor: fd, storeParentDescriptor: parentFD, mode: mode)
            }
            let code = errno
            if code == EINTR { continue }
            _ = close(fd)
            _ = close(parentFD)
            if code == EAGAIN || code == EWOULDBLOCK {
                return nil
            }
            throw LockError.flockFailed(code)
        }
    }

    func acquire(_ mode: Mode) async throws -> Lease {
        let descriptors = try openValidatedLockDescriptor()
        let parentFD = descriptors.0
        let fd = descriptors.1
        var closeOnExit = true
        defer {
            if closeOnExit {
                _ = close(fd)
                _ = close(parentFD)
            }
        }

        let operation: Int32 = mode == .shared ? LOCK_SH | LOCK_NB : LOCK_EX | LOCK_NB
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
                return Lease(fileDescriptor: fd, storeParentDescriptor: parentFD, mode: mode)
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

    private func openValidatedLockDescriptor() throws -> (Int32, Int32) {
        let parentFD = try openStoreParentDirectory()
        do {
            let lockFD = try openLockFile(parentFD: parentFD)
            return (parentFD, lockFD)
        } catch {
            _ = close(parentFD)
            throw error
        }
    }

    private func openStoreParentDirectory() throws -> Int32 {
        let components = try normalizedStoreComponents()
        var currentFD = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard currentFD >= 0 else { throw LockError.openFailed(errno) }
        defer {
            if currentFD >= 0 { _ = close(currentFD) }
        }
        let systemPrefix = components.count >= 2 && components[0] == "private" && (components[1] == "tmp" || components[1] == "var") ? 2 : (components.first == "private" ? 1 : 0)

        for (index, component) in components.enumerated() {
            let nextFD = try openOrCreateDirectory(component, relativeTo: currentFD)
            _ = close(currentFD)
            currentFD = nextFD
            try validateDirectoryDescriptor(currentFD, enforcePrivateMode: index == components.count - 1, systemComponent: index < systemPrefix && index < components.count - 1)
            afterComponentOpened?(component)
        }
        afterParentValidation?()
        let result = currentFD
        currentFD = -1
        return result
    }

    private func normalizedStoreComponents() throws -> [String] {
        guard storeParent.isFileURL, storeParent.path.hasPrefix("/") else {
            throw LockError.invalidStoreParent
        }
        let raw = storeParent.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !raw.isEmpty, !raw.contains(where: { $0 == "." || $0 == ".." }) else {
            throw LockError.invalidStoreParent
        }
        if raw.first == "tmp" || raw.first == "var" {
            return ["private"] + raw
        }
        return raw
    }

    private func openOrCreateDirectory(_ component: String, relativeTo parentFD: Int32) throws -> Int32 {
        let flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        var fd = openat(parentFD, component, flags)
        if fd < 0 && errno == ENOENT {
            guard mkdirat(parentFD, component, mode_t(0o700)) == 0 || errno == EEXIST else {
                throw LockError.openFailed(errno)
            }
            fd = openat(parentFD, component, flags)
        }
        guard fd >= 0 else {
            let code = errno
            throw code == ELOOP || code == ENOTDIR ? LockError.storeParentNotDirectory : LockError.openFailed(code)
        }
        return fd
    }

    private func validateDirectoryDescriptor(_ fd: Int32, enforcePrivateMode: Bool, systemComponent: Bool) throws {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw LockError.statFailed(errno) }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { throw LockError.storeParentNotDirectory }
        guard enforcePrivateMode, !systemComponent else { return }
        guard info.st_uid == getuid() else { throw LockError.storeParentWrongOwner }
        let permissions = UInt16(info.st_mode & 0o777)
        if permissions != 0o700 {
            guard fchmod(fd, mode_t(0o700)) == 0 else { throw LockError.openFailed(errno) }
            guard fstat(fd, &info) == 0 else { throw LockError.statFailed(errno) }
            guard UInt16(info.st_mode & 0o777) == 0o700 else { throw LockError.storeParentWrongPermissions(UInt16(info.st_mode & 0o777)) }
        }
    }

    private func openLockFile(parentFD: Int32) throws -> Int32 {
        var fd: Int32 = -1
        var lastError: Int32 = ENOENT
        for _ in 0..<100 {
            fd = openat(parentFD, ".mactalk-store.lock", O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, mode_t(0o600))
            if fd >= 0 { break }
            lastError = errno
            if lastError != ENOENT {
                break
            }
            usleep(1_000)
        }
        guard fd >= 0 else {
            if lastError == ELOOP { throw LockError.lockPathIsSymlink }
            throw LockError.openFailed(lastError)
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
