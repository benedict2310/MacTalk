import Foundation

/// Validates downloaded model bytes before they can enter the model store.
/// The checksum is mandatory: an absent or malformed digest is never treated as
/// an opt-out, because the result is loaded by native inference code.
enum ModelIntegrityVerifier {
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
        installed = true
    }

    static func isValidDigest(_ digest: String) -> Bool {
        guard digest.utf8.count == 64 else { return false }
        return digest.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
        }
    }
}
