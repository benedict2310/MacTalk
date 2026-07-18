import XCTest
@preconcurrency import AVFoundation
@testable import MacTalk

final class DeterministicHarnessTests: XCTestCase {
    func test_scriptedASRProcessCancellationIsRecorded() async throws {
        let engine = DeterministicASREngine(script: DeterministicASRScript(processDelayNanoseconds: 5_000_000_000))
        let task = Task {
            try await engine.process(
                makeConstantPCMBuffer(sampleRate: 16_000, channels: 1, frameCount: 16),
                language: "en"
            )
        }
        try await Task.sleep(nanoseconds: 5_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected and asserted by the recorded cancellation event below.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        XCTAssertEqual(engine.cancellationCount, 1)
    }

    func test_audioFixturesAreStableAndIsolatedFakesFailClosed() throws {
        XCTAssertEqual(DeterministicAudioFixtures.silence(count: 3), [0, 0, 0])
        XCTAssertEqual(DeterministicAudioFixtures.impulse(count: 3), [1, 0, 0])
        XCTAssertEqual(DeterministicAudioFixtures.tone(count: 0), [])

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let downloader = DeterministicModelDownloader()
        XCTAssertThrowsError(try downloader.download(filename: "never-download.bin"))
        XCTAssertEqual(downloader.requestedModels, ["never-download.bin"])
        let trap = DeterministicNetworkTrap()
        trap.assertNoRequests()
    }
}
