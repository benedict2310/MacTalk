import CryptoKit
import Foundation
import Network
import XCTest
@testable import MacTalk

final class BoundedModelDownloadTransportTests: XCTestCase {
    private final class Capacity: VolumeCapacityProviding, @unchecked Sendable {
        let value: Int64
        private(set) var calls = 0
        init(_ value: Int64) { self.value = value }
        func availableCapacity(for url: URL) throws -> Int64 { calls += 1; return value }
    }

    private func identity(for data: Data, size: Int64? = nil, artifactPath: String = "fixture.bin", filename: String = "fixture.bin") -> DownloadArtifactIdentity {
        DownloadArtifactIdentity(schemaVersion: 1, provider: "fixture", modelID: "test", sourceRepository: "local",
                                 revision: "0123456789abcdef0123456789abcdef01234567", artifactPath: artifactPath,
                                 filename: filename, sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), sizeBytes: size ?? Int64(data.count))
    }

    private func request(identity: DownloadArtifactIdentity, server: LoopbackHTTPServer, root: URL) -> BoundedModelDownloadRequest {
        BoundedModelDownloadRequest(identity: identity, mirrors: [server.url], workspaceRoot: root)
    }

    private func seedPrefix(payload: Data, count: Int, identity: DownloadArtifactIdentity, mirror: URL, root: URL, validator: String? = nil) throws {
        let slot = root
            .appendingPathComponent("partials", isDirectory: true)
            .appendingPathComponent(try BoundedModelDownloadTransport.identityDirectoryName(for: identity), isDirectory: true)
        try FileManager.default.createDirectory(at: slot, withIntermediateDirectories: true)
        try Data(payload.prefix(count)).write(to: slot.appendingPathComponent("payload.part"), options: .atomic)
        let metadataURL = slot.appendingPathComponent("payload.part.json")
        try JSONEncoder().encode(SeedMetadata(identity: identity, mirror: mirror.absoluteString, validator: validator)).write(to: metadataURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadataURL.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: slot.appendingPathComponent("payload.part").path)
    }

    private struct SeedMetadata: Codable { let identity: DownloadArtifactIdentity; let mirror: String; let validator: String? }

    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mactalk-transport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testStrongAndDateValidatorsRejectAdversarialValues() {
        XCTAssertEqual(BoundedModelDownloadTransport.validValidator("\"opaque-tag\""), "\"opaque-tag\"")
        XCTAssertNil(BoundedModelDownloadTransport.validValidator("W/\"opaque-tag\""))
        XCTAssertNil(BoundedModelDownloadTransport.validValidator("\"embedded\"quote\""))
        XCTAssertNil(BoundedModelDownloadTransport.validValidator("\"line\u{000d}\u{000a}break\""))
        XCTAssertNil(BoundedModelDownloadTransport.validValidator("\"control\u{0001}\""))
        XCTAssertNil(BoundedModelDownloadTransport.validValidator("\"trailing\" "))
        XCTAssertEqual(BoundedModelDownloadTransport.validValidator("Sun, 06 Nov 1994 08:49:37 GMT"), "Sun, 06 Nov 1994 08:49:37 GMT")
        XCTAssertNil(BoundedModelDownloadTransport.validValidator("Sun, 6 Nov 1994 08:49:37 GMT"))
        XCTAssertNil(BoundedModelDownloadTransport.validValidator("Sun, 06 Nov 1994 08:49:37 GMT "))
        XCTAssertNil(BoundedModelDownloadTransport.validValidator("Sun, 06 Nov 1994 08:49:60 GMT"))
        XCTAssertNil(BoundedModelDownloadTransport.validValidator("Sunday, 06-Nov-94 08:49:37 GMT"))
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

    func testInvalidAggregateDiskRequirementFailsBeforeOpeningAnyRequest() async throws {
        let payload = Data("payload".utf8)
        let server = try LoopbackHTTPServer { _ in .init(body: .fixed(payload)) }
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let id = identity(for: payload)
        for required in [Int64(0), Int64(-1), id.sizeBytes - 1, Int64.max - 1] {
            do {
                _ = try await BoundedModelDownloadTransport(allowInsecureLoopback: true).download(
                    BoundedModelDownloadRequest(identity: id, mirrors: [server.url], workspaceRoot: root,
                                                aggregateDiskBytesStillRequired: required))
                XCTFail("invalid aggregate requirement must fail: \\(required)")
            } catch BoundedModelDownloadError.invalidIdentity { }
            catch { XCTFail("unexpected error for aggregate \\(required): \\(error)") }
        }
        XCTAssertTrue(server.requestLog.isEmpty)
    }

    func testMetadataReplacementIsAlwaysOldOrNewWithoutDeleteGap() throws {
        let payload = Data("metadata-payload".utf8)
        let id = identity(for: payload)
        let workspace = try root(); defer { try? FileManager.default.removeItem(at: workspace) }
        let slot = workspace.appendingPathComponent("slot", isDirectory: true)
        try FileManager.default.createDirectory(at: slot, withIntermediateDirectories: true)
        let metadataURL = slot.appendingPathComponent("payload.part.json")
        let mirror = URL(string: "http://localhost:12345/fixture")!
        let old = BoundedModelDownloadTransport.PartialMetadata(identity: id, mirror: mirror.absoluteString, validator: nil)
        var changed = id
        changed = DownloadArtifactIdentity(schemaVersion: id.schemaVersion, provider: id.provider, modelID: "changed", sourceRepository: id.sourceRepository, revision: id.revision, artifactPath: id.artifactPath, filename: id.filename, sha256: id.sha256, sizeBytes: id.sizeBytes)
        let new = BoundedModelDownloadTransport.PartialMetadata(identity: changed, mirror: mirror.absoluteString, validator: nil)
        try Self.persistMetadata(old, at: metadataURL)
        let writer = DispatchQueue.global(qos: .userInitiated)
        let finished = DispatchSemaphore(value: 0)
        writer.async {
            defer { finished.signal() }
            for index in 0..<1_000 {
                try? Self.persistMetadata(index.isMultiple(of: 2) ? old : new, at: metadataURL)
            }
        }
        var observations = 0
        var invalidObservation: Error?
        while finished.wait(timeout: .now()) == .timedOut {
            do {
                let observed = try JSONDecoder().decode(BoundedModelDownloadTransport.PartialMetadata.self, from: Data(contentsOf: metadataURL))
                XCTAssertTrue(observed == old || observed == new, "metadata reader observed an unexpected generation")
                observations += 1
            } catch {
                invalidObservation = error
                break
            }
        }
        XCTAssertNil(invalidObservation, "metadata replacement exposed a delete gap: \(String(describing: invalidObservation))")
        XCTAssertGreaterThan(observations, 0)
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
        try seedPrefix(payload: payload, count: 9_000, identity: id, mirror: server.url, root: root, validator: "\"fixture-etag\"")
        let destination = try await BoundedModelDownloadTransport(allowInsecureLoopback: true).download(BoundedModelDownloadRequest(identity: id, mirrors: [server.url], workspaceRoot: root))
        XCTAssertEqual(try Data(contentsOf: destination), payload)
        XCTAssertEqual(server.requestLog.count, 1)
        XCTAssertEqual(server.requestLog[0].headers["range"], "bytes=9000-")
        XCTAssertEqual(server.requestLog[0].headers["if-range"], "\"fixture-etag\"")
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
            if call == 1 { return .init(headers: ["ETag": "\"strong-fixture\""], body: .drop(payload, admittedBytes: 9_000)) }
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
        XCTAssertEqual(server.requestLog[1].headers["if-range"], "\"strong-fixture\"")
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

    func testFilenameAndArtifactPathMustBeStrictRelativeSafeValues() async throws {
        let payload = Data("payload".utf8)
        let server = try LoopbackHTTPServer { _ in .init(body: .fixed(payload)) }
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let invalid: [DownloadArtifactIdentity] = [
            identity(for: payload, filename: ""), identity(for: payload, filename: "."),
            identity(for: payload, filename: ".."), identity(for: payload, filename: "a/b"),
            identity(for: payload, filename: "a\0b"), identity(for: payload, artifactPath: ""),
            identity(for: payload, artifactPath: "/absolute"), identity(for: payload, artifactPath: "a//b"),
            identity(for: payload, artifactPath: "a/./b"), identity(for: payload, artifactPath: "a/../b"),
            identity(for: payload, artifactPath: "a\0b")
        ]
        for id in invalid {
            do {
                _ = try await BoundedModelDownloadTransport(allowInsecureLoopback: true).download(request(identity: id, server: server, root: root))
                XCTFail("unsafe identity must fail: \\(id.filename) / \\(id.artifactPath)")
            } catch BoundedModelDownloadError.invalidIdentity { }
            catch { XCTFail("unexpected identity error: \\(error)") }
        }
        XCTAssertTrue(server.requestLog.isEmpty)
    }

    func testDestinationRemainsDirectChildOfCompletedDirectory() async throws {
        let payload = Data("payload".utf8)
        let server = try LoopbackHTTPServer { _ in .init(body: .fixed(payload)) }
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let id = identity(for: payload, artifactPath: "nested/artifact.bin", filename: "artifact.bin")
        let destination = try await BoundedModelDownloadTransport(allowInsecureLoopback: true).download(request(identity: id, server: server, root: root))
        XCTAssertEqual(destination.deletingLastPathComponent().lastPathComponent, "completed")
        XCTAssertEqual(destination.lastPathComponent, "artifact.bin")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("nested").path))
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

    func testSameWorkspaceSameIdentitySupersessionCannotEraseNewPromotion() async throws {
        let payload = Data(repeating: 23, count: 120_000)
        let slow = try LoopbackHTTPServer { _ in .init(body: .slow(payload, chunkSize: 1_024, delay: 0.01)) }
        let fast = try LoopbackHTTPServer { _ in .init(body: .fixed(payload)) }
        let workspace = try root(); defer { try? FileManager.default.removeItem(at: workspace) }
        let transport = BoundedModelDownloadTransport(allowInsecureLoopback: true)
        let id = identity(for: payload)
        let first = Task {
            try await transport.download(BoundedModelDownloadRequest(identity: id, mirrors: [slow.url], workspaceRoot: workspace))
        }
        try await waitForRequest(slow)
        let second = Task {
            try await transport.download(BoundedModelDownloadRequest(identity: id, mirrors: [fast.url], workspaceRoot: workspace))
        }
        let destination = try await second.value
        XCTAssertEqual(try Data(contentsOf: destination), payload)
        do {
            _ = try await first.value
            XCTFail("superseded operation must fail")
        } catch BoundedModelDownloadError.superseded {
            // expected
        } catch {
            XCTFail("unexpected supersession error: \(error)")
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(try Data(contentsOf: destination), payload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("partials").appendingPathComponent(try BoundedModelDownloadTransport.identityDirectoryName(for: id)).appendingPathComponent("payload.part").path))
    }

    func testLastModifiedValidatorCanResumeWithoutETag() async throws {
        let payload = Data(repeating: 30, count: 1_024)
        let server = try LoopbackHTTPServer { request in
            if request.headers["range"] != nil {
                XCTAssertEqual(request.headers["if-range"], "Wed, 21 Oct 2015 07:28:00 GMT")
                return .init(status: 206, headers: ["Content-Length": "1020"], body: .fixed(Data(payload.dropFirst(4))), contentRange: "bytes 4-1023/1024")
            }
            return .init(headers: ["Last-Modified": "Wed, 21 Oct 2015 07:28:00 GMT"], body: .drop(payload, admittedBytes: 4))
        }
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let id = identity(for: payload)
        do { _ = try await BoundedModelDownloadTransport(allowInsecureLoopback: true).download(request(identity: id, server: server, root: root)); XCTFail("first request should interrupt") } catch BoundedModelDownloadError.interrupted { }
        _ = try await BoundedModelDownloadTransport(allowInsecureLoopback: true).download(request(identity: id, server: server, root: root))
    }

    func testWeakOrAbsentValidatorNeverBecomesIfRange() async throws {
        let payload = Data(repeating: 31, count: 1_024)
        let server = try LoopbackHTTPServer { request in
            if request.headers["range"] != nil {
                XCTAssertNil(request.headers["if-range"])
                return .init(status: 206, headers: ["ETag": "W/\"weak\"", "Content-Length": "1020"], body: .fixed(Data(payload.dropFirst(4))), contentRange: "bytes 4-1023/1024")
            }
            return .init(body: .fixed(payload))
        }
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let id = identity(for: payload)
        try seedPrefix(payload: payload, count: 4, identity: id, mirror: server.url, root: root)
        _ = try await BoundedModelDownloadTransport(allowInsecureLoopback: true).download(request(identity: id, server: server, root: root))
    }

    func testCanonicalIdentityFramingRejectsControlCharacterCollision() throws {
        let payload = Data("canonical".utf8)
        let base = identity(for: payload)
        let first = DownloadArtifactIdentity(schemaVersion: 1, provider: "a\u{1f}b", modelID: "c", sourceRepository: base.sourceRepository, revision: base.revision, artifactPath: base.artifactPath, filename: base.filename, sha256: base.sha256, sizeBytes: base.sizeBytes)
        let second = DownloadArtifactIdentity(schemaVersion: 1, provider: "a", modelID: "b\u{1f}c", sourceRepository: base.sourceRepository, revision: base.revision, artifactPath: base.artifactPath, filename: base.filename, sha256: base.sha256, sizeBytes: base.sizeBytes)
        XCTAssertNotEqual(try BoundedModelDownloadTransport.identityDirectoryName(for: first), try BoundedModelDownloadTransport.identityDirectoryName(for: second))
        let shaVariant = DownloadArtifactIdentity(schemaVersion: base.schemaVersion, provider: base.provider, modelID: base.modelID, sourceRepository: base.sourceRepository, revision: base.revision, artifactPath: base.artifactPath, filename: base.filename, sha256: String(repeating: "a", count: 64), sizeBytes: base.sizeBytes)
        let sizeVariant = DownloadArtifactIdentity(schemaVersion: base.schemaVersion, provider: base.provider, modelID: base.modelID, sourceRepository: base.sourceRepository, revision: base.revision, artifactPath: base.artifactPath, filename: base.filename, sha256: base.sha256, sizeBytes: base.sizeBytes + 1)
        XCTAssertNotEqual(try BoundedModelDownloadTransport.identityDirectoryName(for: base), try BoundedModelDownloadTransport.identityDirectoryName(for: shaVariant))
        XCTAssertNotEqual(try BoundedModelDownloadTransport.identityDirectoryName(for: base), try BoundedModelDownloadTransport.identityDirectoryName(for: sizeVariant))
    }

    func testCancellationAfterBodyBeforePromotionPreventsCommit() async throws {
        let payload = Data(repeating: 24, count: 32_000)
        let server = try LoopbackHTTPServer { _ in .init(body: .fixed(payload)) }
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let operationID = UUID()
        let transport = BoundedModelDownloadTransport(allowInsecureLoopback: true)
        let request = BoundedModelDownloadRequest(identity: identity(for: payload), mirrors: [server.url], operationID: operationID, workspaceRoot: root, progress: { received, total in
            if received == total { transport.cancel(operationID: operationID) }
        })
        do { _ = try await transport.download(request); XCTFail("cancellation after body must prevent promotion") }
        catch BoundedModelDownloadError.cancelled { }
        let destination = root.appendingPathComponent("completed/fixture.bin")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testCancellationAfterCommitClaimPreservesCommittedResult() async throws {
        let payload = Data("claim-wins".utf8)
        let server = try LoopbackHTTPServer { _ in .init(body: .fixed(payload)) }
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let operationID = UUID()
        let cancellation = CancellationProbe(operationID: operationID)
        let transport = BoundedModelDownloadTransport(allowInsecureLoopback: true, afterGenerationClaim: { _ in
            cancellation.transport?.cancel(operationID: operationID)
        })
        cancellation.transport = transport
        let request = BoundedModelDownloadRequest(identity: identity(for: payload), mirrors: [server.url], operationID: operationID, workspaceRoot: root)
        let destination = try await transport.download(request)
        XCTAssertEqual(try Data(contentsOf: destination), payload)
        XCTAssertNil(transport.terminalErrorForTesting(1), "post-commit cancellation must not overwrite the committed terminal state")
    }

    func testAnchoredWorkspacePromotionDoesNotFollowRootReplacement() async throws {
        let payload = Data("anchored-payload".utf8)
        let server = try LoopbackHTTPServer { _ in .init(body: .fixed(payload)) }
        let root = try root(); let moved = root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + "-moved")
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: moved) }
        let id = identity(for: payload)
        let transport = BoundedModelDownloadTransport(allowInsecureLoopback: true)
        let request = BoundedModelDownloadRequest(identity: id, mirrors: [server.url], workspaceRoot: root, progress: { received, total in
            if received == total {
                try? FileManager.default.moveItem(at: root, to: moved)
                try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            }
        })
        _ = try await transport.download(request)
        XCTAssertEqual(try Data(contentsOf: moved.appendingPathComponent("completed/\(id.filename)")), payload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("completed/\(id.filename)").path))
    }

    func testAnchoredIntermediateDirectoryReplacementCannotCaptureWrites() async throws {
        let payload = Data("anchored-intermediate".utf8)
        let server = try LoopbackHTTPServer { _ in .init(body: .fixed(payload)) }
        let root = try root(); let movedPartials = root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + "-partials-moved")
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: movedPartials) }
        let transport = BoundedModelDownloadTransport(allowInsecureLoopback: true)
        let request = BoundedModelDownloadRequest(identity: identity(for: payload), mirrors: [server.url], workspaceRoot: root, progress: { received, total in
            if received == total {
                let partials = root.appendingPathComponent("partials", isDirectory: true)
                try? FileManager.default.moveItem(at: partials, to: movedPartials)
                try? FileManager.default.createDirectory(at: partials, withIntermediateDirectories: true)
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: partials.path)
            }
        })
        let destination = try await transport.download(request)
        XCTAssertEqual(try Data(contentsOf: destination), payload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("partials").appendingPathComponent(try BoundedModelDownloadTransport.identityDirectoryName(for: request.identity)).appendingPathComponent("payload.part").path))

    }

    func testUnknownCancellationDoesNotPoisonFutureReuseOfCallerID() async throws {
        let payload = Data("unknown-cancel".utf8)
        let server = try LoopbackHTTPServer { _ in .init(body: .fixed(payload)) }
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let transport = BoundedModelDownloadTransport(allowInsecureLoopback: true)
        for _ in 0..<100 {
            transport.cancel(operationID: id)
        }
        XCTAssertEqual(transport.cancellationStateCountForTesting(), 0)
        let request = BoundedModelDownloadRequest(identity: identity(for: payload), mirrors: [server.url], operationID: id, workspaceRoot: root)
        let destination = try await transport.download(request)
        XCTAssertEqual(try Data(contentsOf: destination), payload)
        XCTAssertEqual(transport.cancellationStateCountForTesting(), 0)
    }

    func testCancellationAfterClaimDoesNotPoisonFutureReuseOfCallerID() async throws {
        let payload = Data("claimed-cancel".utf8)
        let server = try LoopbackHTTPServer { _ in .init(body: .fixed(payload)) }
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let transport = BoundedModelDownloadTransport(allowInsecureLoopback: true)
        let request = BoundedModelDownloadRequest(identity: identity(for: payload), mirrors: [server.url], operationID: id, workspaceRoot: root)
        _ = try await transport.download(request)
        transport.cancel(operationID: id)
        XCTAssertEqual(transport.cancellationStateCountForTesting(), 0)
        let second = try await transport.download(BoundedModelDownloadRequest(identity: identity(for: payload), mirrors: [server.url], operationID: id, workspaceRoot: root))
        XCTAssertEqual(try Data(contentsOf: second), payload)
        XCTAssertEqual(server.requestLog.count, 2)
    }

    func testDuplicateCallerIDsAreRejectedBeforeSideEffects() async throws {
        let payload = Data(repeating: 37, count: 100_000)
        let slow = try LoopbackHTTPServer { _ in .init(body: .slow(payload, chunkSize: 512, delay: 0.002)) }
        let fast = try LoopbackHTTPServer { _ in .init(body: .fixed(payload)) }
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID(); let identity = identity(for: payload)
        let transport = BoundedModelDownloadTransport(allowInsecureLoopback: true)
        let first = Task { try await transport.download(BoundedModelDownloadRequest(identity: identity, mirrors: [slow.url], operationID: id, workspaceRoot: root)) }
        try await waitForRequest(slow)
        let second = Task { try await transport.download(BoundedModelDownloadRequest(identity: identity, mirrors: [fast.url], operationID: id, workspaceRoot: root)) }
        do { _ = try await second.value; XCTFail("duplicate caller ID must be rejected") }
        catch BoundedModelDownloadError.duplicateOperationID { }
        catch { XCTFail("duplicate caller ID must be rejected before side effects, got \(error)") }
        _ = try await first.value
        XCTAssertEqual(slow.requestLog.count, 1)
        XCTAssertTrue(fast.requestLog.isEmpty)
    }

    func testLoopbackStopIsIdempotentAndClosesListener() throws {
        let server = try LoopbackHTTPServer { _ in .init(body: .fixed(Data())) }
        XCTAssertFalse(server.isStopped)
        server.stop(); server.stop()
        XCTAssertTrue(server.isStopped)
        XCTAssertEqual(server.activeConnectionCount, 0)
    }

    func testLoopbackQueuedAcceptAfterStopNeverStartsOrResponds() throws {
        let enteredAccept = DispatchSemaphore(value: 0)
        let releaseAccept = DispatchSemaphore(value: 0)
        let server = try LoopbackHTTPServer(response: { _ in
            XCTFail("a connection accepted after stop must not respond")
            return .init(body: .fixed(Data("unexpected".utf8)))
        }, beforeAcceptStateCheck: {
            enteredAccept.signal()
            _ = releaseAccept.wait(timeout: .now() + 5)
        })
        let client = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: server.port)!,
            using: .tcp
        )
        let clientQueue = DispatchQueue(label: "com.mactalk.loopback-stop-test")
        client.start(queue: clientQueue)
        XCTAssertEqual(enteredAccept.wait(timeout: .now() + 5), .success)
        server.stop()
        releaseAccept.signal()
        for _ in 0..<100 where server.activeConnectionCount != 0 {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(server.isStopped)
        XCTAssertEqual(server.activeConnectionCount, 0)
        XCTAssertTrue(server.requestLog.isEmpty)
        server.stop()
        client.cancel()
    }

    private final class CancellationProbe: @unchecked Sendable {
        let operationID: UUID
        weak var transport: BoundedModelDownloadTransport?

        init(operationID: UUID) {
            self.operationID = operationID
        }
    }

    private static func persistMetadata(_ metadata: BoundedModelDownloadTransport.PartialMetadata, at url: URL) throws {
        try JSONEncoder().encode(metadata).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func waitForRequest(_ server: LoopbackHTTPServer) async throws {
        for _ in 0..<100 {
            if !server.requestLog.isEmpty { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("loopback server did not receive a request")
    }
}
