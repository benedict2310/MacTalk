import CryptoKit
import Foundation
import XCTest
@testable import MacTalk

private final class TestMutex: @unchecked Sendable {
    private let mutex = NSLock()
    func lock() { mutex.lock() }
    func unlock() { mutex.unlock() }
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
