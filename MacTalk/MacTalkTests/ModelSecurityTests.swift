import CryptoKit
import XCTest
@testable import MacTalk

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() }
}

private extension ModelDownloader.State {
    var isTerminal: Bool {
        switch self {
        case .done, .failed: return true
        case .idle, .running, .verifying: return false
        }
    }
}

private final class StateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var tagged: [(UUID, ModelDownloader.State)] = []
    private var legacy: [ModelDownloader.State] = []

    func appendTagged(_ operationID: UUID, _ state: ModelDownloader.State) {
        lock.lock(); tagged.append((operationID, state)); lock.unlock()
    }

    func appendLegacy(_ state: ModelDownloader.State) {
        lock.lock(); legacy.append(state); lock.unlock()
    }

    var taggedStates: [(UUID, ModelDownloader.State)] {
        lock.lock(); defer { lock.unlock() }
        return tagged
    }

    var legacyStates: [ModelDownloader.State] {
        lock.lock(); defer { lock.unlock() }
        return legacy
    }
}

private final class SequencedBoundedTransport: BoundedModelDownloading, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [URL]
    init(results: [URL]) { self.results = results }

    func download(_ request: BoundedModelDownloadRequest) async throws -> URL {
        try lock.withLock {
            guard !results.isEmpty else { throw BoundedModelDownloadError.transport("missing fixture") }
            return results.removeFirst()
        }
    }

    func cancel(operationID: UUID) {}
}

private final class GateBoundedTransport: BoundedModelDownloading, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [URL]
    private var firstGate: AsyncStream<Void>.Continuation
    private let firstRelease: AsyncStream<Void>
    let firstStarted = DispatchSemaphore(value: 0)
    private(set) var cancelled: [UUID] = []

    init(results: [URL]) {
        self.results = results
        let stream = AsyncStream<Void>.makeStream()
        firstRelease = stream.stream
        firstGate = stream.continuation
    }

    func download(_ request: BoundedModelDownloadRequest) async throws -> URL {
        let (result, shouldGate) = lock.withLock { () -> (URL, Bool) in
            guard !results.isEmpty else { fatalError("missing fixture") }
            return (results.removeFirst(), true)
        }
        if shouldGate {
            firstStarted.signal()
            _ = await firstRelease.first { _ in true }
        }
        return result
    }

    func cancel(operationID: UUID) { lock.withLock { cancelled.append(operationID) } }
    func releaseFirst() { firstGate.yield(()) }
}

private final class CacheOperationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var events: [(String, URL)] = []

    var operations: ModelDownloader.CacheOperations {
        ModelDownloader.CacheOperations(
            inspect: { [self] url in record("inspect", url); return false },
            remove: { [self] url in record("remove", url) },
            replace: { [self] source, destination, _ in record("replace", source); record("replace-destination", destination) }
        )
    }

    private func record(_ operation: String, _ url: URL) {
        lock.withLock { events.append((operation, url)) }
    }
}

