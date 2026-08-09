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
        let stop = Task { await lifecycle.stopAndWait() }
        driver.resumeDiscovery()

        do {
            _ = try await start.value
            XCTFail("retired start unexpectedly succeeded")
        } catch is CancellationError {
            // Expected: retirement is represented as typed cancellation.
        }
        await stop.value
        XCTAssertEqual(driver.createdCount, 1)
        XCTAssertEqual(driver.stopCount, 1)
        XCTAssertFalse(lifecycle.hasActiveStream)
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
        let stop = Task { await lifecycle.stopAndWait() }
        driver.resumeStart()

        do {
            _ = try await start.value
            XCTFail("retired start unexpectedly succeeded")
        } catch is CancellationError {
            // Expected.
        }
        await stop.value
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
        await lifecycle.stopAndWait()
        XCTAssertEqual(driver.stopCount, 2)
        XCTAssertFalse(lifecycle.hasActiveStream)
    }

    private func waitUntil(_ predicate: @escaping () -> Bool) async {
        for _ in 0..<100 {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("condition did not become true")
    }
}

private final class DeterministicScreenStream: NSObject, @unchecked Sendable {}

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
