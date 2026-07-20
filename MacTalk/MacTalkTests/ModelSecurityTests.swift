import CryptoKit
import XCTest
@testable import MacTalk

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() }
}

private final class RecordingBoundedTransport: BoundedModelDownloading, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [BoundedModelDownloadRequest] = []
    private(set) var cancelled: [UUID] = []
    var resultURL: URL!
    var error: Error?

    func download(_ request: BoundedModelDownloadRequest) async throws -> URL {
        record(request)
        if let error { throw error }
        guard let result = resultURL else { throw BoundedModelDownloadError.transport("missing fixture") }
        request.progress?(request.identity.sizeBytes, request.identity.sizeBytes)
        return result
    }

    func cancel(operationID: UUID) { lock.withLock { cancelled.append(operationID) } }

    func record(_ request: BoundedModelDownloadRequest) { lock.withLock { requests.append(request) } }
    func requestSnapshot() -> [BoundedModelDownloadRequest] { lock.withLock { requests } }
}

final class ModelSecurityTests: XCTestCase {
    private var root: URL!
    private var modelRoot: URL!
    private var downloadsRoot: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MacTalk-ModelSecurity-\(UUID().uuidString)")
        modelRoot = root.appendingPathComponent("models")
        downloadsRoot = root.appendingPathComponent("downloads")
        try FileManager.default.createDirectory(at: modelRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: downloadsRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func test_modelDownloaderMapsIdentityAndMirrorOrderAndRemovesLegacyResumeFiles() async throws {
        let payload = Data("verified model".utf8)
        let source = root.appendingPathComponent("fixture.part")
        try payload.write(to: source)
        let transport = RecordingBoundedTransport(); transport.resultURL = source
        let downloader = ModelDownloader(modelRoot: modelRoot, downloadsRoot: downloadsRoot, transport: transport)
        let mirrorA = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/rev/model.bin")!
        let mirrorB = URL(string: "https://hf-mirror.com/ggerganov/whisper.cpp/resolve/rev/model.bin")!
        let spec = makeSpec(payload: payload, urls: [mirrorA, mirrorB])
        try Data("legacy".utf8).write(to: downloadsRoot.appendingPathComponent("fixture.resume"))
        try Data("legacy".utf8).write(to: downloadsRoot.appendingPathComponent("fixture.resume.json"))
        let done = expectation(description: "done")
        downloader.onState = { if case .done = $0 { done.fulfill() } }
        downloader.start(spec: spec)
        await fulfillment(of: [done], timeout: 2)

        let request = try XCTUnwrap(transport.requestSnapshot().first)
        XCTAssertEqual(request.identity.schemaVersion, 1)
        XCTAssertEqual(request.identity.provider, "whisper")
        XCTAssertEqual(request.identity.modelID, spec.id)
        XCTAssertEqual(request.identity.sourceRepository, spec.source)
        XCTAssertEqual(request.identity.revision, spec.revision)
        XCTAssertEqual(request.identity.artifactPath, spec.filename)
        XCTAssertEqual(request.identity.filename, spec.filename)
        XCTAssertEqual(request.identity.sha256, spec.sha256)
        XCTAssertEqual(request.identity.sizeBytes, spec.sizeBytes)
        XCTAssertEqual(request.mirrors, [mirrorA, mirrorB])
        XCTAssertEqual(request.workspaceRoot, downloadsRoot)
        XCTAssertEqual(request.aggregateDiskBytesStillRequired, spec.sizeBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: downloadsRoot.appendingPathComponent("fixture.resume").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: downloadsRoot.appendingPathComponent("fixture.resume.json").path))
    }

    func test_invalidDigestAndNoURLsFailBeforeTransport() async {
        let transport = RecordingBoundedTransport()
        let downloader = ModelDownloader(modelRoot: modelRoot, downloadsRoot: downloadsRoot, transport: transport)
        let invalid = makeSpec(payload: Data("x".utf8), urls: [URL(string: "https://example.invalid/model")!], digest: "")
        let noURLs = makeSpec(payload: Data("x".utf8), urls: [])
        let invalidFailure = expectation(description: "invalid digest")
        let noURLFailure = expectation(description: "no urls")
        var seen = 0
        downloader.onState = { state in
            guard case .failed = state else { return }
            seen += 1
            if seen == 1 { invalidFailure.fulfill() } else { noURLFailure.fulfill() }
        }
        downloader.start(spec: invalid)
        downloader.start(spec: noURLs)
        await fulfillment(of: [invalidFailure, noURLFailure], timeout: 2)
        XCTAssertTrue(transport.requestSnapshot().isEmpty)
    }

