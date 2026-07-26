import CryptoKit
import Darwin
import Foundation
import os

/// Builds official, immutable download requests for inactive Parakeet source
/// artifacts. Identities and mirrors stay pinned to generated provenance;
/// callers only supply dynamic operation/aggregate context.
enum ParakeetSourceDownloadRequestFactory {
    static func manifestEntry(for entry: GeneratedParakeetManifestEntry) -> ParakeetManifestEntry {
        ParakeetManifestEntry(path: entry.path, size: entry.size, sha256: entry.sha256)
    }

    static func downloadIdentity(for entry: GeneratedParakeetManifestEntry) throws -> DownloadArtifactIdentity {
        try ParakeetModelDownloader.downloadIdentity(for: manifestEntry(for: entry))
    }

    static func mirrorURL(for entry: GeneratedParakeetManifestEntry) throws -> URL {
        try ParakeetModelDownloader.mirrorURL(for: manifestEntry(for: entry))
    }

    /// Reserves every simultaneously live allocation: the complete staged
    /// source tree, completed transport payloads, and a payload plus spool for
    /// each pending download. This remains safe as completed artifacts stay in
    /// the bounded transport workspace between source entries.
    static func remainingBytes(
        operationEntries: [GeneratedParakeetManifestEntry],
        pendingEntries: [GeneratedParakeetManifestEntry]
    ) throws -> Int64 {
        let total = try ParakeetModelDownloader.remainingBytes(from: 0, entries: operationEntries.map(manifestEntry(for:)))
        let pending = try ParakeetModelDownloader.remainingBytes(from: 0, entries: pendingEntries.map(manifestEntry(for:)))
        let doubledTotal = total.multipliedReportingOverflow(by: 2)
        let reservation = doubledTotal.partialValue.addingReportingOverflow(pending)
        guard !doubledTotal.overflow, !reservation.overflow else {
            throw ParakeetSourcePreparationError.invalidManifest
        }
        return reservation.partialValue
    }

    static func remainingBytes(_ entries: [GeneratedParakeetManifestEntry]) throws -> Int64 {
        try remainingBytes(operationEntries: entries, pendingEntries: entries)
    }

    static func makeRequest(
        for entry: GeneratedParakeetManifestEntry,
        operationID: UUID,
        workspaceRoot: URL,
        remainingEntries: [GeneratedParakeetManifestEntry],
        operationEntries: [GeneratedParakeetManifestEntry],
        credentialToken: String?
    ) throws -> BoundedModelDownloadRequest {
        guard let index = remainingEntries.firstIndex(where: { $0.path == entry.path && $0.sha256 == entry.sha256 && $0.size == entry.size }) else {
            throw ParakeetSourcePreparationError.invalidManifest
        }
        let trailing = Array(remainingEntries[index...])
        let aggregate = try remainingBytes(operationEntries: operationEntries, pendingEntries: trailing)
        return BoundedModelDownloadRequest(
            identity: try downloadIdentity(for: entry),
            mirrors: [try mirrorURL(for: entry)],
            operationID: operationID,
            workspaceRoot: workspaceRoot,
            aggregateDiskBytesStillRequired: aggregate,
            credentialToken: credentialToken
        )
    }
}

/// Downloads one exact source manifest entry through the bounded transport and
/// writes verified bytes into a preparer-owned sink. Construction is passive.
final class BoundedParakeetSourceArtifactMaterializer: ParakeetSourceArtifactMaterializing, @unchecked Sendable {
    private struct State {
        var operationID: UUID?
        var operationEntries: [GeneratedParakeetManifestEntry] = []
        var remainingEntries: [GeneratedParakeetManifestEntry] = []
    }

    private let transport: any BoundedModelDownloading
    private let workspaceRoot: URL
    private let credentialToken: String?
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(
        transport: any BoundedModelDownloading,
        workspaceRoot: URL,
        credentialToken: String? = nil
    ) {
        self.transport = transport
        self.workspaceRoot = workspaceRoot
        self.credentialToken = credentialToken
    }

    /// Pure operation setup. Validates remaining entries and stores the one
    /// operation ID used for subsequent materialize/cancel calls.
    func begin(operationID: UUID, remainingEntries: [GeneratedParakeetManifestEntry]) throws {
        try beginPreparation(operationID: operationID, remainingEntries: remainingEntries)
    }

    func beginPreparation(operationID: UUID, remainingEntries: [GeneratedParakeetManifestEntry]) throws {
        _ = try ParakeetSourceDownloadRequestFactory.remainingBytes(remainingEntries)
        for entry in remainingEntries {
            _ = try ParakeetSourceDownloadRequestFactory.downloadIdentity(for: entry)
        }
        state.withLock {
            $0.operationID = operationID
            $0.operationEntries = remainingEntries
            $0.remainingEntries = remainingEntries
        }
    }

    func cancel(operationID: UUID) {
        cancelPreparation(operationID: operationID)
    }

    func cancelPreparation(operationID: UUID) {
        transport.cancel(operationID: operationID)
    }

