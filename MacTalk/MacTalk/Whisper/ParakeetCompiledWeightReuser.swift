import CryptoKit
import Darwin
import Foundation

/// A validated one-to-one mapping between the source and compiled weight
/// manifests. Construction is pure; it does not open or mutate the store.
struct ParakeetCompiledWeightReuseMapping: Sendable, Equatable {
    let component: ParakeetSourceComponent
    let sourcePath: String
    let compiledPath: String
    let size: Int64
    let sha256: String
}

enum ParakeetCompiledWeightReuseConfigurationError: Error, Equatable, Sendable {
    case wrongMappingCount
    case duplicateComponent(String)
    case invalidSourceEntry(String)
    case invalidCompiledEntry(String)
    case pathMismatch(String)
    case roleMismatch(String)
    case tupleMismatch(String)
    case invalidDigest(String)
    case invalidSize(String)
    case invalidCompiledDirectoryName
}

enum ParakeetCompiledWeightReuseUnavailableReason: Error, Equatable, Sendable {
    case missing
    case symlink
    case nonRegular
    case unreadable
    case wrongOwner
    case sizeMismatch
    case digestMismatch
    case io(Int32)
}

enum ParakeetCompiledWeightReuseError: Error, Equatable, Sendable {
    case sourceEntryMismatch
    case leaseStoreParentMismatch
    case leaseNotExclusive
    case leaseUnavailable
    case unsafeStagingRoot
    case destinationCollision
    case destinationVerificationFailed
    case io(Int32)
    case cancelled
}

enum ParakeetCompiledWeightReuseMethod: Sendable, Equatable {
    case hardLink
    case copy
}

enum ParakeetCompiledWeightReuseResult: Sendable, Equatable {
    case reused(ParakeetCompiledWeightReuseMethod)
    case unavailable(ParakeetCompiledWeightReuseUnavailableReason)
}

/// Inactive, descriptor-relative reuse of compiled weight files into a source
/// staging tree. This type intentionally has no downloader or activation
/// integration; a later source preparer may call it under its own lease.
final class ParakeetCompiledWeightReuser: @unchecked Sendable {
    struct TestHooks {
        let forceCopy: Bool
        let forceLinkFailure: Bool
        let forceDestinationStatFailureAfterLink: Bool
        let forceCopyStatFailureAfterCreate: Bool
        let afterLink: (() -> Void)?
        let afterCopyCreate: (() -> Void)?
        let beforeSourceStreamRead: (() -> Void)?
        let afterSourceVerification: (() -> Void)?
        let beforeDestinationVerification: (() -> Void)?
        let afterDestinationIdentityObservation: (() -> Void)?

        init(forceCopy: Bool = false, forceLinkFailure: Bool = false,
             forceDestinationStatFailureAfterLink: Bool = false,
             forceCopyStatFailureAfterCreate: Bool = false,
             afterLink: (() -> Void)? = nil,
             afterCopyCreate: (() -> Void)? = nil,
             beforeSourceStreamRead: (() -> Void)? = nil,
             afterSourceVerification: (() -> Void)? = nil,
             beforeDestinationVerification: (() -> Void)? = nil,
             afterDestinationIdentityObservation: (() -> Void)? = nil) {
            self.forceCopy = forceCopy
            self.forceLinkFailure = forceLinkFailure
            self.forceDestinationStatFailureAfterLink = forceDestinationStatFailureAfterLink
            self.forceCopyStatFailureAfterCreate = forceCopyStatFailureAfterCreate
            self.afterLink = afterLink
            self.afterCopyCreate = afterCopyCreate
            self.beforeSourceStreamRead = beforeSourceStreamRead
            self.afterSourceVerification = afterSourceVerification
            self.beforeDestinationVerification = beforeDestinationVerification
            self.afterDestinationIdentityObservation = afterDestinationIdentityObservation
        }
    }

    let mappings: [ParakeetCompiledWeightReuseMapping]
    private let store: ParakeetSourceStore
    private let compiledDirectoryName: String
    private let hooks: TestHooks

