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

    func test_unverifiedLocalAvailabilityRequiresDownloadAndNeverLoads() async throws {
        let spec = try XCTUnwrap(ModelCatalog.bundled().first)
        let selection = EngineSelection.whisper(spec)
        let loader = LifecycleLoader()
        let coordinator = EngineLifecycleCoordinator(loader: loader, availability: { _ in false })

        let result = await coordinator.resolve(selection, requestID: UUID())
        guard case .requiresDownload(.whisper(let requirement)) = result else {
            return XCTFail("known but unavailable catalog identity should require a tagged download")
        }
        XCTAssertEqual(requirement, spec)
        XCTAssertTrue(loader.selections.isEmpty)
    }

    func test_unknownIdentityFailsInsteadOfRequestingDownload() async {
        let selection = EngineSelection(provider: .whisper, modelID: "unknown", revision: "bad")
        let loader = LifecycleLoader()
        let coordinator = EngineLifecycleCoordinator(loader: loader, availability: { _ in false })

        let result = await coordinator.resolve(selection, requestID: UUID())
        guard case .failed = result else {
            return XCTFail("unknown catalog identity must fail without an untagged download")
        }
        XCTAssertTrue(loader.selections.isEmpty)
    }

    func test_supersededDelayedLoadIsStaleAndCannotBecomeReady() async throws {
        let first = EngineSelection(provider: .whisper, modelID: "a", revision: "1")
        let second = EngineSelection(provider: .whisper, modelID: "b", revision: "2")
        let loader = DelayedLifecycleLoader()
        let coordinator = EngineLifecycleCoordinator(loader: loader, availability: { _ in true })
        let firstID = UUID()
        let secondID = UUID()

        let firstTask = Task { await coordinator.resolve(first, requestID: firstID) }
        await loader.waitUntilStarted(first)
        let secondTask = Task { await coordinator.resolve(second, requestID: secondID) }
        await loader.waitUntilStarted(second)
        loader.release(first, engine: TestEngine(provider: .whisper))
        loader.release(second, engine: TestEngine(provider: .whisper))

        guard case .stale = await firstTask.value else {
            return XCTFail("superseded load must be typed stale")
        }
        guard case .ready = await secondTask.value else {
            return XCTFail("current selection should be ready")
        }
        guard case let .ready(selection, _) = coordinator.state else {
            return XCTFail("superseded result must not alter lifecycle state")
        }
        XCTAssertEqual(selection, second)
    }

    func test_cancelledDelayedLoadCannotBeAdopted() async {
        let selection = EngineSelection(provider: .whisper, modelID: "a", revision: "1")
        let loader = DelayedLifecycleLoader()
        let coordinator = EngineLifecycleCoordinator(loader: loader, availability: { _ in true })
        let requestID = UUID()
        let task = Task { await coordinator.resolve(selection, requestID: requestID) }
        await loader.waitUntilStarted(selection)
        coordinator.cancel(requestID: requestID)
        loader.release(selection, engine: TestEngine(provider: .whisper))
        guard case .cancelled = await task.value else {
            return XCTFail("cancelled load must remain cancelled")
        }
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
private final class DelayedLifecycleLoader: EngineSelectionLoader {
    var started: Set<String> = []
    var waiters: [String: CheckedContinuation<any ASREngine, Error>] = [:]

    func load(selection: EngineSelection) async throws -> any ASREngine {
        started.insert(key(selection))
        return try await withCheckedThrowingContinuation { continuation in
            waiters[key(selection)] = continuation
        }
    }

    func waitUntilStarted(_ selection: EngineSelection) async {
        while !started.contains(key(selection)) { await Task.yield() }
    }

    func release(_ selection: EngineSelection, engine: any ASREngine) {
        waiters.removeValue(forKey: key(selection))?.resume(returning: engine)
    }

    private func key(_ selection: EngineSelection) -> String {
        "\(selection.provider.rawValue):\(selection.modelID):\(selection.revision)"
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
