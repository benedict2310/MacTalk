//
//  NotificationManager.swift
//  MacTalk
//
//  Testable, preference-gated wrapper around UserNotifications.
//

import Foundation
import UserNotifications

@MainActor
enum AppNotificationAuthorizationStatus: Equatable {
    case notDetermined
    case denied
    case authorized
    case provisional
    case ephemeral
}

@MainActor
protocol UserNotificationClient: AnyObject {
    func getAuthorizationStatus(_ completion: @escaping (AppNotificationAuthorizationStatus) -> Void)
    func requestAuthorization(_ completion: @escaping (Bool) -> Void)
    func add(_ request: UNNotificationRequest, completion: @escaping (Error?) -> Void)
}

@MainActor
final class SystemUserNotificationClient: UserNotificationClient {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func getAuthorizationStatus(_ completion: @escaping (AppNotificationAuthorizationStatus) -> Void) {
        center.getNotificationSettings { settings in
            let status: AppNotificationAuthorizationStatus
            switch settings.authorizationStatus {
            case .notDetermined:
                status = .notDetermined
            case .denied:
                status = .denied
            case .authorized:
                status = .authorized
            case .provisional:
                status = .provisional
            case .ephemeral:
                status = .ephemeral
            @unknown default:
                status = .denied
            }
            Task { @MainActor in
                completion(status)
            }
        }
    }

    func requestAuthorization(_ completion: @escaping (Bool) -> Void) {
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in
                completion(granted)
            }
        }
    }

    func add(_ request: UNNotificationRequest, completion: @escaping (Error?) -> Void) {
        center.add(request) { error in
            Task { @MainActor in
                completion(error)
            }
        }
    }
}

enum AppNotificationEvent: CaseIterable, Equatable {
    case transcriptionComplete
    case appAudioLost
    case fallbackToMicOnly

    var identifier: String {
        switch self {
        case .transcriptionComplete:
            return "com.mactalk.notification.transcription-complete"
        case .appAudioLost:
            return "com.mactalk.notification.app-audio-lost"
        case .fallbackToMicOnly:
            return "com.mactalk.notification.fallback-to-mic-only"
        }
    }

    var title: String {
        switch self {
        case .transcriptionComplete:
            return "Transcription Complete"
        case .appAudioLost:
            return "App Audio Lost"
        case .fallbackToMicOnly:
            return "Switched to Mic-Only Mode"
        }
    }

    /// Notification text intentionally contains no transcript or other user content.
    var body: String {
        switch self {
        case .transcriptionComplete:
            return "Your transcription is ready in the clipboard."
        case .appAudioLost:
            return "The selected app's audio stream was interrupted. Retrying."
        case .fallbackToMicOnly:
            return "App audio could not be restored. Continuing with microphone only."
        }
    }

    var request: UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        return UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
    }
}

enum NotificationDuplicatePolicy: Equatable {
    /// UserNotifications replaces a pending request with the same identifier.
    case replacePending
}

@MainActor
final class NotificationManager {
    static let shared = NotificationManager(client: SystemUserNotificationClient())
    static let duplicatePolicy: NotificationDuplicatePolicy = .replacePending

    private let client: UserNotificationClient

    init(client: UserNotificationClient) {
        self.client = client
    }

    /// Called by the Show Notifications toggle, which is an explicit user action.
    /// App launch and notification delivery never request authorization.
    func userChangedNotificationsPreference(to enabled: Bool) {
        guard enabled else { return }
        client.getAuthorizationStatus { [weak self] status in
            guard let self, status == .notDetermined else { return }
            self.client.requestAuthorization { _ in }
        }
    }

    /// Submits only when the typed preference is enabled and the current system
    /// authorization still permits alerts. A settings change is intentionally
    /// re-read for every event so revocation takes effect without relaunching.
    func submit(_ event: AppNotificationEvent, enabled: Bool) {
        guard enabled else { return }
        client.getAuthorizationStatus { [weak self] status in
            guard let self,
                  status == .authorized || status == .provisional || status == .ephemeral
            else { return }
            self.client.add(event.request) { _ in }
        }
    }
}