    init(store: ParakeetSourceStore,
         sourceEntries: [GeneratedParakeetManifestEntry],
         compiledEntries: [GeneratedParakeetManifestEntry],
         compiledDirectoryName: String = ParakeetModelDownloader.folderName,
         hooks: TestHooks = TestHooks()) throws {
        guard compiledDirectoryName == ParakeetModelDownloader.folderName else {
            throw ParakeetCompiledWeightReuseConfigurationError.invalidCompiledDirectoryName
        }
        self.store = store
        self.compiledDirectoryName = compiledDirectoryName
        self.hooks = hooks
        self.mappings = try Self.validate(sourceEntries: sourceEntries, compiledEntries: compiledEntries,
                                          compiledDirectoryName: compiledDirectoryName)
    }

    func reuse(sourceEntry: GeneratedParakeetManifestEntry,
               holding lease: ParakeetStoreFileLock.Lease,
               stagingRootFD: Int32) throws -> ParakeetCompiledWeightReuseResult {
        guard let mapping = mappings.first(where: { $0.component.rawValue == sourceEntry.component }) else {
            throw ParakeetCompiledWeightReuseError.sourceEntryMismatch
        }
        guard sourceEntry.role == "weights", sourceEntry.path == mapping.sourcePath,
              sourceEntry.size == mapping.size, sourceEntry.sha256 == mapping.sha256 else {
            throw ParakeetCompiledWeightReuseError.sourceEntryMismatch
        }
        guard lease.authorizesStoreParent(store.parent) else {
            throw ParakeetCompiledWeightReuseError.leaseStoreParentMismatch
        }
        try checkCancellation()
        try validateStagingRoot(stagingRootFD)

        switch lease.mode {
        case .shared:
            throw ParakeetCompiledWeightReuseError.leaseNotExclusive
        case .exclusive:
            break
        }

        let outcome: ParakeetCompiledWeightReuseResult? = try lease.withStoreParentDescriptorIfAvailable { parentFD in
            try self.reuse(relativeTo: parentFD, mapping: mapping, stagingRootFD: stagingRootFD)
        }
        guard let outcome else { throw ParakeetCompiledWeightReuseError.leaseUnavailable }
        return outcome
    }

    private func reuse(relativeTo parentFD: Int32, mapping: ParakeetCompiledWeightReuseMapping,
                       stagingRootFD: Int32) throws -> ParakeetCompiledWeightReuseResult {
        let source: OpenedSource
        do {
            source = try openCompiledSource(parentFD: parentFD, path: mapping.compiledPath)
        } catch let reason as ParakeetCompiledWeightReuseUnavailableReason {
            return .unavailable(reason)
        }
        defer { source.close() }
        do {
            guard try verifySource(source.fileFD, expectedSize: mapping.size, expectedDigest: mapping.sha256) else {
                return .unavailable(.digestMismatch)
            }
        } catch let reason as ParakeetCompiledWeightReuseUnavailableReason {
            return .unavailable(reason)
        }
        hooks.afterSourceVerification?()
        try checkCancellation()

        let destination = try openDestinationParent(rootFD: stagingRootFD, path: mapping.sourcePath)
        defer { close(destination.parentFD) }
        try checkDestinationAbsent(parentFD: destination.parentFD, leaf: destination.leaf)

        try checkCancellation()

        var method = ParakeetCompiledWeightReuseMethod.copy
        if !hooks.forceCopy && source.info.st_uid == getuid() && (source.info.st_mode & 0o777) == 0o600 {
            var linked: Bool
            let linkError: Int32
            if hooks.forceLinkFailure {
                linked = false
                linkError = EIO
            } else {
                linked = linkat(source.parentFD, source.leaf, destination.parentFD, destination.leaf, 0) == 0
                linkError = linked ? 0 : errno
            }
            if linked {
                hooks.afterLink?()
                guard !hooks.forceDestinationStatFailureAfterLink,
                      let linkedInfo = destinationStat(parentFD: destination.parentFD, leaf: destination.leaf) else {
                    // Destination cleanup is caller-owned. macOS has no atomic
                    // conditional unlink, so never unlink a leaf after a
                    // failure; the caller removes the whole staging tree.
                    throw ParakeetCompiledWeightReuseError.destinationVerificationFailed
                }
                hooks.afterDestinationIdentityObservation?()
                let linkedIsRegular = (linkedInfo.st_mode & S_IFMT) == S_IFREG
                let linkedMatchesSource = linkedInfo.st_dev == source.info.st_dev && linkedInfo.st_ino == source.info.st_ino
                guard linkedIsRegular && linkedMatchesSource else {
                    // Do not fall back over an occupied or raced destination.
                    throw ParakeetCompiledWeightReuseError.destinationVerificationFailed
                }
                method = .hardLink
            } else if linkError == EEXIST {
                throw ParakeetCompiledWeightReuseError.destinationCollision
            }
        }

        if method == .copy {
            _ = try copyVerifiedSource(source.fileFD, destination.parentFD, leaf: destination.leaf, size: mapping.size)
        }

        do {
            hooks.beforeDestinationVerification?()
            try verifyDestination(parentFD: destination.parentFD, leaf: destination.leaf,
                                  expectedSize: mapping.size, expectedDigest: mapping.sha256)
            return .reused(method)
        } catch is CancellationError {
            throw ParakeetCompiledWeightReuseError.cancelled
        } catch let error as ParakeetCompiledWeightReuseError {
            throw error
        } catch {
            throw ParakeetCompiledWeightReuseError.destinationVerificationFailed
        }
    }