    func test_validCacheAvoidsTransportAndCorruptCacheIsRemoved() async throws {
        let payload = Data("cached model".utf8)
        let spec = makeSpec(payload: payload, urls: [URL(string: "https://example.invalid/model")!])
        let destination = modelRoot.appendingPathComponent(spec.filename)
        try payload.write(to: destination)
        let transport = RecordingBoundedTransport(); transport.error = BoundedModelDownloadError.transport("must not run")
        let downloader = ModelDownloader(modelRoot: modelRoot, downloadsRoot: downloadsRoot, transport: transport)
        let cachedDone = expectation(description: "cached done")
        downloader.onState = { if case .done = $0 { cachedDone.fulfill() } }
        downloader.start(spec: spec)
        await fulfillment(of: [cachedDone], timeout: 2)
        XCTAssertTrue(transport.requestSnapshot().isEmpty)

        try Data("corrupt".utf8).write(to: destination)
        let replacement = root.appendingPathComponent("replacement.part")
        try payload.write(to: replacement)
        transport.error = nil; transport.resultURL = replacement
        let repaired = expectation(description: "repaired")
        downloader.onState = { if case .done = $0 { repaired.fulfill() } }
        downloader.start(spec: spec)
        await fulfillment(of: [repaired], timeout: 2)
        XCTAssertEqual(try Data(contentsOf: destination), payload)
        XCTAssertEqual(transport.requestSnapshot().count, 1)
    }

    func test_boundedErrorsMapToTypedState() async throws {
        let cases: [(BoundedModelDownloadError, ModelDownloader.ErrorType)] = [
            (.insufficientSpace(required: 10, available: 1), .noSpace),
            (.unexpectedStatus(503), .httpStatus(503)),
            (.downloadTooLarge, .badChecksum),
            (.checksumMismatch, .badChecksum),
            (.incomplete, .badChecksum),
            (.interrupted, .network(BoundedModelDownloadError.interrupted))
        ]
        for (error, expected) in cases {
            let transport = RecordingBoundedTransport(); transport.error = error
            let downloader = ModelDownloader(modelRoot: modelRoot.appendingPathComponent(UUID().uuidString), downloadsRoot: downloadsRoot.appendingPathComponent(UUID().uuidString), transport: transport)
            let failure = expectation(description: "failure")
            downloader.onState = { state in
                guard case .failed(let actual) = state else { return }
                XCTAssertEqual(actual.localizedDescription, expected.localizedDescription)
                failure.fulfill()
            }
            downloader.start(spec: makeSpec(payload: Data("x".utf8), urls: [URL(string: "https://example.invalid/model")!]))
            await fulfillment(of: [failure], timeout: 2)
        }
    }

    func test_realLoopbackTransportEmitsProgressVerifyingDoneAndExactBytes() async throws {
        let payload = Data("loopback model payload".utf8)
        let server = try LoopbackHTTPServer { _ in .init(body: .fixed(payload)) }
        defer { server.stop() }
        let transport = BoundedModelDownloadTransport(allowInsecureLoopback: true)
        let downloader = ModelDownloader(modelRoot: modelRoot, downloadsRoot: downloadsRoot, transport: transport)
        let spec = makeSpec(payload: payload, urls: [server.url])
        let states = LockedBox<[ModelDownloader.State]>([])
        let done = expectation(description: "done")
        downloader.onState = { state in states.withLock { $0.append(state) }; if case .done = state { done.fulfill() } }
        downloader.start(spec: spec)
        await fulfillment(of: [done], timeout: 10)
        let final = try Data(contentsOf: modelRoot.appendingPathComponent(spec.filename))
        XCTAssertEqual(final, payload)
        let captured = states.value
        XCTAssertTrue(captured.contains { if case .running = $0 { true } else { false } })
        XCTAssertTrue(captured.contains { if case .verifying = $0 { true } else { false } })
        XCTAssertTrue(captured.contains { if case .done = $0 { true } else { false } })
    }

    func test_realLoopbackInterruptionPersistsAndLaterStartResumes() async throws {
        let payload = Data("resumable loopback model".utf8)
        let half = payload.count / 2
        let server = try LoopbackHTTPServer { request in
            if let range = request.headers["range"], let start = Int(range.split(separator: "=").last!.split(separator: "-").first!) {
                return .init(status: 206, body: .fixed(Data(payload.dropFirst(start))), contentRange: "bytes \(start)-\(payload.count - 1)/\(payload.count)")
            }
            return .init(body: .drop(payload, admittedBytes: half))
        }
        defer { server.stop() }
        let transport = BoundedModelDownloadTransport(allowInsecureLoopback: true)
        let downloader = ModelDownloader(modelRoot: modelRoot, downloadsRoot: downloadsRoot, transport: transport)
        let spec = makeSpec(payload: payload, urls: [server.url])
        let firstFailure = expectation(description: "interrupted")
        downloader.onState = { if case .failed = $0 { firstFailure.fulfill() } }
        downloader.start(spec: spec)
        await fulfillment(of: [firstFailure], timeout: 10)
        XCTAssertFalse(FileManager.default.fileExists(atPath: modelRoot.appendingPathComponent(spec.filename).path))
        let secondDone = expectation(description: "resumed")
        downloader.onState = { if case .done = $0 { secondDone.fulfill() } }
        downloader.start(spec: spec)
        await fulfillment(of: [secondDone], timeout: 10)
        XCTAssertEqual(try Data(contentsOf: modelRoot.appendingPathComponent(spec.filename)), payload)
        XCTAssertTrue(server.requestLog.dropFirst().contains { $0.headers["range"] != nil })
    }

