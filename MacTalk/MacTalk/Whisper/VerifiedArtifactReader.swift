import CryptoKit
import Darwin
import Foundation

struct VerifiedArtifactBytes: Sendable {
    let identity: GeneratedParakeetManifestEntry
    let data: Data
}

enum VerifiedArtifactReaderError: Error, Equatable, Sendable {
    case invalidPath
    case invalidDigest
    case invalidSize(Int64)
    case sizeTooLarge(Int64)
    case sizeOverflow(Int64)
    case rootNotDirectory
    case openFailed(Int32)
    case statFailed(Int32)
    case notRegularFile
    case sizeMismatch(expected: Int64, actual: Int64)
    case shortRead(expected: Int, actual: Int)
    case readFailed(Int32)
    case cancelled
    case unexpectedTrailingByte
    case checksumMismatch(expected: String, actual: String)
}

/// Reads one manifest entry from an already-open trusted store root. The root
/// descriptor belongs to the caller and is never closed by this type.
struct VerifiedArtifactReader {
    struct TestHooks {
        let afterStat: (() -> Void)?
        let beforeRead: (() -> Void)?
        let afterRead: (() -> Void)?
        let afterVerified: (() -> Void)?

        init(
            afterStat: (() -> Void)? = nil,
            beforeRead: (() -> Void)? = nil,
            afterRead: (() -> Void)? = nil,
            afterVerified: (() -> Void)? = nil
        ) {
            self.afterStat = afterStat
            self.beforeRead = beforeRead
            self.afterRead = afterRead
            self.afterVerified = afterVerified
        }
    }

    private static let maximumSize: Int64 = 536_870_912
    private let rootFD: Int32
    private let hooks: TestHooks
    private let cancellationCheck: @Sendable () -> Bool

    init(rootFD: Int32, hooks: TestHooks = TestHooks(), cancellationCheck: @escaping @Sendable () -> Bool = { false }) {
        self.rootFD = rootFD
        self.hooks = hooks
        self.cancellationCheck = cancellationCheck
    }

    func read(_ entry: GeneratedParakeetManifestEntry) throws -> VerifiedArtifactBytes {
        try checkCancellation()
        let components = try validate(entry)
        var rootInfo = stat()
        guard fstat(rootFD, &rootInfo) == 0 else {
            throw VerifiedArtifactReaderError.statFailed(errno)
        }
        guard (rootInfo.st_mode & S_IFMT) == S_IFDIR else {
            throw VerifiedArtifactReaderError.rootNotDirectory
        }

        var directoryFDs: [Int32] = []
        var currentFD = rootFD
        defer {
            for fd in directoryFDs.reversed() { _ = close(fd) }
        }

        for component in components.dropLast() {
            try checkCancellation()
            let fd = try openChild(named: component, relativeTo: currentFD, directory: true)
            directoryFDs.append(fd)
            currentFD = fd
        }

        let finalFD = try openChild(named: components[components.count - 1], relativeTo: currentFD, directory: false)
        defer { _ = close(finalFD) }

        var fileInfo = stat()
        guard fstat(finalFD, &fileInfo) == 0 else {
            throw VerifiedArtifactReaderError.statFailed(errno)
        }
        guard (fileInfo.st_mode & S_IFMT) == S_IFREG else {
            throw VerifiedArtifactReaderError.notRegularFile
        }
        let actualSize = Int64(fileInfo.st_size)
        guard actualSize == entry.size else {
            throw VerifiedArtifactReaderError.sizeMismatch(expected: entry.size, actual: actualSize)
        }

        hooks.afterStat?()
        let expectedSize = try validatedIntSize(entry.size)
        var data = Data(count: expectedSize)
        hooks.beforeRead?()

        var offset = 0
        try data.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            while offset < expectedSize {
                try checkCancellation()
                let result = Darwin.read(finalFD, baseAddress.advanced(by: offset), expectedSize - offset)
                if result < 0 {
                    if errno == EINTR { continue }
                    throw VerifiedArtifactReaderError.readFailed(errno)
                }
                if result == 0 {
                    throw VerifiedArtifactReaderError.shortRead(expected: expectedSize, actual: offset)
                }
                offset += result
            }
        }
        hooks.afterRead?()

        var trailingByte: UInt8 = 0
        while true {
            let result = Darwin.read(finalFD, &trailingByte, 1)
            if result < 0 {
                if errno == EINTR { continue }
                throw VerifiedArtifactReaderError.readFailed(errno)
            }
            if result == 1 {
                throw VerifiedArtifactReaderError.unexpectedTrailingByte
            }
            break
        }

        try checkCancellation()
        let actualDigest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actualDigest == entry.sha256 else {
            throw VerifiedArtifactReaderError.checksumMismatch(expected: entry.sha256, actual: actualDigest)
        }
        hooks.afterVerified?()
        return VerifiedArtifactBytes(identity: entry, data: data)
    }

    private func checkCancellation() throws {
        if cancellationCheck() { throw VerifiedArtifactReaderError.cancelled }
    }

    private func validate(_ entry: GeneratedParakeetManifestEntry) throws -> [String] {
        guard !entry.path.isEmpty,
              !entry.path.hasPrefix("/"),
              !entry.path.utf8.contains(0) else {
            throw VerifiedArtifactReaderError.invalidPath
        }
        let components = entry.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.utf8.contains(0) }) else {
            throw VerifiedArtifactReaderError.invalidPath
        }
        guard entry.sha256.utf8.count == 64,
              entry.sha256.utf8.allSatisfy({
                  ($0 >= Character("0").asciiValue! && $0 <= Character("9").asciiValue!) ||
                  ($0 >= Character("a").asciiValue! && $0 <= Character("f").asciiValue!)
              }) else {
            throw VerifiedArtifactReaderError.invalidDigest
        }
        _ = try validatedIntSize(entry.size)
        return components
    }

    private func validatedIntSize(_ size: Int64) throws -> Int {
        guard size > 0 else { throw VerifiedArtifactReaderError.invalidSize(size) }
        guard size <= Self.maximumSize else { throw VerifiedArtifactReaderError.sizeTooLarge(size) }
        guard let result = Int(exactly: size) else {
            throw VerifiedArtifactReaderError.sizeOverflow(size)
        }
        return result
    }

    private func openChild(named component: String, relativeTo directoryFD: Int32, directory: Bool) throws -> Int32 {
        let flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK | (directory ? O_DIRECTORY : 0)
        let fd = component.withCString { openat(directoryFD, $0, flags) }
        guard fd >= 0 else { throw VerifiedArtifactReaderError.openFailed(errno) }
        return fd
    }
}
