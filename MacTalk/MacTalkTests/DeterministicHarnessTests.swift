import XCTest
import CryptoKit
@preconcurrency import AVFoundation
@testable import MacTalk

private final class DeterministicFailingTransport: BoundedModelDownloading, @unchecked Sendable {
    private let onRequest: (URL) -> Void
    init(onRequest: @escaping (URL) -> Void) { self.onRequest = onRequest }
    func download(_ request: BoundedModelDownloadRequest) async throws -> URL {
        if let url = request.mirrors.first { onRequest(url) }
        throw BoundedModelDownloadError.transport("Unexpected network request in deterministic lane")
    }
    func cancel(operationID: UUID) {}
}

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value
    init(_ value: Value) { storage = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return storage }
    func withLock(_ body: (inout Value) -> Void) { lock.lock(); body(&storage); lock.unlock() }
}

final class DeterministicHarnessTests: XCTestCase {
    func test_scriptedASRProcessCancellationIsRecorded() async throws {
        let engine = DeterministicASREngine(script: DeterministicASRScript(processDelayNanoseconds: 5_000_000_000))
        let started = expectation(description: "process entered fake engine")
        engine.onEvent = { event in
            if case .process = event { started.fulfill() }
        }
        let task = Task {
            try await engine.process(
                makeConstantPCMBuffer(sampleRate: 16_000, channels: 1, frameCount: 16),
                language: "en"
            )
        }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected and asserted by the recorded cancellation event below.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        XCTAssertEqual(engine.cancellationCount, 1)
    }

    func test_downloaderFailsUnexpectedRequestsAtInjectedTransportBoundary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let downloads = root.appendingPathComponent("downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let payload = Data("deterministic model".utf8)
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let spec = ModelSpec(
            id: "trap-fixture",
            displayName: "Trap fixture",
            filename: "trap-fixture.bin",
            sha256: digest,
            sizeBytes: Int64(payload.count),
            urls: [URL(string: "https://unexpected.invalid/model")!],
            license: nil,
            languages: nil
        )
        let requested = LockedValue<[URL]>([])
        let downloader = ModelDownloader(modelRoot: root, downloadsRoot: downloads,
                                         transport: DeterministicFailingTransport(onRequest: { url in requested.withLock { $0.append(url) } }))
        let failed = expectation(description: "unexpected request is rejected")
        downloader.onState = { state in
            if case .failed = state { failed.fulfill() }
        }

        downloader.start(spec: spec)
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertEqual(requested.value, spec.urls)
    }

    func test_audioFixturesAreStableAndIsolatedFakesFailClosed() throws {
        XCTAssertEqual(DeterministicAudioFixtures.silence(count: 3), [0, 0, 0])
        XCTAssertEqual(DeterministicAudioFixtures.impulse(count: 3), [1, 0, 0])
        XCTAssertEqual(DeterministicAudioFixtures.tone(count: 0), [])

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let downloader = DeterministicModelDownloader()
        XCTAssertThrowsError(try downloader.download(filename: "never-download.bin"))
        XCTAssertEqual(downloader.requestedModels, ["never-download.bin"])
    }
}
