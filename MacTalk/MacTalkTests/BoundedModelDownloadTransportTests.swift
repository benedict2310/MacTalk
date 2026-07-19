import CryptoKit
import Foundation
import XCTest
@testable import MacTalk

final class BoundedModelDownloadTransportTests: XCTestCase {
    private final class Capacity: VolumeCapacityProviding, @unchecked Sendable {
        let value: Int64
        private(set) var calls = 0
        init(_ value: Int64) { self.value = value }
        func availableCapacity(for url: URL) throws -> Int64 { calls += 1; return value }
    }

    private func identity(for data: Data, size: Int64? = nil) -> DownloadArtifactIdentity {
        DownloadArtifactIdentity(schemaVersion: 1, provider: "fixture", modelID: "test", sourceRepository: "local",
                                 revision: "0123456789abcdef0123456789abcdef01234567", artifactPath: "fixture.bin",
                                 filename: "fixture.bin", sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), sizeBytes: size ?? Int64(data.count))
    }

    private func request(identity: DownloadArtifactIdentity, server: LoopbackHTTPServer, root: URL) -> BoundedModelDownloadRequest {
        BoundedModelDownloadRequest(identity: identity, mirrors: [server.url], workspaceRoot: root)
    }

    private func seedPrefix(payload: Data, count: Int, identity: DownloadArtifactIdentity, mirror: URL, root: URL) throws {
        let slot = root
            .appendingPathComponent("partials", isDirectory: true)
            .appendingPathComponent(try BoundedModelDownloadTransport.identityDirectoryName(for: identity), isDirectory: true)
        try FileManager.default.createDirectory(at: slot, withIntermediateDirectories: true)
        try Data(payload.prefix(count)).write(to: slot.appendingPathComponent("payload.part"), options: .atomic)
        try JSONEncoder().encode(SeedMetadata(identity: identity, mirror: mirror.absoluteString)).write(to: slot.appendingPathComponent("payload.part.json"), options: .atomic)
    }

    private struct SeedMetadata: Codable { let identity: DownloadArtifactIdentity; let mirror: String }

    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mactalk-transport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testProductionTransportRejectsInsecureMirrors() async throws {
        let payload = Data("payload".utf8)
        let server = try LoopbackHTTPServer { _ in .init(body: .fixed(payload)) }
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        do {
            _ = try await BoundedModelDownloadTransport().download(request(identity: identity(for: payload), server: server, root: root))
            XCTFail("production transport must reject HTTP mirrors")
        } catch BoundedModelDownloadError.invalidMirror { }
        XCTAssertTrue(server.requestLog.isEmpty)
    }

    func test_exactFixedLengthSuccessUsesActualDataTaskAdapter() async throws {
        let payload = Data("bounded transport".utf8)
        let server = try LoopbackHTTPServer { _ in .init(body: .fixed(payload)) }
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = try await BoundedModelDownloadTransport(allowInsecureLoopback: true).download(request(identity: identity(for: payload), server: server, root: root))
        XCTAssertEqual(try Data(contentsOf: destination), payload)
        XCTAssertEqual(server.requestLog.count, 1)
        XCTAssertEqual(server.requestLog[0].headers["accept-encoding"], "identity")
    }

    func testWrongContentLengthIsRejectedBeforeBodyAdmission() async throws {
        let payload = Data("payload".utf8)
        let server = try LoopbackHTTPServer { _ in .init(headers: ["Content-Length": "999"], body: .fixed(payload)) }
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        do {
            _ = try await BoundedModelDownloadTransport(allowInsecureLoopback: true).download(request(identity: identity(for: payload), server: server, root: root))
            XCTFail("wrong length must fail")
        } catch BoundedModelDownloadError.transport { XCTFail("must not fall through to generic success") }
        catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("completed/fixture.bin").path))
    }

    func testChunkedExactBodyCompletesWithoutContentLength() async throws {
        let payload = Data(repeating: 7, count: 20_000)
        let server = try LoopbackHTTPServer { _ in .init(body: .chunked(payload, chunkSize: 137)) }
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = try await BoundedModelDownloadTransport(allowInsecureLoopback: true).download(request(identity: identity(for: payload), server: server, root: root))
        XCTAssertEqual(try Data(contentsOf: destination), payload)
    }

    func testOversizedChunkedBodyNeverPromotesArtifact() async throws {
        let payload = Data(repeating: 8, count: 20_001)
        let expected = Data(repeating: 8, count: 20_000)
        let server = try LoopbackHTTPServer { _ in .init(body: .chunked(payload, chunkSize: 101)) }
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        do { _ = try await BoundedModelDownloadTransport(allowInsecureLoopback: true).download(request(identity: identity(for: expected), server: server, root: root)); XCTFail("oversized body must fail") } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("completed/fixture.bin").path))
        let slot = root.appendingPathComponent("partials", isDirectory: true)
            .appendingPathComponent(try BoundedModelDownloadTransport.identityDirectoryName(for: identity(for: expected)), isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: slot.appendingPathComponent("payload.part").path))
    }

    func testChecksumFailureDeletesPartialAndFinalState() async throws {
        let payload = Data(repeating: 17, count: 1_024)
        let wrongDigest = Data(repeating: 18, count: payload.count)
        let server = try LoopbackHTTPServer { _ in .init(body: .fixed(payload)) }
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let id = identity(for: wrongDigest)
        do {
            _ = try await BoundedModelDownloadTransport(allowInsecureLoopback: true).download(request(identity: id, server: server, root: root))
            XCTFail("checksum failure must fail")
        } catch BoundedModelDownloadError.checksumMismatch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("completed/fixture.bin").path))
        let slot = root.appendingPathComponent("partials", isDirectory: true).appendingPathComponent(try BoundedModelDownloadTransport.identityDirectoryName(for: id), isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: slot.appendingPathComponent("payload.part").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: slot.appendingPathComponent("payload.part.json").path))
    }

    func testLowSpaceFailsBeforeOpeningAnyRequest() async throws {
        let payload = Data("payload".utf8)
        let server = try LoopbackHTTPServer { _ in .init(body: .fixed(payload)) }
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let capacity = Capacity(0)
        do {
            _ = try await BoundedModelDownloadTransport(capacity: capacity, allowInsecureLoopback: true).download(request(identity: identity(for: payload), server: server, root: root))
            XCTFail("low capacity must fail")
        } catch BoundedModelDownloadError.insufficientSpace { }
        XCTAssertEqual(capacity.calls, 1)
        XCTAssertTrue(server.requestLog.isEmpty)
    }

    func testInterruptedPrefixResumesWithExactRangeAndIfRange() async throws {
        let payload = Data(repeating: 3, count: 32_000)
        let server = try LoopbackHTTPServer { incoming in
            guard let range = incoming.headers["range"], range.hasPrefix("bytes=") else { return .init(status: 416) }
            let start = Int(range.dropFirst(6).split(separator: "-").first ?? "0") ?? 0
            return .init(status: 206, headers: ["Content-Length": String(payload.count - start)], body: .fixed(Data(payload.dropFirst(start))), contentRange: "bytes \(start)-\(payload.count - 1)/\(payload.count)")
        }
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let id = identity(for: payload)
        try seedPrefix(payload: payload, count: 9_000, identity: id, mirror: server.url, root: root)
        let destination = try await BoundedModelDownloadTransport(allowInsecureLoopback: true).download(BoundedModelDownloadRequest(identity: id, mirrors: [server.url], workspaceRoot: root))
        XCTAssertEqual(try Data(contentsOf: destination), payload)
        XCTAssertEqual(server.requestLog.count, 1)
        XCTAssertEqual(server.requestLog[0].headers["range"], "bytes=9000-")
        XCTAssertEqual(server.requestLog[0].headers["if-range"], id.sha256)
    }

    func testIgnoredRangeGetsOneCleanSameMirrorRetry() async throws {
        let payload = Data(repeating: 4, count: 24_000)
        let server = try LoopbackHTTPServer { _ in .init(body: .fixed(payload)) }
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let id = identity(for: payload)
        try seedPrefix(payload: payload, count: 4_000, identity: id, mirror: server.url, root: root)
        let destination = try await BoundedModelDownloadTransport(allowInsecureLoopback: true).download(BoundedModelDownloadRequest(identity: id, mirrors: [server.url], workspaceRoot: root))
        XCTAssertEqual(try Data(contentsOf: destination), payload)
        XCTAssertEqual(server.requestLog.count, 2)
        XCTAssertNotNil(server.requestLog[0].headers["range"])
        XCTAssertNil(server.requestLog[1].headers["range"])
    }

    func testCredentialIsSentOnlyToOfficialHTTPSAndStrippedByRedirect() async throws {
        let payload = Data("payload".utf8)
        let redirected = try LoopbackHTTPServer { _ in .init(body: .fixed(payload)) }
        let origin = try LoopbackHTTPServer { _ in .init(redirect: redirected.url.absoluteString) }
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        do {
            _ = try await BoundedModelDownloadTransport(allowInsecureLoopback: true, allowTestCredentialsOnLoopback: true).download(BoundedModelDownloadRequest(identity: identity(for: payload), mirrors: [origin.url], workspaceRoot: root, credentialToken: "secret"))
        } catch { }
        XCTAssertEqual(origin.requestLog.first?.headers["authorization"], "Bearer secret")
        XCTAssertNil(redirected.requestLog.first?.headers["authorization"])
    }

    func testInterruptedBodyPersistsBoundedPrefixAndResumesOnSameMirror() async throws {
        let payload = Data(repeating: 3, count: 32_000)
        final class Counter: @unchecked Sendable { let lock = NSLock(); var calls = 0 }
        let counter = Counter()
        let server = try LoopbackHTTPServer { request in
            counter.lock.lock(); counter.calls += 1; let call = counter.calls; counter.lock.unlock()
            if call == 1 { return .init(body: .drop(payload, admittedBytes: 9_000)) }
            guard let range = request.headers["range"], range == "bytes=9000-" else { return .init(status: 416) }
            return .init(status: 206, headers: ["Content-Length": "23000"], body: .fixed(Data(payload.dropFirst(9_000))), contentRange: "bytes 9000-31999/32000")
        }
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let id = identity(for: payload)
        do {
            _ = try await BoundedModelDownloadTransport(allowInsecureLoopback: true).download(request(identity: id, server: server, root: root))
            XCTFail("an interrupted transfer must end with a resumable prefix")
        } catch BoundedModelDownloadError.interrupted { }
        let slot = root.appendingPathComponent("partials", isDirectory: true)
            .appendingPathComponent(try BoundedModelDownloadTransport.identityDirectoryName(for: id), isDirectory: true)
        XCTAssertEqual(try Data(contentsOf: slot.appendingPathComponent("payload.part")), Data(payload.prefix(9_000)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: slot.appendingPathComponent("payload.part.json").path))
        let destination = try await BoundedModelDownloadTransport(allowInsecureLoopback: true).download(request(identity: id, server: server, root: root))
        XCTAssertEqual(try Data(contentsOf: destination), payload)
        XCTAssertEqual(server.requestLog[1].headers["range"], "bytes=9000-")
    }

    func testEachIdentityFieldPreventsResumeReuse() async throws {
        let payload = Data(repeating: 11, count: 1_024)
        let base = identity(for: payload)
        let first = try LoopbackHTTPServer { _ in .init(body: .fixed(payload)) }
        let second = try LoopbackHTTPServer { request in
            XCTAssertNil(request.headers["range"])
            return .init(body: .fixed(payload))
        }
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let variants: [DownloadArtifactIdentity] = [
            .init(schemaVersion: 2, provider: base.provider, modelID: base.modelID, sourceRepository: base.sourceRepository, revision: base.revision, artifactPath: base.artifactPath, filename: base.filename, sha256: base.sha256, sizeBytes: base.sizeBytes),
            .init(schemaVersion: base.schemaVersion, provider: "other", modelID: base.modelID, sourceRepository: base.sourceRepository, revision: base.revision, artifactPath: base.artifactPath, filename: base.filename, sha256: base.sha256, sizeBytes: base.sizeBytes),
            .init(schemaVersion: base.schemaVersion, provider: base.provider, modelID: "other", sourceRepository: base.sourceRepository, revision: base.revision, artifactPath: base.artifactPath, filename: base.filename, sha256: base.sha256, sizeBytes: base.sizeBytes),
            .init(schemaVersion: base.schemaVersion, provider: base.provider, modelID: base.modelID, sourceRepository: "other", revision: base.revision, artifactPath: base.artifactPath, filename: base.filename, sha256: base.sha256, sizeBytes: base.sizeBytes),
            .init(schemaVersion: base.schemaVersion, provider: base.provider, modelID: base.modelID, sourceRepository: base.sourceRepository, revision: String(repeating: "a", count: 40), artifactPath: base.artifactPath, filename: base.filename, sha256: base.sha256, sizeBytes: base.sizeBytes),
            .init(schemaVersion: base.schemaVersion, provider: base.provider, modelID: base.modelID, sourceRepository: base.sourceRepository, revision: base.revision, artifactPath: "other.bin", filename: base.filename, sha256: base.sha256, sizeBytes: base.sizeBytes),
            .init(schemaVersion: base.schemaVersion, provider: base.provider, modelID: base.modelID, sourceRepository: base.sourceRepository, revision: base.revision, artifactPath: base.artifactPath, filename: "other.bin", sha256: base.sha256, sizeBytes: base.sizeBytes),
        ]
        for variant in variants {
            try seedPrefix(payload: payload, count: 5, identity: base, mirror: first.url, root: root)
            _ = try await BoundedModelDownloadTransport(allowInsecureLoopback: true).download(BoundedModelDownloadRequest(identity: variant, mirrors: [second.url], workspaceRoot: root))
        }
        XCTAssertEqual(second.requestLog.count, variants.count)
    }

    func testMirrorIdentityPreventsResumeReuse() async throws {
        let payload = Data(repeating: 12, count: 1_024)
        let first = try LoopbackHTTPServer { _ in .init(body: .fixed(payload)) }
        let second = try LoopbackHTTPServer { request in
            XCTAssertNil(request.headers["range"])
            return .init(body: .fixed(payload))
        }
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let id = identity(for: payload)
        try seedPrefix(payload: payload, count: 5, identity: id, mirror: first.url, root: root)
        let destination = try await BoundedModelDownloadTransport(allowInsecureLoopback: true).download(BoundedModelDownloadRequest(identity: id, mirrors: [second.url], workspaceRoot: root))
        XCTAssertEqual(try Data(contentsOf: destination), payload)
        XCTAssertEqual(second.requestLog.count, 1)
    }

    func testMalformedContentRangeAndRangeNotSatisfiableFailClosed() async throws {
        let payload = Data(repeating: 13, count: 1_024)
        let server = try LoopbackHTTPServer { request in
            if request.headers["range"] != nil {
                return .init(status: 206, headers: ["Content-Length": "1019"], body: .fixed(Data(payload.dropFirst(5))), contentRange: "bytes 6-1023/1024")
            }
            return .init(status: 206, headers: ["Content-Length": "1024"], body: .fixed(payload), contentRange: "bytes 0-1023/1024")
        }
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let id = identity(for: payload)
        try seedPrefix(payload: payload, count: 5, identity: id, mirror: server.url, root: root)
        do {
            _ = try await BoundedModelDownloadTransport(allowInsecureLoopback: true).download(request(identity: id, server: server, root: root))
            XCTFail("malformed Content-Range must fail")
        } catch BoundedModelDownloadError.unexpectedStatus(206) { }
        XCTAssertEqual(server.requestLog.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("completed/fixture.bin").path))
    }

    func testCancellationDeletesPartialAndDoesNotTryAnotherMirror() async throws {
        let payload = Data(repeating: 14, count: 200_000)
        let server = try LoopbackHTTPServer { _ in .init(body: .slow(payload, chunkSize: 1_024, delay: 0.01)) }
        let fallback = try LoopbackHTTPServer { _ in XCTFail("cancellation must not try a later mirror"); return .init(body: .fixed(payload)) }
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let id = identity(for: payload)
        let task = Task { try await BoundedModelDownloadTransport(allowInsecureLoopback: true).download(BoundedModelDownloadRequest(identity: id, mirrors: [server.url, fallback.url], workspaceRoot: root)) }
        try await waitForRequest(server)
        task.cancel()
        do { _ = try await task.value; XCTFail("cancellation must fail") }
        catch BoundedModelDownloadError.cancelled { }
        catch { XCTFail("unexpected cancellation error: \(error)") }
        let slot = root.appendingPathComponent("partials", isDirectory: true).appendingPathComponent(try BoundedModelDownloadTransport.identityDirectoryName(for: id), isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: slot.appendingPathComponent("payload.part").path))
        XCTAssertTrue(fallback.requestLog.isEmpty)
    }

    func testSupersessionTerminatesOldOperationWithoutPublishing() async throws {
        let payloadA = Data(repeating: 15, count: 200_000)
        let payloadB = Data(repeating: 16, count: 1_024)
        let slow = try LoopbackHTTPServer { _ in .init(body: .slow(payloadA, chunkSize: 1_024, delay: 0.01)) }
        let fast = try LoopbackHTTPServer { _ in .init(body: .fixed(payloadB)) }
        let rootA = try root(); defer { try? FileManager.default.removeItem(at: rootA) }
        let rootB = try root(); defer { try? FileManager.default.removeItem(at: rootB) }
        let transport = BoundedModelDownloadTransport(allowInsecureLoopback: true)
        let idA = identity(for: payloadA)
        let idB = identity(for: payloadB)
        let first = Task { try await transport.download(BoundedModelDownloadRequest(identity: idA, mirrors: [slow.url], workspaceRoot: rootA)) }
        try await waitForRequest(slow)
        let second = Task { try await transport.download(BoundedModelDownloadRequest(identity: idB, mirrors: [fast.url], workspaceRoot: rootB)) }
        let destination = try await second.value
        XCTAssertEqual(try Data(contentsOf: destination), payloadB)
        do { _ = try await first.value; XCTFail("superseded operation must fail") }
        catch BoundedModelDownloadError.superseded { }
        catch { XCTFail("unexpected supersession error: \(error)") }
    }

    private func waitForRequest(_ server: LoopbackHTTPServer) async throws {
        for _ in 0..<100 {
            if !server.requestLog.isEmpty { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("loopback server did not receive a request")
    }
}
