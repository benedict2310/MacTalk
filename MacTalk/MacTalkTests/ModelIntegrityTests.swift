import XCTest
@testable import MacTalk

private final class FailingBoundedTransport: BoundedModelDownloading, @unchecked Sendable {
    private let onRequest: () -> Void
    init(onRequest: @escaping () -> Void) { self.onRequest = onRequest }
    func download(_ request: BoundedModelDownloadRequest) async throws -> URL {
        onRequest()
        throw URLError(.badURL)
    }
    func cancel(operationID: UUID) {}
}

final class ModelIntegrityTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacTalkModelIntegrity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func test_sha256StreamerMatchesKnownDigest() throws {
        let source = try write(Data("hello\n".utf8), named: "hash-fixture")

        XCTAssertEqual(
            try SHA256Streamer.hashFile(at: source),
            "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03"
        )
    }

    func test_validChecksumAndExpectedSizeAreAccepted() throws {
        let payload = Data("known model fixture".utf8)
        let source = try write(payload, named: "download.part")
        let destination = directory.appendingPathComponent("model.bin")
        let spec = makeSpec(sha256: try SHA256Streamer.hashFile(at: source), size: Int64(payload.count))

        try ModelIntegrityVerifier.verifyAndMove(source: source, destination: destination, spec: spec)

        XCTAssertEqual(try Data(contentsOf: destination), payload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    func test_invalidChecksumIsRejectedAndTemporaryFileIsRemoved() throws {
        let source = try write(Data("not the expected model".utf8), named: "download.part")
        let destination = directory.appendingPathComponent("model.bin")
        let spec = makeSpec(sha256: String(repeating: "a", count: 64), size: 22)

        XCTAssertThrowsError(try ModelIntegrityVerifier.verifyAndMove(source: source, destination: destination, spec: spec)) { error in
            guard case ModelDownloader.ErrorType.badChecksum = error else {
                return XCTFail("Expected badChecksum, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func test_missingOrMalformedChecksumFailsClosed() throws {
        let source = try write(Data("fixture".utf8), named: "download.part")
        let destination = directory.appendingPathComponent("model.bin")
        for digest in ["", "not-a-digest", String(repeating: "A", count: 64), String(repeating: "0", count: 63)] {
            let copy = directory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.copyItem(at: source, to: copy)
            let spec = makeSpec(sha256: digest, size: 7)
            XCTAssertThrowsError(try ModelIntegrityVerifier.verifyAndMove(source: copy, destination: destination, spec: spec)) { error in
                guard case ModelDownloader.ErrorType.badChecksum = error else {
                    return XCTFail("Expected badChecksum for \(digest), got \(error)")
                }
            }
        }
    }

    func test_modelDownloaderRejectsMissingDigestBeforeStartingDownload() async {
        let modelsRoot = directory.appendingPathComponent("models")
        let downloadsRoot = directory.appendingPathComponent("downloads")
        let requestStarted = expectation(description: "network must not start")
        requestStarted.isInverted = true
        let downloader = ModelDownloader(modelRoot: modelsRoot, downloadsRoot: downloadsRoot,
                                         transport: FailingBoundedTransport {
            requestStarted.fulfill()
        })
        let rejected = expectation(description: "missing digest rejected")
        downloader.onState = { state in
            if case .failed(ModelDownloader.ErrorType.badChecksum) = state {
                rejected.fulfill()
            }
        }
        downloader.start(spec: makeSpec(
            sha256: "",
            size: 1,
            url: URL(string: "https://example.invalid/never-requested.bin")!
        ))

        await fulfillment(of: [rejected, requestStarted], timeout: 1)
    }

    func test_wrongSizeIsRejectedBeforeDestinationReplacement() throws {
        let oldPayload = Data("existing trusted model".utf8)
        let destination = try write(oldPayload, named: "model.bin")
        let source = try write(Data("wrong size".utf8), named: "download.part")
        let digest = try SHA256Streamer.hashFile(at: source)
        let spec = makeSpec(sha256: digest, size: 20_000_000)

        XCTAssertThrowsError(try ModelIntegrityVerifier.verifyAndMove(source: source, destination: destination, spec: spec))
        XCTAssertEqual(try Data(contentsOf: destination), oldPayload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    func test_existingDestinationIsReplacedOnlyAfterSuccessfulVerification() throws {
        let destination = try write(Data("old".utf8), named: "model.bin")
        let source = try write(Data("new model".utf8), named: "download.part")
        let payload = try Data(contentsOf: source)
        let spec = makeSpec(sha256: try SHA256Streamer.hashFile(at: source), size: Int64(payload.count))

        try ModelIntegrityVerifier.verifyAndMove(source: source, destination: destination, spec: spec)

        XCTAssertEqual(try Data(contentsOf: destination), payload)
    }

    private func makeSpec(sha256: String, size: Int64,
                          url: URL = URL(string: "https://example.invalid/model.bin")!) -> ModelSpec {
        ModelSpec(id: "fixture", displayName: "Fixture", filename: "model.bin", sha256: sha256,
                  sizeBytes: size, urls: [url], license: nil, languages: nil)
    }

    @discardableResult
    private func write(_ data: Data, named: String) throws -> URL {
        let url = directory.appendingPathComponent(named)
        try data.write(to: url)
        return url
    }
}
