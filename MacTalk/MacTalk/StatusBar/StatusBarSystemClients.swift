import AppKit
import AVFoundation
import Foundation

@MainActor
protocol PermissionClient: AnyObject {
    var microphoneState: MicrophonePermissionState { get }
    var screenRecordingGranted: Bool { get }
    var accessibilityTrusted: Bool { get }
    var accessibilityDiagnostics: PermissionDiagnostics { get }

    func requestMicrophone() async -> Bool
    func requestAccessibilitySystemPrompt() async -> Bool
    func resetAccessibilityApproval(reason: String) -> Bool
    func openMicrophoneSettings()
    func openScreenRecordingSettings()
    func openAccessibilitySettings()
}

@MainActor
protocol ClipboardWriting: AnyObject {
    @discardableResult
    func write(_ text: String) -> Bool
}

@MainActor
protocol TextInserting: AnyObject {
    func insert(_ text: String) -> AutoInsertResult
}

@MainActor
protocol WorkspaceReading: AnyObject {
    var frontmostApplication: ApplicationIdentity? { get }
    var activeApplications: [ApplicationIdentity] { get }
}

@MainActor
protocol NotificationSubmitting: AnyObject {
    func submit(_ event: AppNotificationEvent, enabled: Bool)
}

@MainActor
final class SystemPermissionClient: PermissionClient {
    var microphoneState: MicrophonePermissionState { Permissions.microphonePermissionState() }
    var screenRecordingGranted: Bool { Permissions.checkScreenRecordingPermission() }
    var accessibilityTrusted: Bool { Permissions.isAccessibilityTrusted() }
    var accessibilityDiagnostics: PermissionDiagnostics { Permissions.getAccessibilityDiagnostics() }

    func requestMicrophone() async -> Bool {
        await withCheckedContinuation { continuation in
            Permissions.ensureMic { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    func requestAccessibilitySystemPrompt() async -> Bool {
        await withCheckedContinuation { continuation in
            Permissions.requestAccessibilityPermission {
                continuation.resume(returning: true)
            }
        }
    }

    func resetAccessibilityApproval(reason: String) -> Bool {
        Permissions.resetAccessibilityApproval(reason: reason)
    }

    func openMicrophoneSettings() { Permissions.openMicrophoneSettings() }
    func openScreenRecordingSettings() { Permissions.openScreenRecordingSettings() }
    func openAccessibilitySettings() { Permissions.openAccessibilitySettings() }
}

@MainActor
final class SystemClipboardWriter: ClipboardWriting {
    func write(_ text: String) -> Bool {
        ClipboardManager.setClipboard(text)
        return true
    }
}

@MainActor
final class SystemTextInserter: TextInserting {
    func insert(_ text: String) -> AutoInsertResult {
        AutoInsertManager.insertText(text)
    }
}

@MainActor
final class SystemWorkspaceReader: WorkspaceReading {
    private let workspace: NSWorkspace
    private let processIdentifier: pid_t

    init(workspace: NSWorkspace = .shared, processIdentifier: pid_t = ProcessInfo.processInfo.processIdentifier) {
        self.workspace = workspace
        self.processIdentifier = processIdentifier
    }

    var frontmostApplication: ApplicationIdentity? {
        workspace.frontmostApplication.map(ApplicationIdentity.init)
    }

    var activeApplications: [ApplicationIdentity] {
        workspace.runningApplications
            .filter { $0.isActive && $0.processIdentifier != processIdentifier }
            .map(ApplicationIdentity.init)
    }
}

@MainActor
final class SystemNotificationSubmitter: NotificationSubmitting {
    private let manager: NotificationManager

    init(manager: NotificationManager) {
        self.manager = manager
    }

    func submit(_ event: AppNotificationEvent, enabled: Bool) {
        manager.submit(event, enabled: enabled)
    }
}

@MainActor
struct StatusBarDependencies {
    let permissionClient: any PermissionClient
    let clipboardWriter: any ClipboardWriting
    let textInserter: any TextInserting
    let workspaceReader: any WorkspaceReading
    let notificationSubmitter: any NotificationSubmitting
    let clock: @MainActor () -> Date

    static func live(notificationManager: NotificationManager) -> StatusBarDependencies {
        StatusBarDependencies(
            permissionClient: SystemPermissionClient(),
            clipboardWriter: SystemClipboardWriter(),
            textInserter: SystemTextInserter(),
            workspaceReader: SystemWorkspaceReader(),
            notificationSubmitter: SystemNotificationSubmitter(manager: notificationManager),
            clock: { Date() }
        )
    }
}
