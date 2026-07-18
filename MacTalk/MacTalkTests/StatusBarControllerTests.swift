import XCTest
@testable import MacTalk

@MainActor
final class StatusBarControllerTests: XCTestCase {
    func test_statusBarIntentsAreStableTypedValues() {
        XCTAssertEqual(StatusBarIntent.startMicOnly, .startMicOnly)
        XCTAssertNotEqual(StatusBarIntent.startMicOnly, .startMicPlusAppAudio)
        XCTAssertEqual(StatusBarIntent.stop, .stop)
        XCTAssertNotEqual(StatusBarIntent.startMicOnly, .toggleMicOnly)
        XCTAssertNotEqual(StatusBarIntent.startMicPlusAppAudio, .toggleMicPlusAppAudio)
    }

    func test_applicationIdentityDoesNotRetainWorkspaceObjects() {
        let identity = ApplicationIdentity(processIdentifier: 42, bundleIdentifier: "com.example.Editor", displayName: "Editor")
        XCTAssertEqual(identity.processIdentifier, 42)
        XCTAssertEqual(identity.bundleIdentifier, "com.example.Editor")
        XCTAssertEqual(identity.displayName, "Editor")
    }

    func test_viewStateCapturesEffectiveAutoPasteSeparatelyFromStoredPreference() {
        let state = StatusBarViewState(
            recordingPhase: .idle,
            startEnabled: true,
            stopEnabled: false,
            recordingIcon: false,
            provider: .whisper,
            whisperModelID: "model",
            effectiveAutoPaste: false
        )
        XCTAssertTrue(state.startEnabled)
        XCTAssertFalse(state.effectiveAutoPaste)
    }
}