    func test_cancelSlowBodyEmitsOneCancelledAndDoesNotPublish() async throws {
        let payload = Data(repeating: 7, count: 256 * 1024)
        let server = try LoopbackHTTPServer { _ in .init(body: .slow(payload, chunkSize: 1024, delay: 0.02)) }
        defer { server.stop() }
        let transport = BoundedModelDownloadTransport(allowInsecureLoopback: true)
        let downloader = ModelDownloader(modelRoot: modelRoot, downloadsRoot: downloadsRoot, transport: transport)
        let spec = makeSpec(payload: payload, urls: [server.url])
        let cancelled = expectation(description: "cancelled")
        let cancelledCount = LockedBox(0)
        downloader.onState = { state in
            if case .failed(let error) = state, let typed = error as? ModelDownloader.ErrorType, case .cancelled = typed {
                cancelledCount.withLock { $0 += 1 }
                cancelled.fulfill()
            }
        }
        downloader.start(spec: spec)
        try await Task.sleep(for: .milliseconds(100))
        downloader.cancel()
        await fulfillment(of: [cancelled], timeout: 5)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(cancelledCount.value, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: modelRoot.appendingPathComponent(spec.filename).path))
    }

    func test_startingB_supersedesA() async throws {
        let payloadA = Data(repeating: 1, count: 128 * 1024)
        let payloadB = Data("model B".utf8)
        let serverA = try LoopbackHTTPServer { _ in .init(body: .slow(payloadA, chunkSize: 1024, delay: 0.02)) }
        let serverB = try LoopbackHTTPServer { _ in .init(body: .fixed(payloadB)) }
        defer { serverA.stop(); serverB.stop() }
        let transport = BoundedModelDownloadTransport(allowInsecureLoopback: true)
        let downloader = ModelDownloader(modelRoot: modelRoot, downloadsRoot: downloadsRoot, transport: transport)
        let specA = makeSpec(payload: payloadA, urls: [serverA.url], id: "a", filename: "a.bin")
        let specB = makeSpec(payload: payloadB, urls: [serverB.url], id: "b", filename: "b.bin")
        let doneB = expectation(description: "B done")
        downloader.onState = { state in if case .done = state { doneB.fulfill() } }
        downloader.start(spec: specA)
        try await Task.sleep(for: .milliseconds(80))
        downloader.start(spec: specB)
        await fulfillment(of: [doneB], timeout: 10)
        XCTAssertFalse(FileManager.default.fileExists(atPath: modelRoot.appendingPathComponent(specA.filename).path))
        XCTAssertEqual(try Data(contentsOf: modelRoot.appendingPathComponent(specB.filename)), payloadB)
    }

    func test_tokenHelperOnlyAuthorizesExactOfficialOrigin() {
        let token = "test-token"
        XCTAssertEqual(ModelDownloader.request(for: URL(string: "https://huggingface.co/model")!, token: token).value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        XCTAssertEqual(ModelDownloader.request(for: URL(string: "https://huggingface.co:443/model")!, token: token).value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        for url in ["https://huggingface.co:444/model", "https://HF-MIRROR.com/model", "http://huggingface.co/model"] {
            XCTAssertNil(ModelDownloader.request(for: URL(string: url)!, token: token).value(forHTTPHeaderField: "Authorization"), url)
        }
    }

    private func makeSpec(payload: Data, urls: [URL], digest: String? = nil, id: String = "fixture", filename: String = "fixture.bin") -> ModelSpec {
        ModelSpec(id: id, displayName: "Fixture", filename: filename,
                  sha256: digest ?? SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined(),
                  sizeBytes: Int64(payload.count), urls: urls, license: nil, languages: nil,
                  revision: "immutable-revision", source: "fixture/repository")
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value
    init(_ value: Value) { storage = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return storage }
    func withLock(_ body: (inout Value) -> Void) { lock.lock(); body(&storage); lock.unlock() }
}
