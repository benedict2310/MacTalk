import Foundation
import CryptoKit
import Darwin

/// Validates downloaded model bytes before they can enter the model store.
/// The checksum is mandatory: an absent or malformed digest is never treated as
/// an opt-out, because the result is loaded by native inference code.
enum ModelIntegrityVerifier {
    private static let testHookLock = NSLock()
    nonisolated(unsafe) private static var testBeforeCommitHook: (@Sendable (ModelSpec) -> Void)?
    nonisolated(unsafe) private static var testCommitDecisionHook: (@Sendable (ModelSpec, Bool) -> Void)?

    /// Installs a deterministic test barrier immediately before destination mutation.
    /// Production callers never install this hook.
    static func setTestBeforeCommitHook(_ hook: (@Sendable (ModelSpec) -> Void)?) {
        testHookLock.lock()
        testBeforeCommitHook = hook
        testHookLock.unlock()
    }

    static func runTestBeforeCommitHook(for spec: ModelSpec) {
        testHookLock.lock()
        let hook = testBeforeCommitHook
        testHookLock.unlock()
        hook?(spec)
    }

    static func setTestCommitDecisionHook(_ hook: (@Sendable (ModelSpec, Bool) -> Void)?) {
        testHookLock.lock()
        testCommitDecisionHook = hook
        testHookLock.unlock()
    }

    static func runTestCommitDecisionHook(for spec: ModelSpec, accepted: Bool) {
        testHookLock.lock()
        let hook = testCommitDecisionHook
        testHookLock.unlock()
        hook?(spec, accepted)
    }

    /// Opens the artifact without following a symlink and validates that exact
    /// open object. The descriptor remains usable by the native loader, which
    /// prevents a path replacement between validation and initialization.
    static func openValidated(source: URL, spec: ModelSpec) throws -> Int32 {
        guard isValidDigest(spec.sha256), spec.sizeBytes > 0 else {
            throw ModelDownloader.ErrorType.badChecksum
        }
        let fd = open(source.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw ModelDownloader.ErrorType.badChecksum }
        do {
            var info = stat()
            guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                  Int64(info.st_size) == spec.sizeBytes else {
                throw ModelDownloader.ErrorType.badChecksum
            }
            guard try hashFileDescriptor(fd) == spec.sha256 else {
                throw ModelDownloader.ErrorType.badChecksum
            }
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    private static func hashFileDescriptor(_ fd: Int32) throws -> String {
        guard lseek(fd, 0, SEEK_SET) >= 0 else { throw ModelDownloader.ErrorType.badChecksum }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            let count = buffer.withUnsafeMutableBytes { raw in
                read(fd, raw.baseAddress, raw.count)
            }
            if count < 0 { throw ModelDownloader.ErrorType.badChecksum }
            if count == 0 { break }
            hasher.update(data: Data(buffer[0..<count]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func validate(source: URL, spec: ModelSpec) throws {
        guard isValidDigest(spec.sha256) else {
            throw ModelDownloader.ErrorType.badChecksum
        }

        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
            guard let size = (attributes[.size] as? NSNumber)?.int64Value else {
                throw ModelDownloader.ErrorType.badChecksum
            }

            // Size is part of the immutable artifact identity. Never accept a
            // rounded/provider size or an existence-only cache entry.
            guard size == spec.sizeBytes else {
                throw ModelDownloader.ErrorType.badChecksum
            }

            let actualDigest = try SHA256Streamer.hashFile(at: source)
            guard actualDigest == spec.sha256 else {
                throw ModelDownloader.ErrorType.badChecksum
            }
        } catch let error as ModelDownloader.ErrorType {
            throw error
        } catch {
            throw ModelDownloader.ErrorType.badChecksum
        }
    }

    /// Verify first, then atomically install the file. A failed source is
    /// always removed, while an existing destination remains untouched until
    /// verification has completed successfully.
    static func verifyAndMove(source: URL, destination: URL, spec: ModelSpec) throws {
        var installed = false
        defer {
            if !installed {
                try? FileManager.default.removeItem(at: source)
            }
        }

        try validate(source: source, spec: spec)
        runTestBeforeCommitHook(for: spec)
        try commitVerified(source: source, destination: destination, spec: spec)
        installed = true
    }

    /// Installs bytes that the caller has already verified. This method is
    /// intentionally limited to the short destination mutation; hashing and
    /// generation checks belong outside this operation's commit lock.
    static func commitVerified(source: URL, destination: URL, spec: ModelSpec) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)

        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: source,
                                              backupItemName: nil,
                                              options: .usingNewMetadataOnly)
        } else {
            try fileManager.moveItem(at: source, to: destination)
        }
    }

    static func isValidDigest(_ digest: String) -> Bool {
        guard digest.utf8.count == 64 else { return false }
        return digest.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
        }
    }
}
