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
