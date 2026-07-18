import XCTest
@testable import MacTalk

@MainActor
final class PermissionFlowCoordinatorTests: XCTestCase {
    func test_microphonePermissionMatrix() async {
        for state in [MicrophonePermissionState.granted, .notDetermined, .denied, .restricted, .unknown] {
            let client = PermissionFake(microphone: state)
            let coordinator = PermissionFlowCoordinator(client: client)
            let result = await coordinator.authorizeStart(mode: .micOnly)
            switch state {
            case .granted:
                XCTAssertEqual(result, .granted)
            case .notDetermined:
                XCTAssertEqual(result, .granted)
                XCTAssertEqual(client.microphoneRequests, 1)
            case .denied, .restricted, .unknown:
                XCTAssertEqual(result, .deniedMicrophone)
                XCTAssertEqual(client.openedMicrophoneSettings, 1)
            }
        }
    }

    func test_screenPermissionIsRequiredOnlyForMicAndApp() async {
        let client = PermissionFake(microphone: .granted, screenGranted: false)
        let coordinator = PermissionFlowCoordinator(client: client)
        let micOnlyResult = await coordinator.authorizeStart(mode: .micOnly)
        let micAndAppResult = await coordinator.authorizeStart(mode: .micPlusAppAudio)
        XCTAssertEqual(micOnlyResult, .granted)
        XCTAssertEqual(micAndAppResult, .deniedScreenRecording)
        XCTAssertEqual(client.openedScreenSettings, 1)
    }

    func test_effectiveAutoPasteRequiresAccessibility() {
        let client = PermissionFake(accessibility: false)
        let coordinator = PermissionFlowCoordinator(client: client, storedAutoPaste: true)
        XCTAssertFalse(coordinator.effectiveAutoPaste)
        client.accessibility = true
        XCTAssertTrue(coordinator.refresh(storedAutoPaste: true).effectiveAutoPaste)
    }

    func test_insertDenialUsesThirtySixtyAndThreeHundredSecondBackoff() {
        var now = Date(timeIntervalSince1970: 1_000)
        let client = PermissionFake(accessibility: false)
        let coordinator = PermissionFlowCoordinator(client: client, clock: { now })
        XCTAssertEqual(coordinator.permissionDeniedByInsert(at: now), .requestPrompt)
        XCTAssertEqual(coordinator.permissionDeniedByInsert(at: now.addingTimeInterval(29)), .throttled)
        XCTAssertEqual(coordinator.permissionDeniedByInsert(at: now.addingTimeInterval(30)), .requestPrompt)
        XCTAssertEqual(coordinator.permissionDeniedByInsert(at: now.addingTimeInterval(89)), .throttled)
        XCTAssertEqual(coordinator.permissionDeniedByInsert(at: now.addingTimeInterval(90)), .requestPrompt)
        XCTAssertEqual(coordinator.permissionDeniedByInsert(at: now.addingTimeInterval(209)), .throttled)
        XCTAssertEqual(coordinator.permissionDeniedByInsert(at: now.addingTimeInterval(210)), .requestPrompt)
        now = now.addingTimeInterval(600)
        XCTAssertEqual(coordinator.permissionDeniedByInsert(at: now), .requestPrompt)
        coordinator.recordSuccessfulInsert()
        XCTAssertEqual(coordinator.permissionDeniedByInsert(at: now), .requestPrompt)
    }
}

@MainActor
private final class PermissionFake: PermissionClient {
    var microphoneState: MicrophonePermissionState
    var screenRecordingGranted: Bool
    var accessibility: Bool
    var microphoneRequests = 0
    var openedMicrophoneSettings = 0
    var openedScreenSettings = 0

    init(
        microphone: MicrophonePermissionState = .granted,
        screenGranted: Bool = true,
        accessibility: Bool = true
    ) {
        self.microphoneState = microphone
        self.screenRecordingGranted = screenGranted
        self.accessibility = accessibility
    }

    var accessibilityTrusted: Bool { accessibility }
    var accessibilityDiagnostics: PermissionDiagnostics {
        PermissionDiagnostics(
            bundleIdentifier: "test",
            teamIdentifier: "test",
            isAdHocSigned: false,
            isRunningFromXcode: false,
            executablePath: "test",
            isAccessibilityTrusted: accessibility
        )
    }

    func requestMicrophone() async -> Bool {
        microphoneRequests += 1
        microphoneState = .granted
        return true
    }

    func requestAccessibilitySystemPrompt() async -> Bool { false }
    func resetAccessibilityApproval(reason: String) -> Bool { true }
    func openMicrophoneSettings() { openedMicrophoneSettings += 1 }
    func openScreenRecordingSettings() { openedScreenSettings += 1 }
    func openAccessibilitySettings() {}
}
