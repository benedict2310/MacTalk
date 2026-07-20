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
            if case .done = state {
                _ = terminalCount.increment()
                done.fulfill()
            }
        }

        let first = Task { try await downloader.downloadIfNeeded() }
        await firstHookEntered.wait()
        let second = Task { try await downloader.downloadIfNeeded() }
        // Let B claim ownership before A releases its exclusive store lease;
        // B cannot reach the hook until that lease is available.
        try await Task.sleep(for: .milliseconds(50))
        releaseFirstHook.signal()

        do {
            _ = try await first.value
            XCTFail("superseded operation unexpectedly completed")
        } catch {
            guard let typed = error as? ParakeetModelDownloader.ErrorType else {
                XCTFail("unexpected supersession error: \(error)")
                return
            }
            if case .cancelled = typed {
                // expected
            } else {
                XCTFail("superseded operation reported \(typed)")
            }
        }
        _ = try await second.value
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(terminalCount.current(), 1)
        XCTAssertTrue(downloader.modelsAvailable())
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

    func test_cancelBlockedAtActivationBodyCannotStealCommittedTerminal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("parakeet-activation-cancel-race-\\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("abc".utf8)
        let entry = ParakeetManifestEntry(path: "a.bin", size: 3,
                                          sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        let bodyEntered = AsyncLatch()
        let releaseBody = AsyncLatch()
        let terminals = AtomicCounter()
        let states = AtomicString()
        let downloader = ParakeetModelDownloader(
            modelsRoot: root,
            manifest: [entry],
            transport: RecordingParakeetTransport(),
            activationBodyHook: {
                bodyEntered.signal()
                await releaseBody.wait()
            })
        downloader.onState = { @MainActor state in
            switch state {
            case .done, .failed:
                _ = terminals.increment()
            default:
                states.set(String(describing: state))
            }
        }

        let operation = Task { try await downloader.downloadIfNeeded() }
        await bodyEntered.wait()
        let cancellation = Task { downloader.cancel() }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(cancellation.isCancelled, "cancel must wait for the activation ownership boundary")
        releaseBody.signal()

        _ = try await operation.value
        await cancellation.value
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(terminals.current(), 1)
        XCTAssertTrue(downloader.modelsAvailable())
        let rootItems = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        XCTAssertFalse(rootItems.contains { $0.lastPathComponent.hasPrefix(".backup-") })
        XCTAssertFalse(rootItems.contains { $0.lastPathComponent.hasPrefix(".staging-") })
        XCTAssertFalse(states.value.contains("cancelled"))
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
        for (_, item) in cases.enumerated() {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("parakeet-errors-\\(index)-\\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let downloader = ParakeetModelDownloader(modelsRoot: root, manifest: [entry], transport: FailingParakeetTransport(failure: item.0))
            do {
                _ = try await downloader.downloadIfNeeded()
                XCTFail("case \\(index) unexpectedly succeeded")
            } catch let error as ParakeetModelDownloader.ErrorType {
                XCTAssertTrue(item.1(error), "case \\(index) mapped to \\(error)")
            } catch {
                XCTFail("case \\(index) returned unexpected error \\(error)")
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