    private static func validate(sourceEntries: [GeneratedParakeetManifestEntry],
                                 compiledEntries: [GeneratedParakeetManifestEntry],
                                 compiledDirectoryName: String) throws -> [ParakeetCompiledWeightReuseMapping] {
        guard isSafeComponent(compiledDirectoryName) else { throw ParakeetCompiledWeightReuseConfigurationError.invalidCompiledDirectoryName }
        let sourceWeights = sourceEntries.filter { $0.role == "weights" }
        let compiledWeights = compiledEntries.filter { entry in
            entry.role == "compiled" && ParakeetSourceComponent.allCases.contains(where: {
                entry.path == "\($0.rawValue).mlmodelc/weights/weight.bin"
            })
        }
        guard sourceWeights.count == ParakeetSourceComponent.allCases.count,
              compiledWeights.count == ParakeetSourceComponent.allCases.count else {
            throw ParakeetCompiledWeightReuseConfigurationError.wrongMappingCount
        }
        var mappings: [ParakeetCompiledWeightReuseMapping] = []
        for component in ParakeetSourceComponent.allCases {
            guard let source = sourceWeights.first(where: { $0.component == component.rawValue }) else {
                throw ParakeetCompiledWeightReuseConfigurationError.duplicateComponent(component.rawValue)
            }
            guard sourceWeights.filter({ $0.component == component.rawValue }).count == 1 else {
                throw ParakeetCompiledWeightReuseConfigurationError.duplicateComponent(component.rawValue)
            }
            guard source.role == "weights" else { throw ParakeetCompiledWeightReuseConfigurationError.roleMismatch(source.path) }
            guard let expectedSourcePath = ParakeetSourcePathContract.expectedPath(component: component, role: "weights") else {
                throw ParakeetCompiledWeightReuseConfigurationError.pathMismatch(component.rawValue)
            }
            guard source.path == expectedSourcePath else { throw ParakeetCompiledWeightReuseConfigurationError.pathMismatch(source.path) }
            try validateTuple(source, path: source.path)

            guard let compiled = compiledWeights.first(where: { $0.component == component.rawValue }) else {
                throw ParakeetCompiledWeightReuseConfigurationError.duplicateComponent(component.rawValue)
            }
            guard compiledWeights.filter({ $0.component == component.rawValue }).count == 1 else {
                throw ParakeetCompiledWeightReuseConfigurationError.duplicateComponent(component.rawValue)
            }
            let expectedCompiledPath = "\(component.rawValue).mlmodelc/weights/weight.bin"
            guard compiled.role == "compiled" else { throw ParakeetCompiledWeightReuseConfigurationError.roleMismatch(compiled.path) }
            guard compiled.path == expectedCompiledPath else { throw ParakeetCompiledWeightReuseConfigurationError.pathMismatch(compiled.path) }
            try validateTuple(compiled, path: compiled.path)
            guard source.size == compiled.size, source.sha256 == compiled.sha256 else {
                throw ParakeetCompiledWeightReuseConfigurationError.tupleMismatch(component.rawValue)
            }
            mappings.append(ParakeetCompiledWeightReuseMapping(component: component, sourcePath: source.path,
                                                               compiledPath: "\(compiledDirectoryName)/\(compiled.path)",
                                                               size: source.size, sha256: source.sha256))
        }
        return mappings
    }

