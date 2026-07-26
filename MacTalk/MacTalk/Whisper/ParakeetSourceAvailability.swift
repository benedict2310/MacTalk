import Darwin
import Foundation

/// Lightweight synchronous availability boundary for menu/selection code.
/// It authenticates the canonical source directory and identity marker under a
/// shared store lease. Full structure, size and digest verification still runs
/// immediately before every CoreML load through the snapshot provider.
struct ParakeetSourceAvailability: ParakeetBootstrapSourceAvailability, Sendable {
    let store: ParakeetSourceStore

    func isAvailable() -> Bool {
        guard FileManager.default.fileExists(atPath: store.parent.path) else { return false }
        let lock = ParakeetStoreFileLock(storeParent: store.parent)
        guard let lease = try? lock.tryAcquire(.shared) else { return false }
        defer { lease.release() }
        return (try? lease.withStoreParentDescriptor { parentFD in
            try validateIdentityMarker(parentFD: parentFD)
        }) != nil
    }

    private func validateIdentityMarker(parentFD: Int32) throws {
        let sourceFD = store.sourceDirectoryName.withCString {
            openat(parentFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard sourceFD >= 0 else { throw AvailabilityError.invalid }
        defer { _ = Darwin.close(sourceFD) }
        var sourceInfo = stat()
        guard fstat(sourceFD, &sourceInfo) == 0,
              (sourceInfo.st_mode & S_IFMT) == S_IFDIR,
              sourceInfo.st_uid == getuid(),
              (sourceInfo.st_mode & 0o077) == 0 else {
            throw AvailabilityError.invalid
        }

        let markerFD = ParakeetSourceStore.identityMarkerName.withCString {
            openat(sourceFD, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        }
        guard markerFD >= 0 else { throw AvailabilityError.invalid }
        defer { _ = Darwin.close(markerFD) }
        var markerInfo = stat()
        guard fstat(markerFD, &markerInfo) == 0,
              (markerInfo.st_mode & S_IFMT) == S_IFREG,
              markerInfo.st_uid == getuid(),
              (markerInfo.st_mode & 0o077) == 0,
              markerInfo.st_size > 0,
              markerInfo.st_size <= 16 * 1024 else {
            throw AvailabilityError.invalid
        }
        let markerSize = Int(markerInfo.st_size)
        var data = Data(count: markerSize)
        var offset = 0
        while offset < markerSize {
            let count = data.withUnsafeMutableBytes { bytes in
                Darwin.read(markerFD, bytes.baseAddress!.advanced(by: offset), markerSize - offset)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw AvailabilityError.invalid
            }
            guard count > 0 else { throw AvailabilityError.invalid }
            offset += count
        }
        var trailing: UInt8 = 0
        guard Darwin.read(markerFD, &trailing, 1) == 0,
              let identity = try? JSONDecoder().decode(ParakeetSourceIdentity.self, from: data),
              identity == store.identity else {
            throw AvailabilityError.invalid
        }
    }

    private enum AvailabilityError: Error { case invalid }
}
