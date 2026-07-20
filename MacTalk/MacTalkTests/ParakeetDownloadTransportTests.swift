import CryptoKit
import Foundation
import XCTest
@testable import MacTalk

private final class TestMutex: @unchecked Sendable {
    private let mutex = NSLock()
    func lock() { mutex.lock() }
    func unlock() { mutex.unlock() }
}

private final class RecordingParakeetTransport: BoundedModelDownloading, @unchecked Sendable {
    private let lock = TestMutex()
    private(set) var requests: [BoundedModelDownloadRequest] = []

    func download(_ request: BoundedModelDownloadRequest) async throws -> URL {
        lock.lock()
        requests.append(request)
        lock.unlock()
        let bytes = request.identity.artifactPath == "a.bin" ? Data("abc".utf8) : Data("de".utf8)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("parakeet-source-\(UUID().uuidString)")
        try bytes.write(to: url)
        return url
    }

    func cancel(operationID: UUID) {}
}

final class ParakeetDownloadTransportTests: XCTestCase {
    func test_compiledManifestMapsAllTwentyOneArtifactsInOrder() throws {
        XCTAssertEqual(ParakeetModelDownloader.manifest.count, 21)
        for (index, entry) in ParakeetModelDownloader.manifest.enumerated() {
            let identity = try ParakeetModelDownloader.downloadIdentity(for: entry)
            XCTAssertEqual(identity.provider, "parakeet")
            XCTAssertEqual(identity.modelID, "parakeet-tdt-0.6b-v3")
            XCTAssertEqual(identity.sourceRepository, GeneratedModelProvenance.parakeetRepository)
            XCTAssertEqual(identity.revision, GeneratedModelProvenance.parakeetRevision)
            XCTAssertEqual(identity.artifactPath, entry.path)
            XCTAssertEqual(identity.filename, entry.path.split(separator: "/").last.map(String.init))
            XCTAssertEqual(identity.sizeBytes, entry.size)
            XCTAssertEqual(identity.sha256, entry.sha256)
            XCTAssertEqual(try ParakeetModelDownloader.mirrorURL(for: entry).absoluteString,
                           "https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml/resolve/aed02740059203c4a87495924f685de3722ae9ce/\(entry.path)")
            XCTAssertEqual(identity.artifactPath, GeneratedModelProvenance.parakeetCompiled[index].path)
        }
    }

    func test_downloaderPassesRemainingAggregateToBoundedTransportAndActivatesAtomically() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("parakeet-download-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let entries = [
            ParakeetManifestEntry(path: "a.bin", size: 3, sha256: SHA256.hash(data: Data("abc".utf8)).map { String(format: "%02x", $0) }.joined()),
            ParakeetManifestEntry(path: "b.bin", size: 2, sha256: SHA256.hash(data: Data("de".utf8)).map { String(format: "%02x", $0) }.joined())
        ]
        let transport = RecordingParakeetTransport()
        let downloader = ParakeetModelDownloader(modelsRoot: root, manifest: entries, transport: transport)
        let active: URL
        do {
            active = try await downloader.downloadIfNeeded()
        } catch {
            print("synthetic downloader error=\(error), requests=\(transport.requests.count)")
            throw error
        }
        XCTAssertEqual(active.lastPathComponent, ParakeetModelDownloader.folderName)
        XCTAssertEqual(transport.requests.map(\.aggregateDiskBytesStillRequired), [5, 2])
        XCTAssertTrue(downloader.modelsAvailable())
    }

    func test_remainingBytesUsesCheckedAggregateAccounting() throws {
        let entries = [
            ParakeetManifestEntry(path: "a", size: 2, sha256: String(repeating: "a", count: 64)),
            ParakeetManifestEntry(path: "b", size: 3, sha256: String(repeating: "b", count: 64)),
            ParakeetManifestEntry(path: "c", size: 5, sha256: String(repeating: "c", count: 64))
        ]
        XCTAssertEqual(try ParakeetModelDownloader.remainingBytes(from: 0, entries: entries), 10)
        XCTAssertEqual(try ParakeetModelDownloader.remainingBytes(from: 2, entries: entries), 5)
        XCTAssertEqual(try ParakeetModelDownloader.remainingBytes(from: 3, entries: entries), 0)
        XCTAssertThrowsError(try ParakeetModelDownloader.remainingBytes(from: 4, entries: entries))
        let overflowing = [
            ParakeetManifestEntry(path: "a", size: Int64.max, sha256: String(repeating: "a", count: 64)),
            ParakeetManifestEntry(path: "b", size: 1, sha256: String(repeating: "b", count: 64))
        ]
        XCTAssertThrowsError(try ParakeetModelDownloader.remainingBytes(from: 0, entries: overflowing))
    }
}
