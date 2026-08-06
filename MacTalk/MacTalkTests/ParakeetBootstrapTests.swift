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
        XCTAssertNotNil(bootstrap.currentLoadedManager())
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

        XCTAssertTrue(actual.manager === expected)
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
        XCTAssertNil(bootstrap.currentLoadedManager())
    }

    func test_cleanupFailureDoesNotRevokeVerifiedSourceManager() async throws {
        let events = LockedBootstrapEvents()
        let expected = AsrManager()
        let bootstrap = ParakeetBootstrap(
            preparer: FakeBootstrapPreparer(events: events),
            loader: FakeBootstrapLoader(events: events, results: [.success(.init(manager: expected, retained: BootstrapRetentionProbe()))]),
            cleaner: FakeLegacyCleaner(events: events, error: BootstrapTestError.failed)
        )

        let actual = try await bootstrap.ensureReady()

        XCTAssertTrue(actual.manager === expected)
        XCTAssertTrue(bootstrap.currentLoadedManager()?.manager === expected)
        XCTAssertEqual(bootstrap.currentState(), .ready)
        XCTAssertEqual(events.snapshot(), ["load", "cleanup"])
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

        XCTAssertTrue(bootstrap.currentLoadedManager()?.manager === newManager)
        XCTAssertEqual(events.snapshot().filter { $0 == "cleanup" }.count, 1)
        XCTAssertEqual(bootstrap.currentState(), .ready)
    }

    func test_replacementOwnsGenerationBeforePreparationCompletes() async throws {
        let events = LockedBootstrapEvents()
        let oldLoadGate = AsyncBootstrapGate()
        let replacementPreparationGate = AsyncBootstrapGate()
        let oldManager = AsrManager()
        let newManager = AsrManager()
        let bootstrap = ParakeetBootstrap(
            preparer: BlockingBootstrapPreparer(events: events, gate: replacementPreparationGate),
            loader: FakeBootstrapLoader(events: events, results: [
                .blocked(.init(manager: oldManager, retained: BootstrapRetentionProbe()), oldLoadGate),
                .success(.init(manager: newManager, retained: BootstrapRetentionProbe()))
            ]),
            cleaner: FakeLegacyCleaner(events: events)
        )

        let old = Task { try await bootstrap.ensureReady() }
        await oldLoadGate.waitUntilEntered()
        let replacement = Task { try await bootstrap.downloadModels() }
        await replacementPreparationGate.waitUntilEntered()
        await oldLoadGate.release()
        _ = try? await old.value
        XCTAssertNil(bootstrap.currentLoadedManager(), "superseded load published during newer preparation")

        await replacementPreparationGate.release()
        _ = try await replacement.value
        XCTAssertTrue(bootstrap.currentLoadedManager()?.manager === newManager)
        XCTAssertEqual(events.snapshot().filter { $0 == "cleanup" }.count, 1)
    }

    func test_preCancelledDownloadDoesNotSupersedeActiveLoad() async throws {
        let events = LockedBootstrapEvents()
        let activeGate = AsyncBootstrapGate()
        let cancelledEntryGate = AsyncBootstrapGate()
        let activeManager = AsrManager()
        let bootstrap = ParakeetBootstrap(
            preparer: FakeBootstrapPreparer(events: events),
            loader: FakeBootstrapLoader(events: events, results: [
                .blocked(.init(manager: activeManager, retained: BootstrapRetentionProbe()), activeGate),
                .failure(BootstrapTestError.failed)
            ]),
            cleaner: FakeLegacyCleaner(events: events)
        )

        let active = Task { try await bootstrap.ensureReady() }
        await activeGate.waitUntilEntered()
        let cancelled = Task {
            await cancelledEntryGate.enterAndWait()
            return try await bootstrap.downloadModels()
        }
        cancelled.cancel()
        await cancelledEntryGate.release()
        _ = try? await cancelled.value
        await activeGate.release()
        let loaded = try await active.value

        XCTAssertTrue(loaded.manager === activeManager)
        XCTAssertTrue(bootstrap.currentLoadedManager()?.manager === activeManager)
        XCTAssertEqual(events.snapshot().filter { $0 == "prepare" }.count, 0)
        XCTAssertEqual(events.snapshot().filter { $0 == "cleanup" }.count, 1)
    }

    func test_cancellationWinningBeforeGenerationClaimPreservesActiveLoad() async throws {
        let events = LockedBootstrapEvents()
        let activeGate = AsyncBootstrapGate()
        let claimGate = BlockingBootstrapClaimGate()
        let activeManager = AsrManager()
        let bootstrap = ParakeetBootstrap(
            preparer: FakeBootstrapPreparer(events: events),
            loader: FakeBootstrapLoader(events: events, results: [
                .blocked(.init(manager: activeManager, retained: BootstrapRetentionProbe()), activeGate)
            ]),
            cleaner: FakeLegacyCleaner(events: events),
            beforeDownloadClaim: { claimGate.enterAndBlock() }
        )

        let active = Task { try await bootstrap.ensureReady() }
        await activeGate.waitUntilEntered()
        let cancelled = Task { try await bootstrap.downloadModels() }
        await Task.detached { claimGate.waitUntilEntered() }.value
        cancelled.cancel()
        claimGate.release()
        _ = try? await cancelled.value
        await activeGate.release()
        let loaded = try await active.value

        XCTAssertTrue(loaded.manager === activeManager)
        XCTAssertEqual(events.snapshot().filter { $0 == "prepare" }.count, 0)
    }

    func test_cancellingDownloadInvalidatesBlockedLoadAndSkipsCleanup() async {
        let events = LockedBootstrapEvents()
        let gate = AsyncBootstrapGate()
        let bootstrap = ParakeetBootstrap(
            preparer: FakeBootstrapPreparer(events: events),
            loader: FakeBootstrapLoader(events: events, results: [
                .blocked(.init(manager: AsrManager(), retained: BootstrapRetentionProbe()), gate)
            ]),
            cleaner: FakeLegacyCleaner(events: events)
        )

        let download = Task { try await bootstrap.downloadModels() }
        await gate.waitUntilEntered()
        download.cancel()
        await gate.release()
        _ = try? await download.value

        XCTAssertNil(bootstrap.currentLoadedManager())
        XCTAssertEqual(events.snapshot().filter { $0 == "cleanup" }.count, 0)
        XCTAssertEqual(bootstrap.currentState(), .idle)
    }

    func test_cleanupFailureIsRetriedAtNextSafeEnsureBoundary() async throws {
        let events = LockedBootstrapEvents()
        let bootstrap = ParakeetBootstrap(
            preparer: FakeBootstrapPreparer(events: events),
            loader: FakeBootstrapLoader(events: events, results: [
                .success(.init(manager: AsrManager(), retained: BootstrapRetentionProbe()))
            ]),
            cleaner: FakeLegacyCleaner(events: events, failureCount: 1)
        )

        _ = try await bootstrap.ensureReady()
        _ = try await bootstrap.ensureReady()

        XCTAssertEqual(events.snapshot().filter { $0 == "cleanup" }.count, 2)
        XCTAssertEqual(bootstrap.currentState(), .ready)
    }

    func test_consumerHandleRetainsOldAssetsAcrossNewPublication() async throws {
        let events = LockedBootstrapEvents()
        var oldRetention: BootstrapRetentionProbe? = BootstrapRetentionProbe()
        weak var weakOldRetention = oldRetention
        let bootstrap = ParakeetBootstrap(
            preparer: FakeBootstrapPreparer(events: events),
            loader: FakeBootstrapLoader(events: events, results: [
                .success(.init(manager: AsrManager(), retained: oldRetention!)),
                .success(.init(manager: AsrManager(), retained: BootstrapRetentionProbe()))
            ]),
            cleaner: FakeLegacyCleaner(events: events)
        )
        var oldHandle: ParakeetBootstrapLoadedManager? = try await bootstrap.ensureReady()
        oldRetention = nil

        _ = try await bootstrap.downloadModels()
        XCTAssertNotNil(weakOldRetention, "active consumer lost its CoreML asset retention")
        XCTAssertNotNil(oldHandle)
        oldHandle = nil
        XCTAssertNil(weakOldRetention)
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

private struct BlockingBootstrapPreparer: ParakeetBootstrapSourcePreparing {
    let events: LockedBootstrapEvents
    let gate: AsyncBootstrapGate
    func prepare() async throws -> URL {
        events.append("prepare")
        await gate.enterAndWait()
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

private final class FakeLegacyCleaner: ParakeetBootstrapLegacyCleaning, @unchecked Sendable {
    let events: LockedBootstrapEvents
    private let failures: OSAllocatedUnfairLock<Int>
    init(events: LockedBootstrapEvents, error: BootstrapTestError? = nil, failureCount: Int = 0) {
        self.events = events
        self.failures = OSAllocatedUnfairLock(initialState: error == nil ? failureCount : 1)
    }
    func removeCompiledGeneration() async throws {
        events.append("cleanup")
        let shouldFail = failures.withLock { value -> Bool in
            guard value > 0 else { return false }
            value -= 1
            return true
        }
        if shouldFail { throw BootstrapTestError.failed }
    }
}

private final class BlockingBootstrapClaimGate: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)
    func enterAndBlock() {
        entered.signal()
        released.wait()
    }
    func waitUntilEntered() { entered.wait() }
    func release() { released.signal() }
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
