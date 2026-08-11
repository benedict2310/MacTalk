import XCTest
@preconcurrency import CoreMedia
@testable import MacTalk

final class ScreenAudioCaptureTests: XCTestCase {
    func test_stopDuringDiscoveryRetiresOperationBeforeLateStreamCanPublish() async throws {
        let driver = DeterministicScreenStreamDriver()
        driver.pauseDiscovery = true
        let lifecycle = ScreenCaptureLifecycle(driver: driver)
        let start = Task {
            try await lifecycle.start(request: "first", sessionID: UUID(), onAudioSampleBuffer: { _, _ in }, onStreamError: { _, _ in })
        }

        await driver.waitForDiscovery()
        lifecycle.requestStop()
        let stop = Task { try await lifecycle.stopAndWait() }
        driver.resumeDiscovery()

        do {
            _ = try await start.value
            XCTFail("retired start unexpectedly succeeded")
        } catch is CancellationError {
            // Expected: retirement is represented as typed cancellation.
        }
        try await stop.value
        XCTAssertEqual(driver.createdCount, 1)
        XCTAssertEqual(driver.stopCount, 1)
        XCTAssertFalse(lifecycle.hasActiveStream)
    }

    func test_stopFailureIsRetainedAndRetried() async throws {
        let driver = StatefulScreenStreamDriver()
        driver.stopFailuresRemaining = 1
        let lifecycle = ScreenCaptureLifecycle(driver: driver)

        _ = try await start(lifecycle, request: "first")
        lifecycle.requestStop()

        do {
            try await lifecycle.stopAndWait()
            XCTFail("first stop should fail")
        } catch is ScreenCaptureLifecycleError {
            // The failed operation remains owned and retryable.
        }
        XCTAssertTrue(driver.isActive)

        try await lifecycle.stopAndWait()
        XCTAssertFalse(driver.isActive)
        XCTAssertEqual(driver.stopCount, 2)
    }

    func test_stopAndWaitInPublicationWindowCannotReturnEarly() async throws {
        let driver = StatefulScreenStreamDriver()
        driver.pauseDiscovery = true
        let lifecycle = ScreenCaptureLifecycle(driver: driver)
        let startTask = Task { try await lifecycle.start(request: "first", sessionID: UUID(), onAudioSampleBuffer: { _, _ in }, onStreamError: { _, _ in }) }
        await driver.waitForDiscovery()

        let stopTask = Task { try await lifecycle.stopAndWait() }
        await Task.yield()
        XCTAssertFalse(stopTask.isCancelled)
        XCTAssertEqual(driver.stopCount, 0)

        driver.resumeDiscovery()
        _ = try? await startTask.value
        try await stopTask.value
        XCTAssertFalse(driver.isActive)
    }

    func test_concurrentStopWaitersShareSuccessfulStop() async throws {
        let driver = StatefulScreenStreamDriver()
        driver.pauseStart = true
        let lifecycle = ScreenCaptureLifecycle(driver: driver)
        let startTask = Task { try await lifecycle.start(request: "first", sessionID: UUID(), onAudioSampleBuffer: { _, _ in }, onStreamError: { _, _ in }) }
        await driver.waitForStart()
        lifecycle.requestStop()

        let first = Task { try await lifecycle.stopAndWait() }
        let second = Task { try await lifecycle.stopAndWait() }
        driver.resumeStart()
        _ = try? await startTask.value
        try await first.value
        try await second.value
        XCTAssertEqual(driver.stopCount, 1)
        XCTAssertFalse(driver.isActive)
    }

    func test_replacementWaitsForOldSuccessfulStop() async throws {
        let driver = StatefulScreenStreamDriver()
        driver.pauseStop = true
        let lifecycle = ScreenCaptureLifecycle(driver: driver)
        _ = try await start(lifecycle, request: "first")
        lifecycle.requestStop()

        let replacement = Task { try await lifecycle.start(request: "second", sessionID: UUID(), onAudioSampleBuffer: { _, _ in }, onStreamError: { _, _ in }) }
        await driver.waitForStop()
        XCTAssertEqual(driver.createdCount, 1)
        driver.resumeStop()
        driver.pauseStop = false
        _ = try await replacement.value
        XCTAssertEqual(driver.createdCount, 2)
        XCTAssertTrue(driver.isActive)
        lifecycle.requestStop()
        try await lifecycle.stopAndWait()
    }

