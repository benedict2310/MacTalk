import XCTest
@testable import MacTalk
@preconcurrency import AVFoundation

@MainActor
final class EngineReloadCoordinatorTests: XCTestCase {
    func test_modelChangeDuringRecordingAppliesOnNextStart() async throws {
        let first = EngineSelection(provider: .whisper, modelID: "model-a", revision: "rev-a")
        let second = EngineSelection(provider: .whisper, modelID: "model-b", revision: "rev-b")
        let loader = FakeEngineSelectionLoader()
        let coordinator = EngineReloadCoordinator(loader: loader)

        let firstEngine = try await coordinator.reconcile(
            pending: PendingSettingsSnapshot(engine: first),
            isRecording: false
        )
        let activeEngine = try await coordinator.reconcile(
            pending: PendingSettingsSnapshot(engine: second),
            isRecording: true
        )

        XCTAssertEqual(ObjectIdentifier(firstEngine as AnyObject), ObjectIdentifier(activeEngine as AnyObject))
        XCTAssertEqual(loader.loadedSelections, [first])
        XCTAssertEqual(coordinator.loadedSelection, first)

        let nextEngine = try await coordinator.reconcile(
            pending: PendingSettingsSnapshot(engine: second),
            isRecording: false
        )
        XCTAssertNotEqual(ObjectIdentifier(firstEngine as AnyObject), ObjectIdentifier(nextEngine as AnyObject))
        XCTAssertEqual(loader.loadedSelections, [first, second])
        XCTAssertEqual(coordinator.loadedSelection, second)
    }

    func test_providerChangeDuringRecordingAppliesOnNextStart() async throws {
        let whisper = EngineSelection(provider: .whisper, modelID: "model-a", revision: "rev-a")
        let parakeet = EngineSelection.parakeet
        let loader = FakeEngineSelectionLoader()
        let coordinator = EngineReloadCoordinator(loader: loader)

        _ = try await coordinator.reconcile(
            pending: PendingSettingsSnapshot(engine: whisper),
            isRecording: false
        )
        _ = try await coordinator.reconcile(
            pending: PendingSettingsSnapshot(engine: parakeet),
            isRecording: true
        )
        XCTAssertEqual(loader.loadedSelections, [whisper])
        XCTAssertEqual(coordinator.loadedSelection, whisper)

        _ = try await coordinator.reconcile(
            pending: PendingSettingsSnapshot(engine: parakeet),
            isRecording: false
        )
        XCTAssertEqual(loader.loadedSelections, [whisper, parakeet])
        XCTAssertEqual(coordinator.loadedSelection, parakeet)
    }

    func test_whisperIdentityIncludesProviderModelAndRevision() throws {
        let spec = try XCTUnwrap(ModelCatalog.bundled().first)
        let selection = EngineSelection.whisper(spec)

        XCTAssertEqual(selection.provider, .whisper)
        XCTAssertEqual(selection.modelID, spec.id)
        XCTAssertEqual(selection.revision, spec.sha256)
    }
}

private final class FakeEngineSelectionLoader: EngineSelectionLoader, @unchecked Sendable {
    private(set) var loadedSelections: [EngineSelection] = []

    func load(selection: EngineSelection) async throws -> any ASREngine {
        loadedSelections.append(selection)
        return FakeASREngine(provider: selection.provider)
    }
}

private final class FakeASREngine: ASREngine, @unchecked Sendable {
    let provider: ASRProvider

    init(provider: ASRProvider) {
        self.provider = provider
    }

    func prepare() async throws {}
    func reset() async {}
    func process(_ buffer: AVAudioPCMBuffer, language: String?) async throws -> ASRPartial? { nil }
    func finalize(_ buffer: AVAudioPCMBuffer, language: String?) async throws -> ASRFinalSegment? { nil }
    func setPartialHandler(_ handler: (@Sendable (ASRPartial) -> Void)?) {}
}
