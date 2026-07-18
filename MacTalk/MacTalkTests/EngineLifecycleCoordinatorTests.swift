import XCTest
@testable import MacTalk
@preconcurrency import AVFoundation

@MainActor
final class EngineLifecycleCoordinatorTests: XCTestCase {
    func test_exactIdentityIsReusedWithoutCrossProviderAdoption() async throws {
        let first = EngineSelection(provider: .whisper, modelID: "a", revision: "1")
        let loader = LifecycleLoader()
        let coordinator = EngineLifecycleCoordinator(loader: loader, availability: { _ in true })

        let firstResult = await coordinator.resolve(first, requestID: UUID())
        let one = try XCTUnwrap(ready(firstResult))
        let secondResult = await coordinator.resolve(first, requestID: UUID())
        let two = try XCTUnwrap(ready(secondResult))
        XCTAssertEqual(ObjectIdentifier(one as AnyObject), ObjectIdentifier(two as AnyObject))
        XCTAssertEqual(loader.selections, [first])
    }

    func test_unverifiedLocalAvailabilityRequiresDownloadAndNeverLoads() async {
        let selection = EngineSelection(provider: .whisper, modelID: "missing", revision: "bad")
        let loader = LifecycleLoader()
        let coordinator = EngineLifecycleCoordinator(loader: loader, availability: { _ in false })

        let result = await coordinator.resolve(selection, requestID: UUID())
        guard case .requiresDownload = result else {
            return XCTFail("unavailable catalog identity should require a tagged download")
        }
        XCTAssertTrue(loader.selections.isEmpty)
    }

    func test_settingsChangeWhileRecordingDoesNotReplaceReadyEngine() async throws {
        let first = EngineSelection(provider: .whisper, modelID: "a", revision: "1")
        let second = EngineSelection(provider: .parakeet, modelID: "p", revision: "r")
        let loader = LifecycleLoader()
        let coordinator = EngineLifecycleCoordinator(loader: loader, availability: { _ in true })
        let firstResult = await coordinator.resolve(first, requestID: UUID())
        let firstEngine = try XCTUnwrap(ready(firstResult))

        coordinator.settingsChanged(to: snapshot(provider: .parakeet), recordingActive: true)
        let result = await coordinator.resolve(second, requestID: UUID())
        guard case .failed = result else { return XCTFail("active engine was replaced") }
        XCTAssertEqual(ObjectIdentifier(firstEngine as AnyObject), ObjectIdentifier(loader.engines[0]))
    }

    private func ready(_ result: EngineResolution) -> (any ASREngine)? {
        guard case let .ready(engine) = result else { return nil }
        return engine
    }

    private func snapshot(provider: ASRProvider) -> SettingsSnapshot {
        SettingsSnapshot(provider: provider, whisperModelID: "unused", language: nil, captureMode: .micOnly, showNotifications: true, autoPaste: false)
    }
}

@MainActor
private final class LifecycleLoader: EngineSelectionLoader {
    var selections: [EngineSelection] = []
    var engines: [TestEngine] = []

    func load(selection: EngineSelection) async throws -> any ASREngine {
        selections.append(selection)
        let engine = TestEngine(provider: selection.provider)
        engines.append(engine)
        return engine
    }
}

private final class TestEngine: ASREngine, @unchecked Sendable {
    let provider: ASRProvider
    init(provider: ASRProvider) { self.provider = provider }
    func prepare() async throws {}
    func reset() async {}
    func process(_ buffer: AVAudioPCMBuffer, language: String?) async throws -> ASRPartial? { nil }
    func finalize(_ buffer: AVAudioPCMBuffer, language: String?) async throws -> ASRFinalSegment? { nil }
    func setPartialHandler(_ handler: (@Sendable (ASRPartial) -> Void)?) {}
}
