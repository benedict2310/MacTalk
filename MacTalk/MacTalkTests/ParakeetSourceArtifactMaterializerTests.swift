import CryptoKit
import Darwin
import Foundation
import os
import XCTest
@testable import MacTalk

final class ParakeetSourceArtifactMaterializerTests: XCTestCase {
    func test_constructionIsFilesystemPassive() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mactalk-source-mat-passive-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        _ = BoundedParakeetSourceArtifactMaterializer(
            transport: RecordingSourceTransport(),
            workspaceRoot: root
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func test_materializeBuildsExactOfficialRequestAndWritesVerifiedBytes() async throws {
        let bytesA = Data("vocabulary-a".utf8)
        let bytesB = Data("spec-b-bytes".utf8)
        let entryA = makeEntry(path: "parakeet_vocab.json", component: "Vocabulary", role: "vocabulary", data: bytesA)
        let entryB = makeEntry(
            path: "mlpackages/Preprocessor.mlpackage/Data/com.apple.CoreML/model.mlmodel",
            component: "Preprocessor",
            role: "specification",
            data: bytesB
        )
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = RecordingSourceTransport(payloads: [
            entryA.path: bytesA,
            entryB.path: bytesB
        ])
        let materializer = BoundedParakeetSourceArtifactMaterializer(
            transport: transport,
            workspaceRoot: root,
            credentialToken: "test-token"
        )
        let operationID = UUID()
        try materializer.begin(operationID: operationID, remainingEntries: [entryA, entryB])

        try await ParakeetSourceArtifactSinkTestSupport.withTemporarySink(entry: entryA) { sink, _ in
            try await materializer.materialize(entry: entryA, sink: sink)
        }
        try await ParakeetSourceArtifactSinkTestSupport.withTemporarySink(entry: entryB) { sink, _ in
            try await materializer.materialize(entry: entryB, sink: sink)
        }

        let requests = transport.requestSnapshot()
        XCTAssertEqual(requests.count, 2)
        let expectedIdentityA = try ParakeetSourceDownloadRequestFactory.downloadIdentity(for: entryA)
        let expectedMirrorA = try ParakeetSourceDownloadRequestFactory.mirrorURL(for: entryA)
        XCTAssertEqual(requests[0].identity, expectedIdentityA)
        XCTAssertEqual(requests[0].mirrors, [expectedMirrorA])
        XCTAssertEqual(requests[0].operationID, operationID)
        XCTAssertEqual(requests[0].workspaceRoot.standardizedFileURL, root.standardizedFileURL)
        XCTAssertEqual(requests[0].credentialToken, "test-token")
        XCTAssertEqual(requests[0].aggregateDiskBytesStillRequired, Int64(3 * (bytesA.count + bytesB.count)))
        XCTAssertEqual(requests[1].aggregateDiskBytesStillRequired, Int64(2 * bytesA.count + 3 * bytesB.count))
        XCTAssertEqual(requests[1].identity.artifactPath, entryB.path)
        XCTAssertTrue(expectedMirrorA.absoluteString.hasPrefix("https://huggingface.co/"))
    }

    func test_largePayloadSpoolsAndStreamsVerifiedChunksToSink() async throws {
        // More than four internal chunks: the materializer must use its
        // unlinked spool rather than retain a payload-sized Data buffer.
        var bytes = Data(count: 64 * 1024 * 5 + 17)
        for index in bytes.indices { bytes[index] = UInt8(index & 0xff) }
        let entry = makeEntry(path: "parakeet_vocab.json", component: "Vocabulary", role: "vocabulary", data: bytes)
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let materializer = BoundedParakeetSourceArtifactMaterializer(
            transport: RecordingSourceTransport(payloads: [entry.path: bytes]),
            workspaceRoot: root
        )
        try materializer.begin(operationID: UUID(), remainingEntries: [entry])

        try await ParakeetSourceArtifactSinkTestSupport.withTemporarySink(entry: entry) { sink, url in
            try await materializer.materialize(entry: entry, sink: sink)
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
    }

    func test_corruptPayloadFailsBeforeSuccessfulSinkFinish() async throws {
        let good = Data("good-payload".utf8)
        let entry = makeEntry(path: "parakeet_vocab.json", component: "Vocabulary", role: "vocabulary", data: good)
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // Same size, wrong bytes — must fail digest after open, not size.
        let transport = RecordingSourceTransport(payloads: [entry.path: Data("bad-payload!".utf8)])
        let materializer = BoundedParakeetSourceArtifactMaterializer(transport: transport, workspaceRoot: root)
        try materializer.begin(operationID: UUID(), remainingEntries: [entry])

        do {
            try await ParakeetSourceArtifactSinkTestSupport.withTemporarySink(entry: entry) { sink, _ in
                try await materializer.materialize(entry: entry, sink: sink)
            }
            XCTFail("corrupt payload must not finish")
        } catch let error as ParakeetSourcePreparationError {
            XCTAssertEqual(error, .artifactDigest)
        }
        XCTAssertEqual(transport.requestSnapshot().count, 1)
    }

    func test_symlinkPayloadFailsClosed() async throws {
        let good = Data("link-payload".utf8)
        let entry = makeEntry(path: "parakeet_vocab.json", component: "Vocabulary", role: "vocabulary", data: good)
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = SymlinkSourceTransport(bytes: good)
        let materializer = BoundedParakeetSourceArtifactMaterializer(transport: transport, workspaceRoot: root)
        try materializer.begin(operationID: UUID(), remainingEntries: [entry])

        do {
            try await ParakeetSourceArtifactSinkTestSupport.withTemporarySink(entry: entry) { sink, _ in
                try await materializer.materialize(entry: entry, sink: sink)
            }
            XCTFail("symlink payload must fail")
        } catch let error as ParakeetSourcePreparationError {
            XCTAssertEqual(error, .invalidTree)
        }
    }

    func test_cancelForwardsOperationIDAndMapsTransportCancellation() async throws {
        let good = Data("cancel-me".utf8)
        let entry = makeEntry(path: "parakeet_vocab.json", component: "Vocabulary", role: "vocabulary", data: good)
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = CancellingSourceTransport()
        let materializer = BoundedParakeetSourceArtifactMaterializer(transport: transport, workspaceRoot: root)
        let operationID = UUID()
        try materializer.begin(operationID: operationID, remainingEntries: [entry])

        do {
            try await ParakeetSourceArtifactSinkTestSupport.withTemporarySink(entry: entry) { sink, _ in
                try await materializer.materialize(entry: entry, sink: sink)
            }
            XCTFail("cancelled transport must fail")
        } catch let error as ParakeetSourcePreparationError {
            XCTAssertEqual(error, .cancelled)
        }

        materializer.cancel(operationID: operationID)
        XCTAssertEqual(transport.cancelledIDs, [operationID])
    }

    func test_beginRejectsOverflowAndUnknownMaterializeDoesNotCallTransport() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = RecordingSourceTransport()
        let materializer = BoundedParakeetSourceArtifactMaterializer(transport: transport, workspaceRoot: root)
        let huge = GeneratedParakeetManifestEntry(
            path: "parakeet_vocab.json",
            size: Int64.max,
            sha256: String(repeating: "a", count: 64),
            component: "Vocabulary",
            role: "vocabulary"
        )
        XCTAssertThrowsError(try materializer.begin(operationID: UUID(), remainingEntries: [huge, huge])) { error in
            XCTAssertNotNil(error)
        }
        XCTAssertTrue(transport.requestSnapshot().isEmpty)

        let good = Data("only".utf8)
        let entry = makeEntry(path: "parakeet_vocab.json", component: "Vocabulary", role: "vocabulary", data: good)
        try materializer.begin(operationID: UUID(), remainingEntries: [entry])
        let other = makeEntry(path: "other.json", component: "Vocabulary", role: "vocabulary", data: good)
        do {
            try await ParakeetSourceArtifactSinkTestSupport.withTemporarySink(entry: other) { sink, _ in
                try await materializer.materialize(entry: other, sink: sink)
            }
            XCTFail("unknown entry must fail before transport")
        } catch let error as ParakeetSourcePreparationError {
            XCTAssertEqual(error, .invalidManifest)
        }
        XCTAssertTrue(transport.requestSnapshot().isEmpty)
    }

    func test_bootstrapAndPreparerDoNotReferenceBoundedSourceMaterializerYet() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("MacTalk/Whisper")
        let bootstrap = try String(contentsOf: root.appendingPathComponent("ParakeetBootstrap.swift"), encoding: .utf8)
        let preparer = try String(contentsOf: root.appendingPathComponent("ParakeetSourcePreparer.swift"), encoding: .utf8)
        XCTAssertFalse(bootstrap.contains("BoundedParakeetSourceArtifactMaterializer"))
        XCTAssertFalse(preparer.contains("BoundedParakeetSourceArtifactMaterializer"))
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mactalk-source-mat-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeEntry(path: String, component: String, role: String, data: Data) -> GeneratedParakeetManifestEntry {
        GeneratedParakeetManifestEntry(
            path: path,
            size: Int64(data.count),
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            component: component,
            role: role
        )
    }
}

private final class RecordingSourceTransport: BoundedModelDownloading, @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: [BoundedModelDownloadRequest]())
    private let payloads: [String: Data]

    init(payloads: [String: Data] = [:]) {
        self.payloads = payloads
    }

    func download(_ request: BoundedModelDownloadRequest) async throws -> URL {
        state.withLock { $0.append(request) }
        let data = payloads[request.identity.artifactPath] ?? Data()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("source-payload-\(UUID().uuidString).bin")
        try data.write(to: url)
        return url
    }

    func cancel(operationID: UUID) {}

    func requestSnapshot() -> [BoundedModelDownloadRequest] {
        state.withLock { $0 }
    }
}

private final class SymlinkSourceTransport: BoundedModelDownloading, @unchecked Sendable {
    let bytes: Data
    init(bytes: Data) { self.bytes = bytes }

    func download(_ request: BoundedModelDownloadRequest) async throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("source-link-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("target.bin")
        let link = directory.appendingPathComponent("link.bin")
        try bytes.write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        return link
    }

    func cancel(operationID: UUID) {}
}

private final class CancellingSourceTransport: BoundedModelDownloading, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var cancelledIDs: [UUID] = []

    func download(_ request: BoundedModelDownloadRequest) async throws -> URL {
        throw BoundedModelDownloadError.cancelled
    }

    func cancel(operationID: UUID) {
        lock.lock()
        cancelledIDs.append(operationID)
        lock.unlock()
    }
}
