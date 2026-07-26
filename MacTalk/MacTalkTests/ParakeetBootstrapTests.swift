import XCTest
import FluidAudio
import os
@testable import MacTalk

final class ParakeetBootstrapTests: XCTestCase {
    func test_downloadPreparesThenLoadsVerifiedSourceAndRetainsAssets() async throws {
        let events = LockedBootstrapEvents()
        let preparer = FakeBootstrapPreparer(events: events)
        var retained: BootstrapRetentionProbe? = BootstrapRetentionProbe()
        weak var weakRetained = retained
        let loader = FakeBootstrapLoader(events: events, results: [.success(.init(manager: AsrManager(), retained: retained!))])
        let cleaner = FakeLegacyCleaner(events: events)
        let bootstrap = ParakeetBootstrap(preparer: preparer, loader: loader, cleaner: cleaner)
        retained = nil

        _ = try await bootstrap.downloadModels()

        XCTAssertEqual(events.snapshot(), ["prepare", "load", "cleanup"])
        XCTAssertNotNil(bootstrap.currentManager())
        XCTAssertNotNil(weakRetained, "verified snapshot/assets must live with the published manager")
        XCTAssertEqual(bootstrap.currentState(), .ready)
    }

    func test_ensureReadyNeverPreparesOrFallsBackToCompiledPaths() async throws {
        let events = LockedBootstrapEvents()
        let expected = AsrManager()
        let bootstrap = ParakeetBootstrap(
            preparer: FakeBootstrapPreparer(events: events),
            loader: FakeBootstrapLoader(events: events, results: [.success(.init(manager: expected, retained: BootstrapRetentionProbe()))]),
            cleaner: FakeLegacyCleaner(events: events)
        )

        let actual = try await bootstrap.ensureReady()

        XCTAssertTrue(actual === expected)
        XCTAssertEqual(events.snapshot(), ["load", "cleanup"])
    }

    func test_failedVerifiedLoadPreservesRetryMaterialAndSkipsCleanup() async {
        let events = LockedBootstrapEvents()
        let bootstrap = ParakeetBootstrap(
            preparer: FakeBootstrapPreparer(events: events),
            loader: FakeBootstrapLoader(events: events, results: [.failure(BootstrapTestError.failed)]),
            cleaner: FakeLegacyCleaner(events: events)
        )

        do {
            _ = try await bootstrap.downloadModels()
            XCTFail("load unexpectedly succeeded")
        } catch {}

        XCTAssertEqual(events.snapshot(), ["prepare", "load"])
        XCTAssertNil(bootstrap.currentManager())
    }

    func test_newDownloadGenerationPreventsOlderLoadPublishing() async throws {
        let events = LockedBootstrapEvents()
        let gate = AsyncBootstrapGate()
        let oldManager = AsrManager()
        let newManager = AsrManager()
        let loader = FakeBootstrapLoader(events: events, results: [
            .blocked(.init(manager: oldManager, retained: BootstrapRetentionProbe()), gate),
            .success(.init(manager: newManager, retained: BootstrapRetentionProbe()))
        ])
        let bootstrap = ParakeetBootstrap(
            preparer: FakeBootstrapPreparer(events: events),
            loader: loader,
            cleaner: FakeLegacyCleaner(events: events)
        )

        let old = Task { try await bootstrap.ensureReady() }
        await gate.waitUntilEntered()
        let replacement = Task { try await bootstrap.downloadModels() }
        let replacementURL = try await replacement.value
        XCTAssertFalse(replacementURL.path.isEmpty)
        await gate.release()
        _ = try? await old.value

        XCTAssertTrue(bootstrap.currentManager() === newManager)
        XCTAssertEqual(events.snapshot().filter { $0 == "cleanup" }.count, 1)
        XCTAssertEqual(bootstrap.currentState(), .ready)
    }
}

private enum BootstrapTestError: Error { case failed }
private final class BootstrapRetentionProbe: NSObject {}

private final class LockedBootstrapEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
    func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return values }
}

private struct FakeBootstrapPreparer: ParakeetBootstrapSourcePreparing {
    let events: LockedBootstrapEvents
    func prepare() async throws -> URL {
        events.append("prepare")
        return URL(fileURLWithPath: "/verified-source")
    }
}

private final class FakeBootstrapLoader: ParakeetBootstrapVerifiedLoading, @unchecked Sendable {
    enum Result {
        case success(ParakeetBootstrapLoadedManager)
        case failure(Error)
        case blocked(ParakeetBootstrapLoadedManager, AsyncBootstrapGate)
    }
    private let results: OSAllocatedUnfairLock<[Result]>
    private let events: LockedBootstrapEvents
    init(events: LockedBootstrapEvents, results: [Result]) {
        self.events = events
        self.results = OSAllocatedUnfairLock(initialState: results)
    }
    func load() async throws -> ParakeetBootstrapLoadedManager {
        events.append("load")
        let result = results.withLock { $0.removeFirst() }
        switch result {
        case .success(let loaded): return loaded
        case .failure(let error): throw error
        case .blocked(let loaded, let gate): await gate.enterAndWait(); return loaded
        }
    }
}

private struct FakeLegacyCleaner: ParakeetBootstrapLegacyCleaning {
    let events: LockedBootstrapEvents
    func removeCompiledGeneration() async throws { events.append("cleanup") }
}

private actor AsyncBootstrapGate {
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    func enterAndWait() async {
        entered = true
        enteredWaiters.forEach { $0.resume() }; enteredWaiters.removeAll()
        if released { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }
    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }; releaseWaiters.removeAll()
    }
}
