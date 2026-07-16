import XCTest
@testable import MacTalk
@preconcurrency import AVFoundation

final class EngineSelectionLoaderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacTalkEngineSelection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func test_corruptWhisperCacheIsRejectedBeforeEngineInitialization() async throws {
        let spec = try XCTUnwrap(ModelCatalog.bundled().first)
        let fixture = try write(Data("corrupt model cache".utf8))
        let probe = LoaderProbe()
        let loader = DefaultEngineSelectionLoader(
            integrityValidator: { source, validatedSpec in
                probe.validationURL = source
                probe.validatedSpec = validatedSpec
                throw ModelDownloader.ErrorType.badChecksum
            },
            modelPath: { _ in fixture },
            whisperEngineFactory: { _ in
                probe.engineInitializationCount += 1
                return UninitializedFakeEngine()
            }
        )

        do {
            _ = try await loader.load(selection: .whisper(spec))
            XCTFail("A corrupt cache must not be initialized")
        } catch {
            XCTAssertEqual((error as NSError).code, 4)
        }

        XCTAssertEqual(probe.validationURL, fixture)
        XCTAssertEqual(probe.validatedSpec, spec)
        XCTAssertEqual(probe.engineInitializationCount, 0)
    }

    func test_unverifiedWhisperCacheIsRejectedBeforeEngineInitialization() async throws {
        let spec = try XCTUnwrap(ModelCatalog.bundled().first)
        let fixture = try write(Data("unverified model cache".utf8))
        let probe = LoaderProbe()
        let loader = DefaultEngineSelectionLoader(
            modelPath: { _ in fixture },
            whisperEngineFactory: { _ in
                probe.engineInitializationCount += 1
                return UninitializedFakeEngine()
            }
        )

        do {
            _ = try await loader.load(selection: .whisper(spec))
            XCTFail("A model without a trusted digest must not be initialized")
        } catch {
            XCTAssertEqual((error as NSError).code, 4)
            guard let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? ModelDownloader.ErrorType,
                  case .badChecksum = underlying else {
                return XCTFail("Expected the integrity validator's badChecksum error")
            }
        }

        XCTAssertEqual(probe.engineInitializationCount, 0)
    }

    private func write(_ data: Data) throws -> URL {
        let url = directory.appendingPathComponent(UUID().uuidString)
        try data.write(to: url)
        return url
    }
}

private final class LoaderProbe: @unchecked Sendable {
    var validationURL: URL?
    var validatedSpec: ModelSpec?
    var engineInitializationCount = 0
}

private final class UninitializedFakeEngine: ASREngine, @unchecked Sendable {
    let provider: ASRProvider = .whisper

    func prepare() async throws {}
    func reset() async {}
    func process(_ buffer: AVAudioPCMBuffer, language: String?) async throws -> ASRPartial? { nil }
    func finalize(_ buffer: AVAudioPCMBuffer, language: String?) async throws -> ASRFinalSegment? { nil }
    func setPartialHandler(_ handler: (@Sendable (ASRPartial) -> Void)?) {}
}
