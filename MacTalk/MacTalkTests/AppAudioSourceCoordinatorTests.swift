import XCTest
@testable import MacTalk

@MainActor
final class AppAudioSourceCoordinatorTests: XCTestCase {
    func test_filtersWindowlessAppsSortsSystemFirstAndDeduplicates() async throws {
        let sources = [
            candidate("zeta", "Zeta", ownsWindow: true),
            candidate("windowless", "Windowless", ownsWindow: false),
            candidate("alpha", "Alpha", ownsWindow: true),
            candidate("alpha", "Alpha duplicate", ownsWindow: true),
            candidate("system", "System Audio", ownsWindow: true, system: true)
        ]
        let coordinator = AppAudioSourceCoordinator(client: ShareableClientFake(.success(ShareableContentSnapshot(sources: sources))))

        let result = try await coordinator.loadSources()

        XCTAssertEqual(result.map(\.name), ["System Audio", "Alpha", "Zeta"])
    }

    func test_timeoutMapsToScreenCaptureTimeout() async {
        let coordinator = AppAudioSourceCoordinator(client: ShareableClientFake(.failure(TimeoutError(seconds: 5))))

        do {
            _ = try await coordinator.loadSources()
            XCTFail("Expected timeout")
        } catch let error as ScreenCaptureError {
            XCTAssertEqual(error, .timeout)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_noAllowedSourcesMapsToNoSourcesError() async {
        let candidate = candidate("hidden", "Hidden", ownsWindow: false)
        let coordinator = AppAudioSourceCoordinator(client: ShareableClientFake(.success(ShareableContentSnapshot(sources: [candidate]))))

        do {
            _ = try await coordinator.loadSources()
            XCTFail("Expected no sources")
        } catch let error as ScreenCaptureError {
            XCTAssertEqual(error, .noSourcesAvailable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_timeoutReturnsBeforeCancellationIgnoringOperationCompletes() async throws {
        let operation = CancellationIgnoringOperation()
        let recorder = TimeoutCompletionRecorder()
        let clock = ContinuousClock()
        let startedAt = clock.now
        let timeoutTask = Task { () -> Bool in
            do {
                _ = try await withTimeout(seconds: 0.025) {
                    await operation.run()
                }
                return false
            } catch is TimeoutError {
                await recorder.record(clock.now)
                return true
            } catch {
                return false
            }
        }

        await operation.waitUntilStarted()
        try await Task.sleep(nanoseconds: 100_000_000)

        let completedAt = await recorder.value
        XCTAssertNotNil(completedAt)
        if let completedAt {
            XCTAssertLessThan(startedAt.duration(to: completedAt), .milliseconds(90))
        }

        // The underlying operation explicitly ignores cancellation. Resuming
        // it after the timeout verifies that its late completion is harmless.
        await operation.release()
        let timedOut = await timeoutTask.value
        XCTAssertTrue(timedOut)
    }

    private func candidate(
        _ identity: String,
        _ name: String,
        ownsWindow: Bool,
        system: Bool = false
    ) -> ShareableContentSource {
        ShareableContentSource(
            identity: identity,
            source: AppPickerWindowController.AudioSource(app: nil, display: nil, name: name, icon: nil),
            ownsWindow: ownsWindow,
            isSystemAudio: system
        )
    }
}

@MainActor
private final class ShareableClientFake: ShareableContentClient {
    let result: Result<ShareableContentSnapshot, Error>

    init(_ result: Result<ShareableContentSnapshot, Error>) { self.result = result }

    func loadShareableContent(timeout: TimeInterval) async throws -> ShareableContentSnapshot {
        try result.get()
    }
}

private actor CancellationIgnoringOperation {
    private var started = false
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var completion: CheckedContinuation<Void, Never>?

    func run() async {
        if !started {
            started = true
            startedContinuation?.resume()
            startedContinuation = nil
        }
        // Checked continuations do not automatically throw on task
        // cancellation, so this operation remains blocked after cancellation.
        await withCheckedContinuation { continuation in
            completion = continuation
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startedContinuation = continuation
        }
    }

    func release() {
        completion?.resume()
        completion = nil
    }
}

private actor TimeoutCompletionRecorder {
    private(set) var value: ContinuousClock.Instant?

    func record(_ timestamp: ContinuousClock.Instant) {
        value = timestamp
    }
}