private final class BarrierBoundedTransport: BoundedModelDownloading, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [UUID] = []
    private(set) var cancelled: [UUID] = []
    let requestStarted = DispatchSemaphore(value: 0)
    private let releaseStream: AsyncStream<Void>
    private let releaseContinuation: AsyncStream<Void>.Continuation

    init() {
        let stream = AsyncStream<Void>.makeStream()
        releaseStream = stream.stream
        releaseContinuation = stream.continuation
    }

    func download(_ request: BoundedModelDownloadRequest) async throws -> URL {
        lock.withLock { requests.append(request.operationID) }
        requestStarted.signal()
        for await _ in releaseStream { break }
        throw BoundedModelDownloadError.cancelled
    }

    func cancel(operationID: UUID) { lock.withLock { cancelled.append(operationID) } }
    func releaseRequest() { releaseContinuation.yield(()) }
    func requestIDs() -> [UUID] { lock.withLock { requests } }
    func cancelledIDs() -> [UUID] { lock.withLock { cancelled } }
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

    func test_invalidDigestTerminalStateIsNotCancelledAgain() async {
        let transport = RecordingBoundedTransport()
        let downloader = ModelDownloader(modelRoot: modelRoot, downloadsRoot: downloadsRoot, transport: transport)
        let operationID = UUID()
        let terminal = expectation(description: "invalid digest terminal state")
        let recorder = StateRecorder()
        downloader.onOperationState = { taggedOperationID, state in
            recorder.appendTagged(taggedOperationID, state)
        }
        downloader.onState = { state in
            recorder.appendLegacy(state)
            if case .failed(let error) = state, let typed = error as? ModelDownloader.ErrorType, case .badChecksum = typed { terminal.fulfill() }
        }

        downloader.start(spec: makeSpec(payload: Data("x".utf8), urls: [URL(string: "https://example.invalid/model")!], digest: ""), operationID: operationID)
        await fulfillment(of: [terminal], timeout: 2)
        downloader.cancel()
        try? await Task.sleep(for: .milliseconds(100))

        let taggedStates = recorder.taggedStates
        let legacyStates = recorder.legacyStates
        XCTAssertEqual(taggedStates.filter { $0.0 == operationID && $0.1.isTerminal }.count, 1)
        XCTAssertEqual(legacyStates.filter(\.isTerminal).count, 1)
        XCTAssertFalse(legacyStates.contains(where: { state in
            if case .failed(let error) = state, let typed = error as? ModelDownloader.ErrorType, case .cancelled = typed { return true }
            return false
        }))
        XCTAssertTrue(transport.requestSnapshot().isEmpty)
        XCTAssertTrue(transport.cancelled.isEmpty)
    }

    func test_noURLsTerminalStateIsNotCancelledAgain() async {
        let transport = RecordingBoundedTransport()
        let downloader = ModelDownloader(modelRoot: modelRoot, downloadsRoot: downloadsRoot, transport: transport)
        let operationID = UUID()
        let terminal = expectation(description: "no URLs terminal state")
        let recorder = StateRecorder()
        downloader.onOperationState = { taggedOperationID, state in
            recorder.appendTagged(taggedOperationID, state)
        }
        downloader.onState = { state in
            recorder.appendLegacy(state)
            if case .failed(let error) = state, let typed = error as? ModelDownloader.ErrorType, case .noURLs = typed { terminal.fulfill() }
        }

        downloader.start(spec: makeSpec(payload: Data("x".utf8), urls: []), operationID: operationID)
        await fulfillment(of: [terminal], timeout: 2)
        downloader.cancel()
        try? await Task.sleep(for: .milliseconds(100))

        let taggedStates = recorder.taggedStates
        let legacyStates = recorder.legacyStates
        XCTAssertEqual(taggedStates.filter { $0.0 == operationID && $0.1.isTerminal }.count, 1)
        XCTAssertEqual(legacyStates.filter(\.isTerminal).count, 1)
        XCTAssertFalse(legacyStates.contains(where: { state in
            if case .failed(let error) = state, let typed = error as? ModelDownloader.ErrorType, case .cancelled = typed { return true }
            return false
        }))
        XCTAssertTrue(transport.requestSnapshot().isEmpty)
        XCTAssertTrue(transport.cancelled.isEmpty)
    }

    func test_validCacheTerminalStateIsNotCancelledAgain() async throws {
        let payload = Data("cached model".utf8)
        let spec = makeSpec(payload: payload, urls: [URL(string: "https://example.invalid/model")!])
        try payload.write(to: modelRoot.appendingPathComponent(spec.filename))
        let transport = RecordingBoundedTransport()
        let downloader = ModelDownloader(modelRoot: modelRoot, downloadsRoot: downloadsRoot, transport: transport)
        let operationID = UUID()
        let terminal = expectation(description: "valid cache terminal state")
        let recorder = StateRecorder()
        downloader.onOperationState = { taggedOperationID, state in
            recorder.appendTagged(taggedOperationID, state)
        }
        downloader.onState = { state in
            recorder.appendLegacy(state)
            if case .done = state { terminal.fulfill() }
        }

        downloader.start(spec: spec, operationID: operationID)
        await fulfillment(of: [terminal], timeout: 2)
        downloader.cancel()
        try? await Task.sleep(for: .milliseconds(100))

        let taggedStates = recorder.taggedStates
        let legacyStates = recorder.legacyStates
        XCTAssertEqual(taggedStates.filter { $0.0 == operationID && $0.1.isTerminal }.count, 1)
        XCTAssertEqual(legacyStates.filter(\.isTerminal).count, 1)
        XCTAssertFalse(legacyStates.contains(where: { state in
            if case .failed(let error) = state, let typed = error as? ModelDownloader.ErrorType, case .cancelled = typed { return true }
            return false
        }))
        XCTAssertTrue(transport.requestSnapshot().isEmpty)
        XCTAssertTrue(transport.cancelled.isEmpty)
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

    func test_sameDestinationVerificationRaceCannotReplaceNewerGeneration() async throws {
        let payloadA = Data("stale A".utf8)
        let payloadB = Data("fresh B".utf8)
        let sourceA = root.appendingPathComponent("a.part")
        let sourceB = root.appendingPathComponent("b.part")
        try payloadA.write(to: sourceA)
        try payloadB.write(to: sourceB)
        let transport = SequencedBoundedTransport(results: [sourceA, sourceB])
        let downloader = ModelDownloader(modelRoot: modelRoot, downloadsRoot: downloadsRoot, transport: transport)
        let specA = makeSpec(payload: payloadA, urls: [URL(string: "https://example.invalid/a")!], id: "a", filename: "shared.bin")
        let specB = makeSpec(payload: payloadB, urls: [URL(string: "https://example.invalid/b")!], id: "b", filename: "shared.bin")
        let aVerified = DispatchSemaphore(value: 0)
        let releaseA = DispatchSemaphore(value: 0)
        let aRejected = DispatchSemaphore(value: 0)
        ModelIntegrityVerifier.setTestBeforeCommitHook { spec in
            if spec.sha256 == specA.sha256 {
                aVerified.signal()
                releaseA.wait()
            }
        }
        ModelIntegrityVerifier.setTestCommitDecisionHook { spec, accepted in
            if spec.sha256 == specA.sha256 && !accepted { aRejected.signal() }
        }
        defer {
            ModelIntegrityVerifier.setTestBeforeCommitHook(nil)
            ModelIntegrityVerifier.setTestCommitDecisionHook(nil)
        }
        let bDone = expectation(description: "B done")
        let recorder = StateRecorder()
        let operationIDB = UUID()
        downloader.onOperationState = { id, state in
            recorder.appendTagged(id, state)
            if id == operationIDB, case .done = state { bDone.fulfill() }
        }
        downloader.start(spec: specA)
        XCTAssertEqual(aVerified.wait(timeout: .now() + 2), .success)
        downloader.start(spec: specB, operationID: operationIDB)
        await fulfillment(of: [bDone], timeout: 2)
        releaseA.signal()
        XCTAssertEqual(aRejected.wait(timeout: .now() + 2), .success)

        XCTAssertEqual(try Data(contentsOf: modelRoot.appendingPathComponent("shared.bin")), payloadB)
        XCTAssertFalse(recorder.taggedStates.contains { id, state in
            id != operationIDB && state.isTerminal
        })
    }

    func test_supersedingInvalidStartCancelsOnlyOwnedPreviousOperation() async throws {
        let payload = Data("blocked A".utf8)
        let source = root.appendingPathComponent("blocked.part")
        try payload.write(to: source)
        let operationIDA = UUID()
        let operationIDB = UUID()
        let transport = GateBoundedTransport(results: [source])
        let downloader = ModelDownloader(modelRoot: modelRoot, downloadsRoot: downloadsRoot, transport: transport)
        let invalidDone = expectation(description: "invalid replacement rejected")
        downloader.onOperationState = { id, state in
            if id == operationIDB, case .failed(ModelDownloader.ErrorType.invalidFilename) = state {
                invalidDone.fulfill()
            }
        }
        let specA = makeSpec(payload: payload, urls: [URL(string: "https://example.invalid/a")!], id: "a", filename: "shared.bin")
        downloader.start(spec: specA, operationID: operationIDA)
        XCTAssertEqual(transport.firstStarted.wait(timeout: .now() + 2), .success)
        downloader.start(spec: makeSpec(payload: payload, urls: [URL(string: "https://example.invalid/b")!], id: "b", filename: "../outside"), operationID: operationIDB)
        await fulfillment(of: [invalidDone], timeout: 2)
        transport.releaseFirst()
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(transport.cancelled, [operationIDA])
        XCTAssertFalse(FileManager.default.fileExists(atPath: modelRoot.appendingPathComponent("shared.bin").path))
    }

    func test_validReplacementCancelsOnlyItsPriorOperation() async throws {
        let payloadA = Data("replacement A".utf8)
        let payloadB = Data("replacement B".utf8)
        let sourceA = root.appendingPathComponent("replacement-a.part")
        let sourceB = root.appendingPathComponent("replacement-b.part")
        try payloadA.write(to: sourceA)
        try payloadB.write(to: sourceB)
        let transport = GateBoundedTransport(results: [sourceA, sourceB])
        let downloader = ModelDownloader(modelRoot: modelRoot, downloadsRoot: downloadsRoot, transport: transport)
        let operationIDA = UUID()
        let operationIDB = UUID()
        let bDone = expectation(description: "valid replacement done")
        downloader.onOperationState = { id, state in
            if id == operationIDB, case .done = state { bDone.fulfill() }
        }

        downloader.start(spec: makeSpec(payload: payloadA, urls: [URL(string: "https://example.invalid/a")!], id: "a", filename: "a.bin"), operationID: operationIDA)
        XCTAssertEqual(transport.firstStarted.wait(timeout: .now() + 2), .success)
        downloader.start(spec: makeSpec(payload: payloadB, urls: [URL(string: "https://example.invalid/b")!], id: "b", filename: "b.bin"), operationID: operationIDB)
        transport.releaseFirst()
        await fulfillment(of: [bDone], timeout: 2)

        XCTAssertEqual(transport.cancelled, [operationIDA])
        XCTAssertFalse(FileManager.default.fileExists(atPath: modelRoot.appendingPathComponent("a.bin").path))
        XCTAssertEqual(try Data(contentsOf: modelRoot.appendingPathComponent("b.bin")), payloadB)
    }

    func test_badDigestAndNoURLReplacementsCancelPriorOperation() async throws {
        for urls in [[URL(string: "https://example.invalid/bad-digest")!], []] {
            let payload = Data("replacement fixture".utf8)
            let source = root.appendingPathComponent("replacement-\(UUID().uuidString).part")
            try payload.write(to: source)
            let transport = GateBoundedTransport(results: [source])
            let downloader = ModelDownloader(modelRoot: modelRoot.appendingPathComponent(UUID().uuidString), downloadsRoot: downloadsRoot, transport: transport)
            let operationIDA = UUID()
            let operationIDB = UUID()
            let terminal = expectation(description: "replacement rejected")
            downloader.onOperationState = { id, state in
                guard id == operationIDB, case .failed = state else { return }
                terminal.fulfill()
            }

            downloader.start(spec: makeSpec(payload: payload, urls: [URL(string: "https://example.invalid/a")!], id: "a", filename: "a.bin"), operationID: operationIDA)
            XCTAssertEqual(transport.firstStarted.wait(timeout: .now() + 2), .success)
            let specB = makeSpec(payload: payload, urls: urls, digest: urls.isEmpty ? nil : "", id: "b", filename: "b.bin")
            downloader.start(spec: specB, operationID: operationIDB)
            await fulfillment(of: [terminal], timeout: 2)
            transport.releaseFirst()
            XCTAssertEqual(transport.cancelled, [operationIDA])
        }
    }

    func test_overlappingStartsAndCancelNeverCancelWrongOperationID() async throws {
        let payload = Data("concurrent fixture".utf8)
        let transport = BarrierBoundedTransport()
        let operationIDA = UUID()
        let operationIDB = UUID()
        let bRegistered = DispatchSemaphore(value: 0)
        let releaseBRegistration = DispatchSemaphore(value: 0)
        let cancelStarted = DispatchSemaphore(value: 0)
        let cancelFinished = DispatchSemaphore(value: 0)
        let cancelledB = expectation(description: "B cancellation published")
        let recorder = StateRecorder()
        let downloader = ModelDownloader(modelRoot: modelRoot, downloadsRoot: downloadsRoot, transport: transport,
                                          afterTaskRegistration: { id in
            guard id == operationIDB else { return }
            bRegistered.signal()
            releaseBRegistration.wait()
        })
        downloader.onOperationState = { id, state in
            recorder.appendTagged(id, state)
            if id == operationIDB, case .failed(ModelDownloader.ErrorType.cancelled) = state { cancelledB.fulfill() }
        }
        let specA = makeSpec(payload: payload, urls: [URL(string: "https://example.invalid/a")!], id: "a", filename: "a.bin")
        let specB = makeSpec(payload: payload, urls: [URL(string: "https://example.invalid/b")!], id: "b", filename: "b.bin")
        downloader.start(spec: specA, operationID: operationIDA)
        XCTAssertEqual(transport.requestStarted.wait(timeout: .now() + 2), .success)
        DispatchQueue.global().async { downloader.start(spec: specB, operationID: operationIDB) }
        XCTAssertEqual(bRegistered.wait(timeout: .now() + 2), .success)
        DispatchQueue.global().async {
            cancelStarted.signal()
            downloader.cancel()
            cancelFinished.signal()
        }
        XCTAssertEqual(cancelStarted.wait(timeout: .now() + 2), .success)
        releaseBRegistration.signal()
        XCTAssertEqual(cancelFinished.wait(timeout: .now() + 2), .success)
        await fulfillment(of: [cancelledB], timeout: 2)
        transport.releaseRequest()
        transport.releaseRequest()

        let requested = transport.requestIDs()
        let cancelled = transport.cancelledIDs()
        XCTAssertTrue(requested.contains(operationIDA))
        XCTAssertEqual(cancelled.first, operationIDA)
        XCTAssertTrue(Set(cancelled).isSubset(of: Set([operationIDA, operationIDB])))
        XCTAssertFalse(recorder.taggedStates.contains { id, state in id == operationIDA && state.isTerminal })
    }

    func test_cancelRacingRegisteredTaskCancelsThatTaskAndID() async throws {
        let payload = Data("registration fixture".utf8)
        let transport = BarrierBoundedTransport()
        let registrationEntered = DispatchSemaphore(value: 0)
        let releaseRegistration = DispatchSemaphore(value: 0)
        let cancelStarted = DispatchSemaphore(value: 0)
        let cancelFinished = DispatchSemaphore(value: 0)
        let operationID = UUID()
        let cancelledState = expectation(description: "registered operation cancelled")
        let downloader = ModelDownloader(modelRoot: modelRoot, downloadsRoot: downloadsRoot, transport: transport,
                                          afterTaskRegistration: { id in
            guard id == operationID else { return }
            registrationEntered.signal()
            releaseRegistration.wait()
        })
        downloader.onOperationState = { id, state in
            if id == operationID, case .failed(ModelDownloader.ErrorType.cancelled) = state { cancelledState.fulfill() }
        }
        let spec = makeSpec(payload: payload, urls: [URL(string: "https://example.invalid/registration")!])
        DispatchQueue.global().async { downloader.start(spec: spec, operationID: operationID) }
        XCTAssertEqual(registrationEntered.wait(timeout: .now() + 2), .success)
        DispatchQueue.global().async {
            cancelStarted.signal()
            downloader.cancel()
            cancelFinished.signal()
        }
        XCTAssertEqual(cancelStarted.wait(timeout: .now() + 2), .success)
        releaseRegistration.signal()
        XCTAssertEqual(cancelFinished.wait(timeout: .now() + 2), .success)
        await fulfillment(of: [cancelledState], timeout: 2)
        transport.releaseRequest()

        XCTAssertEqual(transport.cancelledIDs(), [operationID])
        XCTAssertTrue(Set(transport.requestIDs()).isSubset(of: Set([operationID])))
    }

    func test_invalidFilenamesRejectBeforeAnyCacheOperationOrTransport() async throws {
        let outside = root.appendingPathComponent("outside")
        let sentinel = Data("do not touch".utf8)
        try sentinel.write(to: outside)
        let invalidFilenames = ["", ".", "..", "../outside", "nested/model.bin", "model" + "\0" + "bin"]
        for filename in invalidFilenames {
            let transport = RecordingBoundedTransport()
            let recorder = CacheOperationRecorder()
            let downloader = ModelDownloader(modelRoot: modelRoot, downloadsRoot: downloadsRoot,
                                              transport: transport, cacheOperations: recorder.operations)
            let failed = expectation(description: "invalid filename rejected: \(filename.debugDescription)")
            downloader.onState = { state in if case .failed = state { failed.fulfill() } }
            downloader.start(spec: makeSpec(payload: Data("payload".utf8), urls: [URL(string: "https://example.invalid/model")!], filename: filename))
            await fulfillment(of: [failed], timeout: 2)
            XCTAssertTrue(recorder.events.isEmpty, filename.debugDescription)
            XCTAssertTrue(transport.requestSnapshot().isEmpty, filename.debugDescription)
            XCTAssertEqual(try Data(contentsOf: outside), sentinel, filename.debugDescription)
        }
    }

    func test_invalidFilenamesNeverInspectTransportOrEscapeModelRoot() async throws {
        let outside = root.appendingPathComponent("outside")
        let sentinel = Data("do not touch".utf8)
        try sentinel.write(to: outside)
        let invalidFilenames = ["", ".", "..", "../outside", "nested/model.bin", "model" + "\0" + "bin"]

        for filename in invalidFilenames {
            let transport = RecordingBoundedTransport()
            let downloader = ModelDownloader(modelRoot: modelRoot, downloadsRoot: downloadsRoot, transport: transport)
            let failed = expectation(description: "invalid filename rejected: \(filename.debugDescription)")
            downloader.onState = { state in
                if case .failed = state { failed.fulfill() }
            }
            downloader.start(spec: makeSpec(payload: Data("payload".utf8), urls: [URL(string: "https://example.invalid/model")!], filename: filename))
            await fulfillment(of: [failed], timeout: 2)
            XCTAssertTrue(transport.requestSnapshot().isEmpty, filename.debugDescription)
            XCTAssertEqual(try Data(contentsOf: outside), sentinel, filename.debugDescription)
        }
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