    func test_overlappingReplacementsRetainOldFailedRetirementForRetry() async throws {
        let driver = StatefulScreenStreamDriver()
        let lifecycle = ScreenCaptureLifecycle(driver: driver)
        _ = try await start(lifecycle, request: "first")
        driver.pauseStop = true
        driver.stopFailuresRemaining = 3

        let second = Task {
            try await lifecycle.start(request: "second", sessionID: UUID(), onAudioSampleBuffer: { _, _ in }, onStreamError: { _, _ in })
        }
        await driver.waitForStop()
        let third = Task {
            try await lifecycle.start(request: "third", sessionID: UUID(), onAudioSampleBuffer: { _, _ in }, onStreamError: { _, _ in })
        }
        await waitUntil { lifecycle.currentGeneration == 3 }

        driver.pauseStop = false
        driver.resumeStop()
        _ = try? await second.value
        _ = try? await third.value
        _ = try? await lifecycle.stopAndWait()
        _ = try? await lifecycle.stopAndWait()

        XCTAssertEqual(driver.stopCount, 4)
        XCTAssertFalse(driver.isActive)
    }

    func test_startFailureAfterPartialActivationStillStops() async throws {
        let driver = StatefulScreenStreamDriver()
        driver.failStartAfterActivation = true
        let lifecycle = ScreenCaptureLifecycle(driver: driver)

        do {
            _ = try await start(lifecycle, request: "first")
            XCTFail("start should fail")
        } catch {
            // Expected start failure after the driver became active.
        }
        XCTAssertEqual(driver.stopCount, 1)
        XCTAssertFalse(driver.isActive)
    }

    private func start(
        _ lifecycle: ScreenCaptureLifecycle<StatefulScreenStreamDriver>,
        request: String
    ) async throws {
        try await lifecycle.start(request: request, sessionID: UUID(), onAudioSampleBuffer: { _, _ in }, onStreamError: { _, _ in })
    }

    func test_stopBetweenStreamCreationAndStartStopsProducedStreamExactlyOnce() async throws {
        let driver = DeterministicScreenStreamDriver()
        driver.pauseStart = true
        let lifecycle = ScreenCaptureLifecycle(driver: driver)
        let start = Task {
            try await lifecycle.start(request: "first", sessionID: UUID(), onAudioSampleBuffer: { _, _ in }, onStreamError: { _, _ in })
        }

        await driver.waitForStart()
        lifecycle.requestStop()
        let stop = Task { try await lifecycle.stopAndWait() }
        driver.resumeStart()

        do {
            _ = try await start.value
            XCTFail("retired start unexpectedly succeeded")
        } catch is CancellationError {
            // Expected.
        }
        try await stop.value
        XCTAssertEqual(driver.createdCount, 1)
        XCTAssertEqual(driver.stopCount, 1)
        XCTAssertFalse(lifecycle.hasActiveStream)
    }

    func test_replacementWaitsForRetirementAndStaleStartCannotBecomeActive() async throws {
        let driver = DeterministicScreenStreamDriver()
        driver.pauseStart = true
        let lifecycle = ScreenCaptureLifecycle(driver: driver)
        let first = Task {
            try await lifecycle.start(request: "first", sessionID: UUID(), onAudioSampleBuffer: { _, _ in }, onStreamError: { _, _ in })
        }
        await driver.waitForStart()

        let replacement = Task {
            try await lifecycle.start(request: "second", sessionID: UUID(), onAudioSampleBuffer: { _, _ in }, onStreamError: { _, _ in })
        }
        await Task.yield()
        XCTAssertEqual(driver.createdCount, 1)
        driver.resumeStart()
        driver.pauseStart = false

        do {
            _ = try await first.value
            XCTFail("stale start unexpectedly succeeded")
        } catch is CancellationError {
            // Expected.
        }
        _ = try await replacement.value
        XCTAssertEqual(driver.createdCount, 2)
        XCTAssertEqual(driver.stopCount, 1)
        XCTAssertTrue(lifecycle.hasActiveStream)

        lifecycle.requestStop()
        try await lifecycle.stopAndWait()
        XCTAssertEqual(driver.stopCount, 2)
        XCTAssertFalse(lifecycle.hasActiveStream)
    }

    private func waitUntil(_ predicate: @escaping () -> Bool) async {
        for _ in 0..<1_000 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("condition did not become true")
    }
}

private final class DeterministicScreenStream: NSObject, @unchecked Sendable {}

private final class StatefulScreenStream: NSObject, @unchecked Sendable {}

private final class StatefulScreenStreamDriver: ScreenCaptureStreamDriver, @unchecked Sendable {
    typealias Stream = StatefulScreenStream
    typealias Request = String

    private let lock = NSLock()
    private var discoveryContinuation: CheckedContinuation<Void, Never>?
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private(set) var createdCount = 0
    private(set) var stopCount = 0
    private(set) var discoveryStarted = false
    private(set) var startStarted = false
    private(set) var stopStarted = false
    private(set) var isActive = false
    var pauseDiscovery = false
    var pauseStart = false
    var pauseStop = false
    var stopFailuresRemaining = 0
    var failStartAfterActivation = false

