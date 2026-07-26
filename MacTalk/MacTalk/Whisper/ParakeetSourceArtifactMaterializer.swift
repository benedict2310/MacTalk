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

    static func remainingBytes(_ entries: [GeneratedParakeetManifestEntry]) throws -> Int64 {
        try ParakeetModelDownloader.remainingBytes(
            from: 0,
            entries: entries.map(manifestEntry(for:))
        )
    }

    static func makeRequest(
        for entry: GeneratedParakeetManifestEntry,
        operationID: UUID,
        workspaceRoot: URL,
        remainingEntries: [GeneratedParakeetManifestEntry],
        credentialToken: String?
    ) throws -> BoundedModelDownloadRequest {
        guard let index = remainingEntries.firstIndex(where: { $0.path == entry.path && $0.sha256 == entry.sha256 && $0.size == entry.size }) else {
            throw ParakeetSourcePreparationError.invalidManifest
        }
        let trailing = Array(remainingEntries[index...])
        let aggregate = try remainingBytes(trailing)
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

        // Spool verified bytes to an unlinked temporary file rather than
        // retaining an entire model artifact in RAM (the Encoder is ~425 MiB).
        // This also freezes the validated byte sequence before it reaches the
        // preparer-owned sink if another same-UID writer changes the payload.
        guard let spool = tmpfile() else { throw ParakeetSourcePreparationError.io(errno) }
        defer { fclose(spool) }
        let spoolFD = fileno(spool)
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
