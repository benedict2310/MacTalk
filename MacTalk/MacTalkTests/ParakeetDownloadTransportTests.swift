import CryptoKit
import Foundation
import XCTest
@testable import MacTalk

private final class TestMutex: @unchecked Sendable {
    private let mutex = NSLock()
    func lock() { mutex.lock() }
    func unlock() { mutex.unlock() }
}

private final class AtomicString: @unchecked Sendable {
    private let mutex = NSLock()
    private var storage = ""
    func set(_ value: String) {
        mutex.lock()
        storage = value
        mutex.unlock()
    }
    var value: String {
        mutex.lock()
        let result = storage
        mutex.unlock()
        return result
    }
}

private final class StateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ParakeetModelDownloader.State] = []

    func append(_ value: ParakeetModelDownloader.State) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var snapshot: [ParakeetModelDownloader.State] {
        lock.lock()
        let result = values
        lock.unlock()
        return result
    }
}

private final class AtomicCounter: @unchecked Sendable {
    private let mutex = NSLock()
    private var value = 0
    func increment() -> Int {
        mutex.lock()
        value += 1
        let result = value
        mutex.unlock()
        return result
    }

    func current() -> Int {
        mutex.lock()
        let result = value
        mutex.unlock()
        return result
    }
}

private final class AsyncLatch: @unchecked Sendable {
    private let mutex = NSLock()
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            mutex.lock()
            waiter = continuation
            mutex.unlock()
        }
    }

    func signal() {
        mutex.lock()
        let continuation = waiter
        waiter = nil
        mutex.unlock()
        continuation?.resume()
    }
}

private struct FailingParakeetTransport: BoundedModelDownloading {
    let failure: BoundedModelDownloadError

    func download(_ request: BoundedModelDownloadRequest) async throws -> URL {
        throw failure
    }

    func cancel(operationID: UUID) {}
}

private final class ProgressParakeetTransport: BoundedModelDownloading, @unchecked Sendable {
    func download(_ request: BoundedModelDownloadRequest) async throws -> URL {
        request.progress?(2, 3)
        request.progress?(1, 3)
        request.progress?(3, 3)
        request.progress?(3, 3)
        let bytes = request.identity.artifactPath == "a.bin" ? Data("abc".utf8) : Data("de".utf8)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("parakeet-progress-\(UUID().uuidString)")
        try bytes.write(to: url)
        return url
    }

    func cancel(operationID: UUID) {}
}

private final class RecordingParakeetTransport: BoundedModelDownloading, @unchecked Sendable {
    private let lock = TestMutex()
    private(set) var requests: [BoundedModelDownloadRequest] = []
    private(set) var cancelledOperationIDs: [UUID] = []
    let cancellation = DispatchSemaphore(value: 0)

    func download(_ request: BoundedModelDownloadRequest) async throws -> URL {
        lock.lock()
        requests.append(request)
        lock.unlock()
        let bytes = request.identity.artifactPath == "a.bin" ? Data("abc".utf8) : Data("de".utf8)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("parakeet-source-\(UUID().uuidString)")
        try bytes.write(to: url)
        return url
    }

    func cancel(operationID: UUID) {
        lock.lock()
        cancelledOperationIDs.append(operationID)
        lock.unlock()
        cancellation.signal()
    }
}

private struct ZeroCapacity: VolumeCapacityProviding, Sendable {
    func availableCapacity(for url: URL) throws -> Int64 { 0 }
}

/// Test-only adapter: production creates the immutable official request, then
/// this adapter rewrites only the URL before the real bounded transport sees it.
private final class LoopbackParakeetTransport: BoundedModelDownloading, @unchecked Sendable {
    private let serverURL: URL
    private let transport: BoundedModelDownloadTransport
    private let expectedAggregates: [String: Int64]
    private let lock = TestMutex()
    private(set) var requests: [BoundedModelDownloadRequest] = []
    private(set) var violations: [String] = []

    init(serverURL: URL, entries: [ParakeetManifestEntry],
         transport: BoundedModelDownloadTransport = BoundedModelDownloadTransport(allowInsecureLoopback: true)) {
        self.serverURL = serverURL
        self.transport = transport
        var aggregates: [String: Int64] = [:]
        for (index, entry) in entries.enumerated() {
            aggregates[entry.path] = try? ParakeetModelDownloader.remainingBytes(from: index, entries: entries)
        }
        self.expectedAggregates = aggregates.compactMapValues { $0 }
    }

