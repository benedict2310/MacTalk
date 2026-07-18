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
    typealias AccessibilityPromptRequester = @MainActor (
        @escaping @MainActor @Sendable (Bool) -> Void
    ) -> Void

    private let accessibilityTimeout: TimeInterval
    private let accessibilityPromptRequester: AccessibilityPromptRequester

    init(
        accessibilityTimeout: TimeInterval = 60,
        accessibilityPromptRequester: @escaping AccessibilityPromptRequester = { completion in
            Permissions.requestAccessibilityPermission(completion: completion)
        }
    ) {
        self.accessibilityTimeout = accessibilityTimeout
        self.accessibilityPromptRequester = accessibilityPromptRequester
    }

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
        let pending = AccessibilityPromptCompletion()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                pending.start(
                    continuation: continuation,
                    timeout: accessibilityTimeout,
                    requester: accessibilityPromptRequester
                )
            }
        }, onCancel: {
            Task { @MainActor in pending.finish(false) }
        })
    }

    func resetAccessibilityApproval(reason: String) -> Bool {
        Permissions.resetAccessibilityApproval(reason: reason)
    }

    func openMicrophoneSettings() { Permissions.openMicrophoneSettings() }
    func openScreenRecordingSettings() { Permissions.openScreenRecordingSettings() }
    func openAccessibilitySettings() { Permissions.openAccessibilitySettings() }
}

/// Owns one checked continuation and its timeout. Completion is idempotent so
/// grant/denial callbacks racing a timeout cannot resume twice.
@MainActor
private final class AccessibilityPromptCompletion {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var timeoutTask: Task<Void, Never>?

    func start(
        continuation: CheckedContinuation<Bool, Never>,
        timeout: TimeInterval,
        requester: SystemPermissionClient.AccessibilityPromptRequester
    ) {
        self.continuation = continuation
        timeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(max(timeout, 0) * 1_000_000_000))
            } catch {
                return
            }
            self?.finish(false)
        }
        requester { [weak self] granted in
            self?.finish(granted)
        }
    }

    func finish(_ granted: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        continuation.resume(returning: granted)
    }
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
    private let insertClipboardText: @MainActor (String) -> AutoInsertResult

    init(insertClipboardText: @escaping @MainActor (String) -> AutoInsertResult = { text in
        AutoInsertManager.insertClipboardText(text)
    }) {
        self.insertClipboardText = insertClipboardText
    }

    func insert(_ text: String) -> AutoInsertResult {
        insertClipboardText(text)
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