    private static func validateTuple(_ entry: GeneratedParakeetManifestEntry, path: String) throws {
        guard entry.size > 0 else { throw ParakeetCompiledWeightReuseConfigurationError.invalidSize(path) }
        guard entry.sha256.utf8.count == 64,
              entry.sha256.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }) else {
            throw ParakeetCompiledWeightReuseConfigurationError.invalidDigest(path)
        }
    }

    private func openCompiledSource(parentFD: Int32, path: String) throws -> OpenedSource {
        let components = path.split(separator: "/").map(String.init)
        var current = parentFD
        var owned: [Int32] = []
        for component in components.dropLast() {
            let fd = component.withCString { openat(current, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            guard fd >= 0 else {
                for descriptor in owned { close(descriptor) }
                throw unavailable(errno)
            }
            owned.append(fd); current = fd
        }
        let leaf = components.last!
        let fileFD = leaf.withCString { openat(current, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK) }
        guard fileFD >= 0 else {
            for descriptor in owned { close(descriptor) }
            throw unavailable(errno)
        }
        var info = stat()
        guard fstat(fileFD, &info) == 0 else { close(fileFD); for descriptor in owned { close(descriptor) }; throw unavailable(errno) }
        guard (info.st_mode & S_IFMT) == S_IFREG else { close(fileFD); for descriptor in owned { close(descriptor) }; throw ParakeetCompiledWeightReuseUnavailableReason.nonRegular }
        guard info.st_uid == getuid() else { close(fileFD); for descriptor in owned { close(descriptor) }; throw ParakeetCompiledWeightReuseUnavailableReason.wrongOwner }
        return OpenedSource(fileFD: fileFD, parentFD: current, leaf: leaf, info: info, ancestors: owned)
    }

    private func verifySource(_ fd: Int32, expectedSize: Int64, expectedDigest: String) throws -> Bool {
        var info = stat(); guard fstat(fd, &info) == 0 else { throw unavailable(errno) }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw ParakeetCompiledWeightReuseUnavailableReason.nonRegular }
        guard info.st_uid == getuid() else { throw ParakeetCompiledWeightReuseUnavailableReason.wrongOwner }
        guard info.st_size == expectedSize else { throw ParakeetCompiledWeightReuseUnavailableReason.sizeMismatch }
        return try streamMatches(fd: fd, expectedSize: expectedSize, expectedDigest: expectedDigest,
                                 unavailable: true, beforeRead: hooks.beforeSourceStreamRead)
    }

    private func streamMatches(fd: Int32, expectedSize: Int64, expectedDigest: String, unavailable: Bool,
                               beforeRead: (() -> Void)? = nil) throws -> Bool {
        guard lseek(fd, 0, SEEK_SET) >= 0 else { throw unavailable ? ParakeetCompiledWeightReuseUnavailableReason.unreadable : ParakeetCompiledWeightReuseError.io(errno) }
        var hasher = SHA256(); var total: Int64 = 0; var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while total < expectedSize {
            beforeRead?()
            try checkCancellation()
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue }; throw unavailable ? ParakeetCompiledWeightReuseUnavailableReason.unreadable : ParakeetCompiledWeightReuseError.io(errno) }
            if count == 0 { throw unavailable ? ParakeetCompiledWeightReuseUnavailableReason.sizeMismatch : ParakeetCompiledWeightReuseError.destinationVerificationFailed }
            let used = Int(min(Int64(count), expectedSize - total))
            hasher.update(data: Data(buffer[0..<used])); total += Int64(used)
            if count > used { throw unavailable ? ParakeetCompiledWeightReuseUnavailableReason.sizeMismatch : ParakeetCompiledWeightReuseError.destinationVerificationFailed }
        }
        try checkCancellation()
        var trailing: UInt8 = 0
        let end = Darwin.read(fd, &trailing, 1)
        if end < 0 { throw unavailable ? ParakeetCompiledWeightReuseUnavailableReason.unreadable : ParakeetCompiledWeightReuseError.io(errno) }
        guard end == 0 else { throw unavailable ? ParakeetCompiledWeightReuseUnavailableReason.sizeMismatch : ParakeetCompiledWeightReuseError.destinationVerificationFailed }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        if digest != expectedDigest { throw unavailable ? ParakeetCompiledWeightReuseUnavailableReason.digestMismatch : ParakeetCompiledWeightReuseError.destinationVerificationFailed }
        return true
    }

    private func openDestinationParent(rootFD: Int32, path: String) throws -> (parentFD: Int32, leaf: String) {
        let components = path.split(separator: "/").map(String.init)
        var current = rootFD; var owned: [Int32] = []; var handedOff = false
        defer {
            if !handedOff {
                for fd in owned.reversed() { close(fd) }
            }
        }
        for component in components.dropLast() {
            try checkCancellation()
            var fd = component.withCString { openat(current, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            if fd < 0 && errno == ENOENT {
                let created = mkdirat(current, component, mode_t(0o700)) == 0
                if !created && errno != EEXIST {
                    throw ParakeetCompiledWeightReuseError.io(errno)
                }
                fd = component.withCString { openat(current, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
                guard fd >= 0 else { throw ParakeetCompiledWeightReuseError.io(errno) }
                if created {
                    guard fchmod(fd, mode_t(0o700)) == 0 else { let code = errno; close(fd); throw ParakeetCompiledWeightReuseError.io(code) }
                }
            }
            guard fd >= 0 else { throw ParakeetCompiledWeightReuseError.io(errno) }
            var info = stat(); guard fstat(fd, &info) == 0 else { let code = errno; close(fd); throw ParakeetCompiledWeightReuseError.io(code) }
            guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid(), (info.st_mode & 0o777) == 0o700 else { close(fd); throw ParakeetCompiledWeightReuseError.unsafeStagingRoot }
            owned.append(fd); current = fd
        }
        for fd in owned.dropLast() { close(fd) }
        handedOff = true
        return (current, components.last!)
    }

    private func checkDestinationAbsent(parentFD: Int32, leaf: String) throws {
        let fd = openDestination(parentFD, leaf)
        if fd >= 0 { close(fd); throw ParakeetCompiledWeightReuseError.destinationCollision }
        if errno != ENOENT { throw ParakeetCompiledWeightReuseError.destinationCollision }
    }

    private func openDestination(_ parentFD: Int32, _ leaf: String) -> Int32 {
        leaf.withCString { openat(parentFD, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK) }
    }

    private func destinationStat(parentFD: Int32, leaf: String) -> stat? {
        var info = stat()
        while true {
            let result = leaf.withCString { fstatat(parentFD, $0, &info, AT_SYMLINK_NOFOLLOW) }
            if result == 0 { return info }
            if errno == EINTR { continue }
            return nil
        }
    }

    private func copyVerifiedSource(_ sourceFD: Int32, _ destinationParentFD: Int32, leaf: String, size: Int64) throws -> stat {
        let destinationFD = leaf.withCString { openat(destinationParentFD, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600)) }
        guard destinationFD >= 0 else { throw errno == EEXIST ? ParakeetCompiledWeightReuseError.destinationCollision : .io(errno) }
        // The caller owns the whole staging tree. Keep this leaf, including
        // partial contents, on every failure so a raced replacement can never
        // be deleted by name cleanup.
        defer { close(destinationFD) }
        hooks.afterCopyCreate?()
        if hooks.forceCopyStatFailureAfterCreate {
            throw ParakeetCompiledWeightReuseError.io(EIO)
        }
        var info = stat()
        guard fstat(destinationFD, &info) == 0 else {
            throw ParakeetCompiledWeightReuseError.io(errno)
        }
        guard fchmod(destinationFD, mode_t(0o600)) == 0 else { throw ParakeetCompiledWeightReuseError.io(errno) }
        guard lseek(sourceFD, 0, SEEK_SET) >= 0 else { throw ParakeetCompiledWeightReuseError.io(errno) }
        var remaining = size; var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while remaining > 0 {
            try checkCancellation()
            let count = Darwin.read(sourceFD, &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue }; throw ParakeetCompiledWeightReuseError.io(errno) }
            guard count > 0 else { throw ParakeetCompiledWeightReuseError.destinationVerificationFailed }
            let used = Int(min(Int64(count), remaining)); var offset = 0
            while offset < used {
                let written = buffer.withUnsafeBytes { rawBuffer in
                    Darwin.write(destinationFD, rawBuffer.baseAddress!.advanced(by: offset), used - offset)
                }
                if written < 0 { if errno == EINTR { continue }; throw ParakeetCompiledWeightReuseError.io(errno) }
                guard written > 0 else { throw ParakeetCompiledWeightReuseError.io(EIO) }
                offset += written
            }
            remaining -= Int64(used)
            if count > used { throw ParakeetCompiledWeightReuseError.destinationVerificationFailed }
        }
        guard fsync(destinationFD) == 0 else { throw ParakeetCompiledWeightReuseError.io(errno) }
        return info
    }

    private func verifyDestination(parentFD: Int32, leaf: String, expectedSize: Int64, expectedDigest: String) throws {
        let fd = openDestination(parentFD, leaf)
        guard fd >= 0 else { throw ParakeetCompiledWeightReuseError.destinationVerificationFailed }
        defer { close(fd) }
        var info = stat(); guard fstat(fd, &info) == 0 else { throw ParakeetCompiledWeightReuseError.destinationVerificationFailed }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(), (info.st_mode & 0o777) == 0o600,
              info.st_size == expectedSize else { throw ParakeetCompiledWeightReuseError.destinationVerificationFailed }
        _ = try streamMatches(fd: fd, expectedSize: expectedSize, expectedDigest: expectedDigest, unavailable: false)
    }

    private func validateStagingRoot(_ fd: Int32) throws {
        var info = stat(); guard fstat(fd, &info) == 0 else { throw ParakeetCompiledWeightReuseError.unsafeStagingRoot }
        guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid(), (info.st_mode & 0o777) == 0o700 else {
            throw ParakeetCompiledWeightReuseError.unsafeStagingRoot
        }
    }

    private func checkCancellation() throws {
        if Task.isCancelled { throw ParakeetCompiledWeightReuseError.cancelled }
    }

    private func unavailable(_ code: Int32) -> Error {
        switch code {
        case ENOENT, ENOTDIR: return ParakeetCompiledWeightReuseUnavailableReason.missing
        case ELOOP: return ParakeetCompiledWeightReuseUnavailableReason.symlink
        case EACCES, EPERM: return ParakeetCompiledWeightReuseUnavailableReason.unreadable
        default: return ParakeetCompiledWeightReuseUnavailableReason.io(code)
        }
    }

    private static func isSafeComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.utf8.contains(0)
    }

    private struct OpenedSource {
        let fileFD: Int32
        let parentFD: Int32
        let leaf: String
        let info: stat
        let ancestors: [Int32]
        func close() { Darwin.close(fileFD); for fd in ancestors.reversed() { Darwin.close(fd) } }
    }
}