    func download(_ request: BoundedModelDownloadRequest) async throws -> URL {
        let expectedMirror = try ParakeetModelDownloader.mirrorURL(
            for: ParakeetManifestEntry(path: request.identity.artifactPath,
                                       size: request.identity.sizeBytes,
                                       sha256: request.identity.sha256))
        let expectedIdentity = try ParakeetModelDownloader.downloadIdentity(
            for: ParakeetManifestEntry(path: request.identity.artifactPath,
                                       size: request.identity.sizeBytes,
                                       sha256: request.identity.sha256))
        let expectedCredential = ProcessInfo.processInfo.environment["HF_TOKEN"]
            ?? ProcessInfo.processInfo.environment["HUGGING_FACE_HUB_TOKEN"]
            ?? ProcessInfo.processInfo.environment["HUGGINGFACEHUB_API_TOKEN"]
        lock.lock()
        requests.append(request)
        let exactMirror = request.mirrors == [expectedMirror]
        let exactIdentity = request.identity == expectedIdentity
        let exactAggregate = expectedAggregates[request.identity.artifactPath] == request.aggregateDiskBytesStillRequired
        let exactCredential = request.credentialToken == expectedCredential
        if !exactMirror { violations.append("mirror") }
        if !exactIdentity { violations.append("identity") }
        if !exactAggregate { violations.append("aggregate") }
        if !exactCredential { violations.append("credential") }
        lock.unlock()
        XCTAssertTrue(exactMirror, "production request must use the official immutable mirror")
        XCTAssertTrue(exactIdentity, "production request must preserve official artifact identity")
        XCTAssertTrue(exactAggregate, "production request must preserve exact aggregate requirement")
        XCTAssertTrue(exactCredential, "production request must preserve official credential policy")

        let rewritten = BoundedModelDownloadRequest(
            identity: request.identity,
            mirrors: [serverURL.appendingPathComponent(request.identity.artifactPath)],
            operationID: request.operationID,
            workspaceRoot: request.workspaceRoot,
            aggregateDiskBytesStillRequired: request.aggregateDiskBytesStillRequired,
            credentialToken: request.credentialToken,
            progress: request.progress)
        return try await transport.download(rewritten)
    }

    func cancel(operationID: UUID) {
        transport.cancel(operationID: operationID)
    }
}

