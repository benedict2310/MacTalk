import Foundation
import CryptoKit

enum SHA256Streamer {
    /// Hash a file using streaming to avoid loading entire file into memory
    /// This is critical for large model files (1GB+)
    static func hashFile(at url: URL, chunkSize: Int = 1 << 20) throws -> String {
        guard let stream = InputStream(url: url) else {
            throw NSError(
                domain: "SHA256Streamer",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Could not open file at \(url.path)"]
            )
        }
        stream.open()
        defer { stream.close() }

        var hasher = SHA256()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let bytesRead = stream.read(buffer, maxLength: chunkSize)
            if bytesRead < 0 {
                throw stream.streamError ?? NSError(
                    domain: "SHA256Streamer",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "Stream read error"]
                )
            }
            if bytesRead == 0 { break }
            hasher.update(data: Data(bytes: buffer, count: bytesRead))
        }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
