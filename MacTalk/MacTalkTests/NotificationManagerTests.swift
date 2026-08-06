import XCTest
import UserNotifications
@testable import MacTalk

@MainActor
final class NotificationManagerTests: XCTestCase {
    func test_initDoesNotRequestAuthorization() {
        let client = FakeUserNotificationClient(status: .notDetermined)
        _ = NotificationManager(client: client)

        XCTAssertEqual(client.authorizationRequestCount, 0)
    }

    func test_enablingNotificationsRequestsAuthorizationButDoesNotDeliverUntilGranted() {
        let client = FakeUserNotificationClient(status: .notDetermined)
        let manager = NotificationManager(client: client)

        manager.userChangedNotificationsPreference(to: true)

        XCTAssertEqual(client.authorizationRequestCount, 1)
        XCTAssertTrue(client.requests.isEmpty)
    }

    func test_grantedEnabledEventSubmitsRedactedRequest() {
        let client = FakeUserNotificationClient(status: .authorized)
        let manager = NotificationManager(client: client)

        manager.submit(.transcriptionComplete, enabled: true)

        XCTAssertEqual(client.requests.count, 1)
        XCTAssertEqual(client.requests[0].identifier, AppNotificationEvent.transcriptionComplete.identifier)
        XCTAssertEqual(client.requests[0].content.title, "Transcription Complete")
        XCTAssertEqual(client.requests[0].content.body, "Your transcription is ready in the clipboard.")
        XCTAssertFalse(client.requests[0].content.body.contains("secret transcript"))
    }

    func test_disabledEventDoesNotQueryOrSubmit() {
        let client = FakeUserNotificationClient(status: .authorized)
        let manager = NotificationManager(client: client)

        manager.submit(.appAudioLost, enabled: false)

        XCTAssertEqual(client.authorizationStatusReadCount, 0)
        XCTAssertTrue(client.requests.isEmpty)
    }

    func test_deniedAuthorizationDoesNotSubmitOrRequestAgain() {
        let client = FakeUserNotificationClient(status: .denied)
        let manager = NotificationManager(client: client)

        manager.userChangedNotificationsPreference(to: true)
        manager.submit(.fallbackToMicOnly, enabled: true)

        XCTAssertEqual(client.authorizationRequestCount, 0)
        XCTAssertTrue(client.requests.isEmpty)
    }

    func test_authorizationSettingsChangesAreObservedOnEachEnabledEvent() {
        let client = FakeUserNotificationClient(status: .authorized)
        let manager = NotificationManager(client: client)

        manager.submit(.appAudioLost, enabled: true)
        client.status = .denied
        manager.submit(.fallbackToMicOnly, enabled: true)

        XCTAssertEqual(client.requests.count, 1)
        XCTAssertEqual(client.requests[0].identifier, AppNotificationEvent.appAudioLost.identifier)
    }

    func test_duplicateEventsUseStableIdentifierAndReplacePendingRequest() {
        let client = FakeUserNotificationClient(status: .authorized)
        let manager = NotificationManager(client: client)

        manager.submit(.appAudioLost, enabled: true)
        manager.submit(.appAudioLost, enabled: true)

        XCTAssertEqual(client.requests.map(\.identifier), [
            AppNotificationEvent.appAudioLost.identifier,
            AppNotificationEvent.appAudioLost.identifier
        ])
        XCTAssertEqual(NotificationManager.duplicatePolicy, .replacePending)
    }

    func test_allEventsHaveStableIdentifiersAndNonTranscriptContent() {
        let expected: [(AppNotificationEvent, String, String)] = [
            (.transcriptionComplete, "Transcription Complete", "Your transcription is ready in the clipboard."),
            (.appAudioLost, "App Audio Lost", "App audio was lost. Recording continues with microphone only."),
            (.fallbackToMicOnly, "Switched to Mic-Only Mode", "App audio could not be restored. Continuing with microphone only.")
        ]
        let client = FakeUserNotificationClient(status: .authorized)
        let manager = NotificationManager(client: client)

        for (event, title, body) in expected {
            manager.submit(event, enabled: true)
            XCTAssertEqual(client.requests.last?.identifier, event.identifier)
            XCTAssertEqual(client.requests.last?.content.title, title)
            XCTAssertEqual(client.requests.last?.content.body, body)
            if event == .appAudioLost {
                XCTAssertFalse(client.requests.last?.content.body.contains("Retrying") ?? false)
            }
        }
    }
}

@MainActor
private final class FakeUserNotificationClient: UserNotificationClient {
    var status: AppNotificationAuthorizationStatus
    private(set) var authorizationStatusReadCount = 0
    private(set) var authorizationRequestCount = 0
    private(set) var requests: [UNNotificationRequest] = []

    init(status: AppNotificationAuthorizationStatus) {
        self.status = status
    }

    func getAuthorizationStatus(_ completion: @escaping (AppNotificationAuthorizationStatus) -> Void) {
        authorizationStatusReadCount += 1
        completion(status)
    }

    func requestAuthorization(_ completion: @escaping (Bool) -> Void) {
        authorizationRequestCount += 1
        completion(status == .authorized)
    }

    func add(_ request: UNNotificationRequest, completion: @escaping (Error?) -> Void) {
        requests.append(request)
        completion(nil)
    }
}