    func makeStream(
        for request: String,
        sessionID: UUID,
        onAudioSampleBuffer: @escaping @Sendable (UUID, CMSampleBuffer) -> Void,
        onStreamError: @escaping @Sendable (UUID, Error) -> Void
    ) async throws -> StatefulScreenStream {
        if pauseDiscovery {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    discoveryContinuation = continuation
                    discoveryStarted = true
                }
            }
        } else {
            lock.withLock { discoveryStarted = true }
        }
        lock.withLock { createdCount += 1 }
        return StatefulScreenStream()
    }

    func startCapture(_ stream: StatefulScreenStream) async throws {
        if pauseStart {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    startContinuation = continuation
                    startStarted = true
                }
            }
        } else {
            lock.withLock { startStarted = true }
        }
        lock.withLock { isActive = true }
        if failStartAfterActivation {
            throw TestDriverError.start
        }
    }

    func stopCapture(_ stream: StatefulScreenStream) async throws {
        if pauseStop {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    stopContinuation = continuation
                    stopStarted = true
                    stopCount += 1
                }
            }
        } else {
            lock.withLock {
                stopStarted = true
                stopCount += 1
            }
        }
        let shouldFail = lock.withLock { () -> Bool in
            guard stopFailuresRemaining > 0 else { return false }
            stopFailuresRemaining -= 1
            return true
        }
        if shouldFail { throw TestDriverError.stop }
        lock.withLock { isActive = false }
    }

    func waitForDiscovery() async { await waitUntil { [self] in lock.withLock { discoveryStarted } } }
    func waitForStart() async { await waitUntil { [self] in lock.withLock { startStarted } } }
    func waitForStop() async { await waitUntil { [self] in lock.withLock { stopStarted } } }

    func resumeDiscovery() {
        let continuation = lock.withLock { defer { discoveryContinuation = nil }; return discoveryContinuation }
        continuation?.resume()
    }

    func resumeStart() {
        let continuation = lock.withLock { defer { startContinuation = nil }; return startContinuation }
        continuation?.resume()
    }

    func resumeStop() {
        let continuation = lock.withLock { defer { stopContinuation = nil }; return stopContinuation }
        continuation?.resume()
    }

    private func waitUntil(_ predicate: @escaping () -> Bool) async {
        for _ in 0..<1_000 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("condition did not become true")
    }

    enum TestDriverError: Swift.Error { case start, stop }
}

private final class DeterministicScreenStreamDriver: ScreenCaptureStreamDriver, @unchecked Sendable {
    typealias Stream = DeterministicScreenStream
    typealias Request = String

    private let lock = NSLock()
    private var discoveryContinuation: CheckedContinuation<Void, Never>?
    private var startContinuation: CheckedContinuation<Void, Never>?
    private(set) var discoveryStarted = false
    private(set) var startStarted = false
    private(set) var createdCount = 0
    private(set) var stopCount = 0
    var pauseDiscovery = false
    var pauseStart = false

    func makeStream(
        for request: String,
        sessionID: UUID,
        onAudioSampleBuffer: @escaping @Sendable (UUID, CMSampleBuffer) -> Void,
        onStreamError: @escaping @Sendable (UUID, Error) -> Void
    ) async throws -> DeterministicScreenStream {
        lock.withLock { discoveryStarted = true }
        if pauseDiscovery {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.withLock { discoveryContinuation = continuation }
            }
        }
        lock.withLock { createdCount += 1 }
        return DeterministicScreenStream()
    }

    func startCapture(_ stream: DeterministicScreenStream) async throws {
        lock.withLock { startStarted = true }
        if pauseStart {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.withLock { startContinuation = continuation }
            }
        }
    }

    func stopCapture(_ stream: DeterministicScreenStream) async throws {
        lock.withLock { stopCount += 1 }
    }

    func waitForDiscovery() async {
        await waitUntil { [self] in self.lock.withLock { self.discoveryStarted } }
    }

    func waitForStart() async {
        await waitUntil { [self] in self.lock.withLock { self.startStarted } }
    }

    func resumeDiscovery() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { discoveryContinuation = nil }
            return discoveryContinuation
        }
        continuation?.resume()
    }

    func resumeStart() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { startContinuation = nil }
            return startContinuation
        }
        continuation?.resume()
    }

    private func waitUntil(_ predicate: @escaping () -> Bool) async {
        for _ in 0..<100 {
            if predicate() { return }
            await Task.yield()
        }
    }
}
