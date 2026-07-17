import XCTest
import CryptoKit
@testable import MacTalk

private final class NetworkTrapURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requests: [URL] = []
    static let lock = NSLock()
    nonisolated(unsafe) static var payload = Data()

    static func reset(with payload: Data) {
        lock.lock(); requests = []; self.payload = payload; lock.unlock()
    }

    static func requestSnapshot() -> [URL] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.requests.append(request.url!); let body = Self.payload; Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ModelSecurityTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        let lock = NSLock()
        var resumes: [Data?] = []
        var requests: [URL] = []
        func append(_ request: URLRequest, resume: Data?) {
            lock.lock(); defer { lock.unlock() }
            requests.append(request.url!)
            resumes.append(resume)
        }
    }

    private var root: URL!
    private var downloads: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MacTalk-Security-\(UUID().uuidString)")
        downloads = root.appendingPathComponent("downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func test_resumeEnvelopeUsesExistingIdentityBeforeTransfer() async throws {
        let payload = Data("verified model".utf8)
        let spec = makeSpec(payload: payload)
        let mirror = try XCTUnwrap(spec.urls.first)
        try writeEnvelope(spec: spec, mirror: mirror, bytes: Data("opaque".utf8))
        let recorder = Recorder()
        let testRoot = root!
        let downloader = ModelDownloader(modelRoot: testRoot, downloadsRoot: downloads,
                                         resumableTaskFactory: { request, resume in
            recorder.append(request, resume: resume)
            let temporary = testRoot.appendingPathComponent("result")
            try payload.write(to: temporary)
            return (temporary, Self.response(for: request.url!, status: 200), nil)
        })
        let done = expectation(description: "download done")
        downloader.onState = { state in if case .done = state { done.fulfill() } }
        downloader.start(spec: spec)
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(recorder.resumes.first!, Data("opaque".utf8))
    }

    func test_identityMismatchClearsEnvelopeAndUsesCleanSameMirror() async throws {
        let payload = Data("verified model".utf8)
        let source = try XCTUnwrap(URL(string: "https://mirror.invalid/model"))
        let cases: [(String, String, Int64, URL)] = [
            ("new-revision", String(repeating: "a", count: 64), Int64(payload.count), source),
            ("rev", String(repeating: "b", count: 64), Int64(payload.count), source),
            ("rev", String(repeating: "b", count: 64), Int64(payload.count + 1), source),
            ("rev", String(repeating: "b", count: 64), Int64(payload.count), URL(string: "https://other.invalid/model")!)
        ]
        for (revision, digest, size, oldMirror) in cases {
            let spec = makeSpec(payload: payload)
            let old = ModelSpec(id: spec.id, displayName: spec.displayName, filename: spec.filename,
                                sha256: digest, sizeBytes: size, urls: [oldMirror], license: nil,
                                languages: nil, revision: revision)
            try writeEnvelope(spec: old, mirror: oldMirror, bytes: Data("stale".utf8))
            let recorder = Recorder()
            let testRoot = root!
            let downloader = ModelDownloader(modelRoot: testRoot.appendingPathComponent(UUID().uuidString),
                                             downloadsRoot: downloads,
                                             resumableTaskFactory: { request, resume in
                recorder.append(request, resume: resume)
                let temporary = testRoot.appendingPathComponent(UUID().uuidString)
                try payload.write(to: temporary)
                return (temporary, Self.response(for: request.url!, status: 200), nil)
            })
            let done = expectation(description: "mismatch clean")
            downloader.onState = { state in if case .done = state { done.fulfill() } }
            downloader.start(spec: spec)
            await fulfillment(of: [done], timeout: 2)
            XCTAssertEqual(recorder.resumes.first!, nil, "identity mismatch must not resume")
            try? FileManager.default.removeItem(at: downloads.appendingPathComponent("\(spec.id).resume"))
        }
    }

    func test_corruptEnvelopeIsDiscarded() async throws {
        let spec = makeSpec(payload: Data("verified model".utf8))
        try Data("not json".utf8).write(to: downloads.appendingPathComponent("\(spec.id).resume"))
        let recorder = Recorder()
        let testRoot = root!
        let downloader = ModelDownloader(modelRoot: testRoot, downloadsRoot: downloads,
                                         resumableTaskFactory: { request, resume in
            recorder.append(request, resume: resume)
            let temporary = testRoot.appendingPathComponent("corrupt-result")
            try Data("verified model".utf8).write(to: temporary)
            return (temporary, Self.response(for: request.url!, status: 200), nil)
        })
        let done = expectation(description: "corrupt envelope recovery")
        downloader.onState = { state in if case .done = state { done.fulfill() } }
        downloader.start(spec: spec)
        await fulfillment(of: [done], timeout: 2)
        XCTAssertNil(recorder.resumes.first!)
    }

    func test_urlSessionNetworkTrapIsUsedForHermeticTransfer() async throws {
        let payload = Data("verified model".utf8)
        let spec = makeSpec(payload: payload)
        NetworkTrapURLProtocol.reset(with: payload)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NetworkTrapURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let downloader = ModelDownloader(session: session, modelRoot: root, downloadsRoot: downloads)
        let done = expectation(description: "URLProtocol transfer done")
        downloader.onState = { state in if case .done = state { done.fulfill() } }
        downloader.start(spec: spec)
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(NetworkTrapURLProtocol.requestSnapshot(), [spec.urls[0]])
    }

    func test_httpTemporaryFileIsRemoved() async throws {
        let spec = makeSpec(payload: Data("verified model".utf8))
        let temporary = root.appendingPathComponent("http-result")
        try Data("bad response".utf8).write(to: temporary)
        let downloader = ModelDownloader(modelRoot: root, downloadsRoot: downloads,
                                         taskFactory: { request in
            (temporary, Self.response(for: request.url!, status: 503))
        })
        let failed = expectation(description: "HTTP failure")
        downloader.onState = { state in if case .failed = state { failed.fulfill() } }
        downloader.start(spec: spec)
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
        XCTAssertTrue(((try? FileManager.default.contentsOfDirectory(at: downloads, includingPropertiesForKeys: nil)) ?? []).allSatisfy { !$0.lastPathComponent.contains("resume-result") })
    }

    private func makeSpec(payload: Data) -> ModelSpec {
        ModelSpec(id: "fixture", displayName: "Fixture", filename: "fixture.bin",
                  sha256: SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined(), sizeBytes: Int64(payload.count),
                  urls: [URL(string: "https://mirror.invalid/fixture")!], license: nil, languages: nil)
    }

    private func writeEnvelope(spec: ModelSpec, mirror: URL, bytes: Data) throws {
        let metadata: [String: Any] = ["id": spec.id, "source": spec.source, "revision": spec.revision,
                                       "digest": spec.sha256, "size": spec.sizeBytes, "mirrorURL": mirror.absoluteString]
        let envelope: [String: Any] = ["metadata": metadata, "resumeData": bytes.base64EncodedString()]
        let data = try JSONSerialization.data(withJSONObject: envelope)
        try data.write(to: downloads.appendingPathComponent("\(spec.id).resume"), options: .atomic)
    }

    private static func response(for url: URL, status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
    }
}