final class ParakeetDownloadTransportTests: XCTestCase {
    func test_activationHasACommitOwnershipBoundaryBeforeRenames() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("MacTalk/Whisper/ParakeetModelDownloader.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertTrue(source.contains("claimActivation"),
                      "activation must claim generation ownership immediately before renames")
        XCTAssertTrue(source.contains("activationHook"),
                      "activation ownership must be testable after an arbitrary pre-activation hook")
        XCTAssertFalse(source.contains("activationBodyHook"),
                       "activation must not await an arbitrary callback under the commit lock")
    }

    func test_bootstrapRoutesCompiledLoadThroughValidatedSharedLeaseBoundary() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("MacTalk/Whisper/ParakeetBootstrap.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertTrue(source.contains("withValidatedSharedLease"),
                      "compiled path loading must execute inside the downloader's validated shared lease")
        XCTAssertTrue(source.contains("let models = try await downloader.withValidatedSharedLease"),
                      "Bootstrap must compose the native path load through the boundary")
    }

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

    func test_validatedSharedLeaseSpansCompiledLoadBodyAndBlocksExclusiveActivation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("parakeet-load-lease-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let entries = [
            ParakeetManifestEntry(path: "a.bin", size: 3, sha256: SHA256.hash(data: Data("abc".utf8)).map { String(format: "%02x", $0) }.joined()),
            ParakeetManifestEntry(path: "b.bin", size: 2, sha256: SHA256.hash(data: Data("de".utf8)).map { String(format: "%02x", $0) }.joined())
        ]
        let downloader = ParakeetModelDownloader(modelsRoot: root, manifest: entries, transport: RecordingParakeetTransport())
        _ = try await downloader.downloadIfNeeded()

        let entered = expectation(description: "compiled load body entered")
        let releaseBody = AsyncLatch()
        let body = Task {
            try await downloader.withValidatedSharedLease { _ in
                entered.fulfill()
                await releaseBody.wait()
                return true
            }
        }
        await fulfillment(of: [entered], timeout: 2)

        let independentLock = ParakeetStoreFileLock(storeParent: root)
        XCTAssertNil(try independentLock.tryAcquire(.exclusive),
                     "activation must be blocked while compiled path loading owns its shared lease")
        releaseBody.signal()
        let loaded = try await body.value
        XCTAssertTrue(loaded)
        let successor = try XCTUnwrap(try independentLock.tryAcquire(.exclusive))
        successor.release()
    }

    func test_supersededOperationCannotActivateAfterPreActivationBarrier() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("parakeet-supersession-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("abc".utf8)
        let entry = ParakeetManifestEntry(path: "a.bin", size: 3,
                                          sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        let firstHookEntered = AsyncLatch()
        let releaseFirstHook = AsyncLatch()
        let counter = AtomicCounter()
        let done = expectation(description: "only the current operation publishes done")
        let terminalCount = AtomicCounter()
        let states = StateRecorder()
        let transport = RecordingParakeetTransport()
        let downloader = ParakeetModelDownloader(modelsRoot: root, manifest: [entry], transport: transport,
            activationHook: {
                let number = counter.increment()
                if number == 1 {
                    firstHookEntered.signal()
                    await releaseFirstHook.wait()
                }
            })
        downloader.onState = { @MainActor state in
            states.append(state)
            if case .done = state {
                _ = terminalCount.increment()
                done.fulfill()
            }
        }

        let first = Task { try await downloader.downloadIfNeeded() }
        await firstHookEntered.wait()
        let second = Task { try await downloader.downloadIfNeeded() }
        // B's claim synchronously invokes transport cancellation while A still
        // owns the activation hook. This latch proves the intended interleaving.
        XCTAssertEqual(transport.cancellation.wait(timeout: .now() + 5), .success,
                       "B must claim ownership and cancel A before A is released")
        XCTAssertEqual(transport.cancelledOperationIDs.count, 1,
                       "only A's public operation ID may be cancelled")
        releaseFirstHook.signal()

        do {
            _ = try await first.value
            XCTFail("superseded operation unexpectedly completed")
        } catch {
            guard let typed = error as? ParakeetModelDownloader.ErrorType else {
                XCTFail("unexpected supersession error: \(error)")
                return
            }
            guard case .cancelled = typed else {
                return XCTFail("superseded operation reported \(typed)")
            }
        }
        _ = try await second.value
        await fulfillment(of: [done], timeout: 2)
        let observed = states.snapshot
        XCTAssertEqual(terminalCount.current(), 1)
        XCTAssertEqual(observed.filter { if case .done = $0 { return true }; return false }.count, 1)
        XCTAssertEqual(observed.filter { if case .failed = $0 { return true }; return false }.count, 0)
        XCTAssertTrue(downloader.modelsAvailable())
        let items = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        XCTAssertEqual(items.filter { $0.lastPathComponent == ParakeetModelDownloader.folderName }.count, 1)
        XCTAssertFalse(items.contains { $0.lastPathComponent.hasPrefix(".staging-") || $0.lastPathComponent.hasPrefix(".backup-") })
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

    func test_integrityFailureNamesTheCurrentArtifact() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("parakeet-error-path-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = ParakeetManifestEntry(path: "nested/a.bin", size: 3, sha256: String(repeating: "a", count: 64))
        let downloader = ParakeetModelDownloader(modelsRoot: root, manifest: [entry],
                                                 transport: FailingParakeetTransport(failure: .checksumMismatch))
        let failed = expectation(description: "integrity failure published")
        let observedPath = AtomicString()
        downloader.onState = { @MainActor state in
            guard case let .failed(error) = state,
                  let typed = error as? ParakeetModelDownloader.ErrorType else { return }
            if case let .corruptFile(path) = typed {
                observedPath.set(path)
                failed.fulfill()
            }
        }
        do {
            _ = try await downloader.downloadIfNeeded()
            XCTFail("checksum failure unexpectedly succeeded")
        } catch { }
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertEqual(observedPath.value, entry.path)
    }

    func test_activationFailurePublishesRealErrorAndCancelCannotStealTerminal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("parakeet-activation-failure-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let oldBytes = Data("abc".utf8)
        let newBytes = Data("new".utf8)
        let oldEntry = ParakeetManifestEntry(path: "a.bin", size: 3, sha256: SHA256.hash(data: oldBytes).map { String(format: "%02x", $0) }.joined())
        let newEntry = ParakeetManifestEntry(path: "b.bin", size: 3, sha256: SHA256.hash(data: newBytes).map { String(format: "%02x", $0) }.joined())
        let seed = ParakeetModelDownloader(modelsRoot: root, manifest: [oldEntry], transport: RecordingParakeetTransport())
        _ = try await seed.downloadIfNeeded()
        let failed = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let terminalCount = AtomicCounter()
        let downloader = ParakeetModelDownloader(modelsRoot: root, manifest: [newEntry], transport: RecordingParakeetTransport(), activationHook: {
            if let items = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil),
               let staging = items.first(where: { $0.lastPathComponent.hasPrefix(".staging-") }) {
                try? FileManager.default.removeItem(at: staging)
            }
        })
        downloader.onState = { @MainActor state in
            if case .failed = state {
                _ = terminalCount.increment()
                failed.signal()
                _ = release.wait(timeout: .now() + 5)
            }
        }
        let operation = Task { try await downloader.downloadIfNeeded() }
        XCTAssertEqual(failed.wait(timeout: .now() + 5), .success)
        let cancellation = Task { downloader.cancel() }
        await cancellation.value
        release.signal()
        do {
            _ = try await operation.value
            XCTFail("activation failure unexpectedly succeeded")
        } catch let error as ParakeetModelDownloader.ErrorType {
            if case .cancelled = error { XCTFail("real activation failure was remapped to cancellation") }
        } catch {
            // The underlying filesystem error is intentionally preserved.
        }
        XCTAssertEqual(terminalCount.current(), 1)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(ParakeetModelDownloader.folderName).appendingPathComponent("a.bin")), oldBytes)
        let rootItems = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        XCTAssertFalse(rootItems.contains { $0.lastPathComponent.hasPrefix(".backup-") || $0.lastPathComponent.hasPrefix(".staging-") })
    }

    func test_successObserverRunsAfterCommitAndCannotBeCancelledOrSuperseded() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("parakeet-activation-success-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("abc".utf8)
        let entry = ParakeetManifestEntry(path: "a.bin", size: 3, sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let downloader = ParakeetModelDownloader(modelsRoot: root, manifest: [entry], transport: RecordingParakeetTransport())
        downloader.onState = { @MainActor state in
            if case .done = state {
                entered.signal()
                _ = release.wait(timeout: .now() + 5)
            }
        }
        let operation = Task { try await downloader.downloadIfNeeded() }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        let cancellation = Task { downloader.cancel() }
        await cancellation.value
        release.signal()
        _ = try await operation.value
        XCTAssertTrue(downloader.modelsAvailable())
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(ParakeetModelDownloader.folderName).appendingPathComponent("a.bin")), bytes)
    }

    func test_realBoundedTransportPublishesTinyManifestInOrder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("parakeet-loopback-success-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let payloads = ["a.bin": Data("abc".utf8), "b.bin": Data("de".utf8)]
        let server = try LoopbackHTTPServer { request in
            let name = request.path.split(separator: "/").last.map(String.init) ?? ""
            return .init(body: .fixed(payloads[name] ?? Data()))
        }
        defer { server.stop() }
        let entries = payloads.map { path, data in
            ParakeetManifestEntry(path: path, size: Int64(data.count), sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        }.sorted { $0.path < $1.path }
        let downloader = ParakeetModelDownloader(modelsRoot: root, manifest: entries,
            transport: LoopbackParakeetTransport(serverURL: server.url, entries: entries))
        let active = try await downloader.downloadIfNeeded()
        XCTAssertEqual(server.requestLog.map { $0.path }, ["/artifact/a.bin", "/artifact/b.bin"])
        XCTAssertEqual(try Data(contentsOf: active.appendingPathComponent("a.bin")), payloads["a.bin"])
        XCTAssertEqual(try Data(contentsOf: active.appendingPathComponent("b.bin")), payloads["b.bin"])
        XCTAssertTrue(downloader.modelsAvailable())
    }

    func test_realBoundedTransportRejectsBadLengthsAndPreservesSeededActive() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("parakeet-loopback-length-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let old = Data("abc".utf8)
        let oldEntry = ParakeetManifestEntry(path: "old.bin", size: 3, sha256: SHA256.hash(data: old).map { String(format: "%02x", $0) }.joined())
        let declaredMismatch = Data(repeating: 9, count: 99)
        let badEntry = ParakeetManifestEntry(path: "bad.bin", size: 3, sha256: SHA256.hash(data: Data("xyz".utf8)).map { String(format: "%02x", $0) }.joined())
        let server = try LoopbackHTTPServer { request in
            if request.path.hasSuffix("old.bin") { return .init(body: .fixed(old)) }
            return .init(headers: ["Content-Length": "99"], body: .fixed(declaredMismatch))
        }
        defer { server.stop() }
        let seedTransport = LoopbackParakeetTransport(serverURL: server.url, entries: [oldEntry])
        let seed = ParakeetModelDownloader(modelsRoot: root, manifest: [oldEntry], transport: seedTransport)
        _ = try await seed.downloadIfNeeded()
        let downloaderTransport = LoopbackParakeetTransport(serverURL: server.url, entries: [badEntry])
        let downloader = ParakeetModelDownloader(modelsRoot: root, manifest: [badEntry], transport: downloaderTransport)
        do {
            _ = try await downloader.downloadIfNeeded()
            XCTFail("wrong Content-Length must fail")
        } catch let error as ParakeetModelDownloader.ErrorType {
            guard case let .unexpectedContentLength(length) = error else {
                return XCTFail("wrong length returned unexpected typed error: \(error)")
            }
            XCTAssertEqual(length, 99)
        } catch {
            XCTFail("wrong length returned untyped error: \(error)")
        }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(ParakeetModelDownloader.folderName).appendingPathComponent("old.bin")), old)
        let items = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        XCTAssertFalse(items.contains { $0.lastPathComponent.hasPrefix(".staging-") || $0.lastPathComponent.hasPrefix(".backup-") })
    }

    func test_realBoundedTransportMapsTruncatedResponseToDownloadFailed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("parakeet-loopback-truncated-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data("abc".utf8)
        let entry = ParakeetManifestEntry(path: "bad.bin", size: 3,
                                          sha256: SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined())
        let server = try LoopbackHTTPServer { _ in .init(body: .drop(payload, admittedBytes: 2)) }
        defer { server.stop() }
        let downloader = ParakeetModelDownloader(modelsRoot: root, manifest: [entry],
            transport: LoopbackParakeetTransport(serverURL: server.url, entries: [entry]))
        do {
            _ = try await downloader.downloadIfNeeded()
            XCTFail("truncated response must fail")
        } catch let error as ParakeetModelDownloader.ErrorType {
            guard case let .downloadFailed(path) = error else {
                return XCTFail("truncated response returned unexpected typed error: \(error)")
            }
            XCTAssertEqual(path, "bad.bin")
        } catch {
            XCTFail("truncated response returned untyped error: \(error)")
        }
    }

    func test_realBoundedTransportRejectsChunkedExpectedPlusOneWithoutPromotion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("parakeet-loopback-oversize-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let expected = Data("abc".utf8)
        let entry = ParakeetManifestEntry(path: "a.bin", size: 3, sha256: SHA256.hash(data: expected).map { String(format: "%02x", $0) }.joined())
        let server = try LoopbackHTTPServer { _ in .init(body: .chunked(Data("abcd".utf8), chunkSize: 1)) }
        defer { server.stop() }
        let downloader = ParakeetModelDownloader(modelsRoot: root, manifest: [entry],
            transport: LoopbackParakeetTransport(serverURL: server.url, entries: [entry]))
        do { _ = try await downloader.downloadIfNeeded(); XCTFail("chunked expected+1 must fail") } catch let error as ParakeetModelDownloader.ErrorType {
            if case .downloadTooLarge = error {} else { XCTFail("unexpected oversize error: \(error)") }
        } catch { }
        XCTAssertTrue(server.requestLog.count >= 1)
        let items = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        XCTAssertFalse(items.contains { $0.lastPathComponent.hasPrefix(".staging-") })
        XCTAssertFalse(downloader.modelsAvailable())
    }

    func test_realBoundedTransportZeroCapacityMakesNoLoopbackRequest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("parakeet-loopback-space-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data("abc".utf8)
        let entry = ParakeetManifestEntry(path: "a.bin", size: 3, sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        let server = try LoopbackHTTPServer { _ in XCTFail("zero capacity must not request"); return .init(body: .fixed(data)) }
        defer { server.stop() }
        let downloader = ParakeetModelDownloader(modelsRoot: root, manifest: [entry],
            transport: LoopbackParakeetTransport(serverURL: server.url, entries: [entry],
                transport: BoundedModelDownloadTransport(capacity: ZeroCapacity(), allowInsecureLoopback: true)))
        do { _ = try await downloader.downloadIfNeeded(); XCTFail("insufficient space must fail") } catch let error as ParakeetModelDownloader.ErrorType {
            if case .insufficientSpace = error {} else { XCTFail("unexpected error: \(error)") }
        }
        XCTAssertTrue(server.requestLog.isEmpty)
        XCTAssertFalse(downloader.modelsAvailable())
    }

    func test_realBoundedTransportRetainsInterruptedPrefixAndResumesInOrder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("parakeet-loopback-resume-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data("abc".utf8)
        let entry = ParakeetManifestEntry(path: "a.bin", size: 3, sha256: SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined())
        let next = Data("de".utf8)
        let nextEntry = ParakeetManifestEntry(path: "b.bin", size: 2, sha256: SHA256.hash(data: next).map { String(format: "%02x", $0) }.joined())
        let server = try LoopbackHTTPServer { request in
            if request.path.hasSuffix("a.bin"), request.headers["range"] == nil {
                return .init(headers: ["ETag": "\"resume\""], body: .drop(payload, admittedBytes: 2))
            }
            if request.path.hasSuffix("a.bin") {
                return .init(status: 206, headers: ["Content-Length": "1"], body: .fixed(Data(payload.dropFirst(2))), contentRange: "bytes 2-2/3")
            }
            return .init(body: .fixed(next))
        }
        defer { server.stop() }
        let downloader = ParakeetModelDownloader(modelsRoot: root, manifest: [entry, nextEntry],
            transport: LoopbackParakeetTransport(serverURL: server.url, entries: [entry, nextEntry]))
        do { _ = try await downloader.downloadIfNeeded(); XCTFail("interrupted transfer must fail first invocation") } catch { }
        XCTAssertFalse(downloader.modelsAvailable())
        _ = try await downloader.downloadIfNeeded()
        XCTAssertEqual(server.requestLog.map { $0.path }, ["/artifact/a.bin", "/artifact/a.bin", "/artifact/b.bin"])
        XCTAssertEqual(server.requestLog[1].headers["range"], "bytes=2-")
        XCTAssertEqual(server.requestLog[1].headers["if-range"], "\"resume\"")
    }

    func test_realBoundedTransportFinalArtifactCancellationCleansPartialLayout() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("parakeet-loopback-cancel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = Data("abc".utf8)
        let second = Data(repeating: 7, count: 100_000)
        let entries = [
            ParakeetManifestEntry(path: "a.bin", size: 3, sha256: SHA256.hash(data: first).map { String(format: "%02x", $0) }.joined()),
            ParakeetManifestEntry(path: "b.bin", size: Int64(second.count), sha256: SHA256.hash(data: second).map { String(format: "%02x", $0) }.joined())
        ]
        let server = try LoopbackHTTPServer { request in
            request.path.hasSuffix("a.bin") ? .init(body: .fixed(first)) : .init(body: .slow(second, chunkSize: 512, delay: 0.002))
        }
        defer { server.stop() }
        let downloader = ParakeetModelDownloader(modelsRoot: root, manifest: entries,
            transport: LoopbackParakeetTransport(serverURL: server.url, entries: entries))
        let task = Task { try await downloader.downloadIfNeeded() }
        for _ in 0..<100 where !server.requestLog.contains(where: { $0.path.hasSuffix("b.bin") }) { try await Task.sleep(for: .milliseconds(10)) }
        downloader.cancel()
        do { _ = try await task.value; XCTFail("cancellation must fail") } catch let error as ParakeetModelDownloader.ErrorType {
            if case .cancelled = error {} else { XCTFail("unexpected cancellation: \(error)") }
        } catch { }
        XCTAssertFalse(downloader.modelsAvailable())
        let items = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        XCTAssertFalse(items.contains { $0.lastPathComponent.hasPrefix(".staging-") })
        XCTAssertEqual(server.requestLog.filter { $0.path.hasSuffix("b.bin") }.count, 1)
    }

    func test_realBoundedTransportSupersessionSuppressesStaleA() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("parakeet-loopback-supersede-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data(repeating: 4, count: 50_000)
        let entry = ParakeetManifestEntry(path: "a.bin", size: Int64(payload.count), sha256: SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined())
        let count = AtomicCounter()
        let aBegan = DispatchSemaphore(value: 0)
        let bBegan = DispatchSemaphore(value: 0)
        let server = try LoopbackHTTPServer { _ in
            if count.increment() == 1 {
                aBegan.signal()
                return .init(body: .slow(payload, chunkSize: 512, delay: 0.002))
            }
            bBegan.signal()
            return .init(body: .fixed(payload))
        }
        defer { server.stop() }
        let states = StateRecorder()
        let done = expectation(description: "only B publishes done")
        let downloader = ParakeetModelDownloader(modelsRoot: root, manifest: [entry],
            transport: LoopbackParakeetTransport(serverURL: server.url, entries: [entry]))
        downloader.onState = { @MainActor state in
            states.append(state)
            if case .done = state { done.fulfill() }
        }
        let first = Task { try await downloader.downloadIfNeeded() }
        XCTAssertEqual(aBegan.wait(timeout: .now() + 5), .success, "A request must begin before B")
        XCTAssertEqual(server.requestLog.count, 1, "B must not be started before A is observed")
        let second = Task { try await downloader.downloadIfNeeded() }
        XCTAssertEqual(bBegan.wait(timeout: .now() + 5), .success, "B request must begin")
        do {
            _ = try await first.value
            XCTFail("superseded A must fail")
        } catch let error as ParakeetModelDownloader.ErrorType {
            guard case .cancelled = error else { return XCTFail("A returned unexpected error: \(error)") }
        } catch {
            XCTFail("A returned untyped error: \(error)")
        }
        let active = try await second.value
        await fulfillment(of: [done], timeout: 2)
        let observed = states.snapshot
        XCTAssertEqual(observed.filter { if case .done = $0 { return true }; return false }.count, 1)
        XCTAssertEqual(observed.filter { if case .failed = $0 { return true }; return false }.count, 0)
        XCTAssertTrue(downloader.modelsAvailable())
        XCTAssertEqual(try Data(contentsOf: active.appendingPathComponent("a.bin")), payload)
        let items = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        XCTAssertEqual(items.filter { $0.lastPathComponent == ParakeetModelDownloader.folderName }.count, 1)
        XCTAssertFalse(items.contains { $0.lastPathComponent.hasPrefix(".staging-") || $0.lastPathComponent.hasPrefix(".backup-") })
    }

    func test_cancelWhileWaitingForStoreLeasePublishesTypedTerminalAndCanRecover() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("parakeet-lock-cancel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("abc".utf8)
        let entry = ParakeetManifestEntry(path: "a.bin", size: 3,
                                          sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        let transport = RecordingParakeetTransport()
        let downloader = ParakeetModelDownloader(modelsRoot: root, manifest: [entry], transport: transport)
        let lock = ParakeetStoreFileLock(storeParent: root)
        let lease = try await lock.acquire(.exclusive)
        defer { lease.release() }
        let cancelled = expectation(description: "typed cancellation published")
        let terminalCount = AtomicCounter()
        downloader.onState = { @MainActor state in
            guard case let .failed(error) = state,
                  let typed = error as? ParakeetModelDownloader.ErrorType,
                  case .cancelled = typed else { return }
            _ = terminalCount.increment()
            cancelled.fulfill()
        }

        let operation = Task { try await downloader.downloadIfNeeded() }
        // Give the child task scheduling opportunities to enter the lock wait,
        // without depending on elapsed time, before repeatedly requesting
        // cancellation until its terminal callback proves ownership.
        for _ in 0..<100 { await Task.yield() }
        var cancelledPublished = false
        while !cancelledPublished {
            downloader.cancel()
            await Task.yield()
            cancelledPublished = terminalCount.current() == 1
        }
        await fulfillment(of: [cancelled], timeout: 2)
        do {
            _ = try await operation.value
            XCTFail("lock-wait cancellation unexpectedly succeeded")
        } catch let error as ParakeetModelDownloader.ErrorType {
            guard case .cancelled = error else { XCTFail("unexpected typed error: \(error)"); return }
        } catch {
            XCTFail("lock-wait cancellation escaped as untyped error: \(error)")
        }
        XCTAssertEqual(terminalCount.current(), 1)
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertFalse(downloader.modelsAvailable())
        let items = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        XCTAssertFalse(items.contains { $0.lastPathComponent.hasPrefix(".staging-") })

        lease.release()
        let active = try await downloader.downloadIfNeeded()
        XCTAssertEqual(active.lastPathComponent, ParakeetModelDownloader.folderName)
        XCTAssertEqual(terminalCount.current(), 1)
        XCTAssertTrue(downloader.modelsAvailable())
    }

    func test_lockAcquisitionFailurePublishesOnceAndDoesNotPoisonValidDownloader() async throws {
        let bytes = Data("abc".utf8)
        let entry = ParakeetManifestEntry(path: "a.bin", size: 3,
                                          sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        let invalid = ParakeetModelDownloader(modelsRoot: URL(string: "https://example.invalid")!,
                                               manifest: [entry], transport: RecordingParakeetTransport())
        let failed = expectation(description: "lock acquisition failure published")
        let terminals = AtomicCounter()
        invalid.onState = { @MainActor state in
            guard case .failed = state else { return }
            _ = terminals.increment()
            failed.fulfill()
        }
        do {
            _ = try await invalid.downloadIfNeeded()
            XCTFail("invalid store root unexpectedly succeeded")
        } catch let error as ParakeetStoreFileLock.LockError {
            XCTAssertEqual(error, .invalidStoreParent)
        } catch {
            XCTFail("invalid store root returned unexpected error: \(error)")
        }
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertEqual(terminals.current(), 1)

        let validRoot = FileManager.default.temporaryDirectory.appendingPathComponent("parakeet-lock-recovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: validRoot) }
        let valid = ParakeetModelDownloader(modelsRoot: validRoot, manifest: [entry], transport: RecordingParakeetTransport())
        _ = try await valid.downloadIfNeeded()
        XCTAssertTrue(valid.modelsAvailable())
    }

    func test_storeExclusiveLeaseSpansLiveBoundedTransportAndBothTryModesBlock() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("parakeet-store-lease-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data(repeating: 3, count: 80_000)
        let entry = ParakeetManifestEntry(path: "a.bin", size: Int64(payload.count), sha256: SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined())
        let server = try LoopbackHTTPServer { _ in .init(body: .slow(payload, chunkSize: 512, delay: 0.002)) }
        defer { server.stop() }
        let downloader = ParakeetModelDownloader(modelsRoot: root, manifest: [entry],
            transport: LoopbackParakeetTransport(serverURL: server.url, entries: [entry]))
        let operation = Task { try await downloader.downloadIfNeeded() }
        for _ in 0..<100 where server.requestLog.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let independent = ParakeetStoreFileLock(storeParent: root)
        XCTAssertNil(try independent.tryAcquire(.shared))
        XCTAssertNil(try independent.tryAcquire(.exclusive))
        downloader.cancel()
        do { _ = try await operation.value } catch { }
    }

    func test_recoveryRestoresNewestValidBackupAndRemovesEveryStaleBackupOnlyExclusively() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("parakeet-recovery-all-backups-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data("abc".utf8)
        let entry = ParakeetManifestEntry(path: "a.bin", size: 3, sha256: SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined())
        let seed = ParakeetModelDownloader(modelsRoot: root, manifest: [entry], transport: RecordingParakeetTransport())
        _ = try await seed.downloadIfNeeded()
        let active = root.appendingPathComponent(ParakeetModelDownloader.folderName)
        let newest = root.appendingPathComponent(".backup-newest")
        let olderValid = root.appendingPathComponent(".backup-older-valid")
        let olderInvalid = root.appendingPathComponent(".backup-older-invalid")
        try FileManager.default.copyItem(at: active, to: newest)
        try FileManager.default.copyItem(at: active, to: olderValid)
        try FileManager.default.createDirectory(at: olderInvalid, withIntermediateDirectories: false)
        try Data("invalid".utf8).write(to: olderInvalid.appendingPathComponent("unexpected"))
        try FileManager.default.removeItem(at: active)

        let lock = ParakeetStoreFileLock(storeParent: root)
        let shared = try await lock.acquire(.shared)
        _ = ParakeetModelDownloader(modelsRoot: root, manifest: [entry], transport: RecordingParakeetTransport())
        XCTAssertFalse(FileManager.default.fileExists(atPath: active.path), "shared lease must retain crash recovery options")
        XCTAssertTrue(FileManager.default.fileExists(atPath: newest.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: olderValid.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: olderInvalid.path))
        shared.release()

        _ = ParakeetModelDownloader(modelsRoot: root, manifest: [entry], transport: RecordingParakeetTransport())
        XCTAssertEqual(try Data(contentsOf: active.appendingPathComponent("a.bin")), payload)
        let items = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        XCTAssertFalse(items.contains { $0.lastPathComponent.hasPrefix(".backup-") }, "successful restore must remove every stale backup")
        XCTAssertFalse(FileManager.default.fileExists(atPath: olderInvalid.path))
    }

    func test_recoveryMutatesOnlyWithExclusiveOwnershipAndRemovesInvalidBackup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("parakeet-recovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data("abc".utf8)
        let entry = ParakeetManifestEntry(path: "a.bin", size: 3, sha256: SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined())
        let seed = ParakeetModelDownloader(modelsRoot: root, manifest: [entry], transport: RecordingParakeetTransport())
        _ = try await seed.downloadIfNeeded()
        let active = root.appendingPathComponent(ParakeetModelDownloader.folderName)
        let backup = root.appendingPathComponent(".backup-valid")
        try FileManager.default.moveItem(at: active, to: backup)
        let lock = ParakeetStoreFileLock(storeParent: root)
        let shared = try await lock.acquire(.shared)
        _ = ParakeetModelDownloader(modelsRoot: root, manifest: [entry], transport: RecordingParakeetTransport())
        XCTAssertFalse(FileManager.default.fileExists(atPath: active.path), "shared ownership must prevent recovery mutation")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        shared.release()
        _ = ParakeetModelDownloader(modelsRoot: root, manifest: [entry], transport: RecordingParakeetTransport())
        XCTAssertEqual(try Data(contentsOf: active.appendingPathComponent("a.bin")), payload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        let invalid = root.appendingPathComponent(".backup-invalid")
        try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: false)
        try Data("bad".utf8).write(to: invalid.appendingPathComponent("unexpected"))
        try FileManager.default.removeItem(at: active)
        let sharedAgain = try await lock.acquire(.shared)
        _ = ParakeetModelDownloader(modelsRoot: root, manifest: [entry], transport: RecordingParakeetTransport())
        XCTAssertTrue(FileManager.default.fileExists(atPath: invalid.path))
        sharedAgain.release()
        _ = ParakeetModelDownloader(modelsRoot: root, manifest: [entry], transport: RecordingParakeetTransport())
        XCTAssertFalse(FileManager.default.fileExists(atPath: invalid.path))
    }

    func test_aggregateProgressIsMonotonicAndUsesWholeManifestContract() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("parakeet-progress-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let entries = [
            ParakeetManifestEntry(path: "a.bin", size: 3, sha256: SHA256.hash(data: Data("abc".utf8)).map { String(format: "%02x", $0) }.joined()),
            ParakeetManifestEntry(path: "b.bin", size: 2, sha256: SHA256.hash(data: Data("de".utf8)).map { String(format: "%02x", $0) }.joined())
        ]
        let states = StateRecorder()
        let downloader = ParakeetModelDownloader(modelsRoot: root, manifest: entries, transport: ProgressParakeetTransport())
        downloader.onState = { @MainActor state in
            states.append(state)
        }
        _ = try await downloader.downloadIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let observed = states.snapshot
        let running = observed.compactMap { state -> (Double, Int, Int, String?)? in
            guard case let .running(progress, index, count, file) = state else { return nil }
            return (progress, index, count, file)
        }
        XCTAssertFalse(running.isEmpty)
        XCTAssertTrue(zip(running, running.dropFirst()).allSatisfy { $0.0 <= $1.0 })
        XCTAssertTrue(running.allSatisfy { $0.2 == entries.count })
        XCTAssertTrue(running.contains { $0.1 == 0 && $0.3 == "a.bin" })
        XCTAssertTrue(running.contains { $0.1 == 1 && $0.3 == "b.bin" })
        XCTAssertTrue(running.contains { $0.0 == 0.4 })
        XCTAssertTrue(running.contains { $0.0 == 0.6 })
        XCTAssertTrue(observed.contains { if case .verifying = $0 { return true }; return false })
        XCTAssertEqual(observed.filter { if case .done = $0 { return true }; return false }.count, 1)
        XCTAssertEqual(observed.filter { if case .failed = $0 { return true }; return false }.count, 0)
    }

    func test_boundedErrorMatrixPreservesNamedArtifactPath() async throws {
        let path = "nested/current.bin"
        let bytes = Data("abc".utf8)
        let entry = ParakeetManifestEntry(path: path, size: 3, sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        let cases: [(BoundedModelDownloadError, (ParakeetModelDownloader.ErrorType) -> Bool)] = [
            (.unexpectedStatus(401), { if case .unauthorized = $0 { return true }; return false }),
            (.unexpectedStatus(403), { if case .unauthorized = $0 { return true }; return false }),
            (.unexpectedStatus(429), { if case let .rateLimited(status) = $0 { return status == 429 }; return false }),
            (.unexpectedStatus(503), { if case let .rateLimited(status) = $0 { return status == 503 }; return false }),
            (.unexpectedStatus(418), { if case let .httpStatus(status) = $0 { return status == 418 }; return false }),
            (.unexpectedContentLength(9), { if case let .unexpectedContentLength(length) = $0 { return length == 9 }; return false }),
            (.downloadTooLarge, { if case .downloadTooLarge = $0 { return true }; return false }),
            (.insufficientSpace(required: 4, available: 3), { if case .insufficientSpace = $0 { return true }; return false }),
            (.invalidIdentity, { if case let .corruptFile(value) = $0 { return value == path }; return false }),
            (.duplicateOperationID, { if case let .corruptFile(value) = $0 { return value == path }; return false }),
            (.checksumMismatch, { if case let .corruptFile(value) = $0 { return value == path }; return false }),
            (.incomplete, { if case let .corruptFile(value) = $0 { return value == path }; return false }),
            (.invalidResumeState, { if case let .corruptFile(value) = $0 { return value == path }; return false }),
            (.metadataTooLarge, { if case let .corruptFile(value) = $0 { return value == path }; return false }),
            (.invalidMirror, { if case let .downloadFailed(value) = $0 { return value == path }; return false }),
            (.invalidContentEncoding, { if case let .downloadFailed(value) = $0 { return value == path }; return false }),
            (.invalidContentRange, { if case let .downloadFailed(value) = $0 { return value == path }; return false }),
            (.rangeNotHonored, { if case let .downloadFailed(value) = $0 { return value == path }; return false }),
            (.rangeNotSatisfiable, { if case let .downloadFailed(value) = $0 { return value == path }; return false }),
            (.interrupted, { if case let .downloadFailed(value) = $0 { return value == path }; return false }),
            (.transport("socket"), { if case let .downloadFailed(value) = $0 { return value == path }; return false })
        ]
        for (index, item) in cases.enumerated() {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("parakeet-errors-\(index)-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let downloader = ParakeetModelDownloader(modelsRoot: root, manifest: [entry], transport: FailingParakeetTransport(failure: item.0))
            do {
                _ = try await downloader.downloadIfNeeded()
                XCTFail("case \(index) unexpectedly succeeded")
            } catch let error as ParakeetModelDownloader.ErrorType {
                XCTAssertTrue(item.1(error), "case \(index) mapped to \(error)")
            } catch {
                XCTFail("case \(index) returned unexpected error \(error)")
            }
        }
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