    func materialize(entry: GeneratedParakeetManifestEntry, sink: ParakeetSourceArtifactSink) async throws {
        let request: BoundedModelDownloadRequest = try state.withLock { current in
            guard let operationID = current.operationID else {
                throw ParakeetSourcePreparationError.invalidManifest
            }
            return try ParakeetSourceDownloadRequestFactory.makeRequest(
                for: entry,
                operationID: operationID,
                workspaceRoot: workspaceRoot,
                remainingEntries: current.remainingEntries,
                operationEntries: current.operationEntries,
                credentialToken: credentialToken
            )
        }

        try checkCancellation()
        let payloadURL: URL
        do {
            payloadURL = try await transport.download(request)
        } catch is CancellationError {
            throw ParakeetSourcePreparationError.cancelled
        } catch let error as BoundedModelDownloadError {
            if error == .cancelled || error == .superseded {
                throw ParakeetSourcePreparationError.cancelled
            }
            throw ParakeetSourcePreparationError.activationFailed
        }
        try checkCancellation()
        try verifyAndWrite(payloadURL: payloadURL, entry: entry, sink: sink)
        try checkCancellation()

        state.withLock { current in
            if let index = current.remainingEntries.firstIndex(where: {
                $0.path == entry.path && $0.sha256 == entry.sha256 && $0.size == entry.size
            }) {
                current.remainingEntries.remove(at: index)
            }
        }
    }

    private func checkCancellation() throws {
        if Task.isCancelled { throw ParakeetSourcePreparationError.cancelled }
    }

    private func verifyAndWrite(
        payloadURL: URL,
        entry: GeneratedParakeetManifestEntry,
        sink: ParakeetSourceArtifactSink
    ) throws {
        guard payloadURL.isFileURL else { throw ParakeetSourcePreparationError.invalidPath(payloadURL.path) }
        let fd = payloadURL.path.withCString {
            open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        }
        guard fd >= 0 else {
            if errno == ELOOP { throw ParakeetSourcePreparationError.invalidTree }
            throw ParakeetSourcePreparationError.io(errno)
        }
        defer { _ = Darwin.close(fd) }

        var info = stat()
        guard fstat(fd, &info) == 0 else { throw ParakeetSourcePreparationError.io(errno) }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw ParakeetSourcePreparationError.invalidTree }
        guard info.st_uid == getuid() else { throw ParakeetSourcePreparationError.invalidTree }
        guard info.st_size == entry.size else { throw ParakeetSourcePreparationError.artifactSize }

        // Spool under the preflighted workspace volume rather than process
        // temp. It is immediately unlinked, so it has no later path authority.
        // This avoids retaining the ~425 MiB Encoder in RAM and freezes the
        // verified bytes before they reach the preparer-owned sink.
        let spoolFD = try openUnlinkedWorkspaceSpool()
        defer { _ = Darwin.close(spoolFD) }
        var hasher = SHA256()
        var total: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while total < entry.size {
            try checkCancellation()
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw ParakeetSourcePreparationError.io(errno)
            }
            if count == 0 { throw ParakeetSourcePreparationError.artifactSize }
            let used = Int(min(Int64(count), entry.size - total))
            if count > used { throw ParakeetSourcePreparationError.artifactSize }
            let chunk = Data(buffer[0..<used])
            hasher.update(data: chunk)
            try writeAll(chunk, to: spoolFD)
            total += Int64(used)
        }
        try checkCancellation()
        var trailing: UInt8 = 0
        let end = Darwin.read(fd, &trailing, 1)
        if end < 0 { throw ParakeetSourcePreparationError.io(errno) }
        guard end == 0 else { throw ParakeetSourcePreparationError.artifactSize }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == entry.sha256 else { throw ParakeetSourcePreparationError.artifactDigest }
        guard lseek(spoolFD, 0, SEEK_SET) >= 0 else { throw ParakeetSourcePreparationError.io(errno) }

        // Only after complete descriptor verification may bounded chunks enter
        // the sink. `buffer` and `chunk` cap retained payload memory at 64 KiB.
        var remaining = entry.size
        while remaining > 0 {
            try checkCancellation()
            let count = Darwin.read(spoolFD, &buffer, min(buffer.count, Int(remaining)))
            if count < 0 {
                if errno == EINTR { continue }
                throw ParakeetSourcePreparationError.io(errno)
            }
            guard count > 0 else { throw ParakeetSourcePreparationError.artifactSize }
            let chunk = Data(buffer[0..<count])
            try sink.write(chunk)
            remaining -= Int64(count)
        }
    }

    private func openUnlinkedWorkspaceSpool() throws -> Int32 {
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        let rootFD = workspaceRoot.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard rootFD >= 0 else { throw ParakeetSourcePreparationError.io(errno) }
        defer { _ = Darwin.close(rootFD) }
        var info = stat()
        guard fstat(rootFD, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid() else {
            throw ParakeetSourcePreparationError.invalidTree
        }
        let name = ".mactalk-source-spool-\(UUID().uuidString)"
        let fd = name.withCString {
            openat(rootFD, $0, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        }
        guard fd >= 0 else { throw ParakeetSourcePreparationError.io(errno) }
        guard name.withCString({ unlinkat(rootFD, $0, 0) == 0 }) else {
            let code = errno
            _ = Darwin.close(fd)
            throw ParakeetSourcePreparationError.io(code)
        }
        return fd
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
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
    }
}
