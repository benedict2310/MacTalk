import AppKit
import Foundation

/// Owns transcript side effects and the safety policy around the application that
/// was active when recording began. All external effects are injected.
@MainActor
final class OutputCoordinator: OutputCoordinating {
    private let clipboardWriter: any ClipboardWriting
    private let textInserter: any TextInserting
    private let workspaceReader: any WorkspaceReading
    private let notifications: any NotificationSubmitting
    private let permissionFlow: any PermissionFlowCoordinating
    private let processIdentifier: pid_t
    private let now: @MainActor () -> Date
    private var target: ApplicationIdentity?

    init(
        clipboardWriter: any ClipboardWriting,
        textInserter: any TextInserting,
        workspaceReader: any WorkspaceReading,
        notifications: any NotificationSubmitting,
        permissionFlow: any PermissionFlowCoordinating,
        processIdentifier: pid_t = ProcessInfo.processInfo.processIdentifier,
        clock: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.clipboardWriter = clipboardWriter
        self.textInserter = textInserter
        self.workspaceReader = workspaceReader
        self.notifications = notifications
        self.permissionFlow = permissionFlow
        self.processIdentifier = processIdentifier
        self.now = clock
    }

    func captureTarget() -> ApplicationIdentity? {
        let frontmost = workspaceReader.frontmostApplication
        if frontmost?.processIdentifier == processIdentifier {
            target = workspaceReader.activeApplications.first ?? frontmost
        } else {
            target = frontmost
        }
        return target
    }

    var currentTarget: ApplicationIdentity? { target }

    func setTarget(_ target: ApplicationIdentity?) {
        self.target = target
    }

    func clearTarget() {
        target = nil
    }

    func handleFinal(text: String, context: OutputContext) -> OutputResult {
        // Clipboard write is intentionally the first side effect and is attempted
        // exactly once, even when insertion is disabled or unsafe.
        let clipboardWritten = clipboardWriter.write(text)
        var outcome: AutoInsertOutcome = .notAttempted
        var permissionEffect: PermissionEffect?
        var message = "Text copied to clipboard"

        if context.autoPastePreference, permissionFlow.effectiveAutoPaste {
            if targetStillFrontmost() {
                switch textInserter.insert(text) {
                case .axSetValueSuccess:
                    outcome = .axSetValueSuccess
                    message = "Text pasted"
                    permissionFlow.recordSuccessfulInsert()
                case .cmdVFallback:
                    outcome = .cmdVFallback
                    message = "Text pasted"
                    permissionFlow.recordSuccessfulInsert()
                case .permissionDenied:
                    outcome = .permissionDenied
                    if permissionFlow.permissionDeniedByInsert(at: now()) == .requestPrompt {
                        permissionEffect = .requestAccessibility
                    }
                case .failed:
                    outcome = .failed
                    permissionFlow.recordSuccessfulInsert()
                }
            } else {
                outcome = .skippedTargetChanged
            }
        }

        target = nil
        notifications.submit(.transcriptionComplete, enabled: context.showNotifications)
        return OutputResult(
            clipboardWritten: clipboardWritten,
            insertOutcome: outcome,
            userMessage: message,
            permissionEffect: permissionEffect
        )
    }

    func cancel() {
        target = nil
    }

    func handleAppAudioLost(showNotification: Bool) {
        notifications.submit(.appAudioLost, enabled: showNotification)
    }

    func handleFallbackToMicOnly(showNotification: Bool) {
        notifications.submit(.fallbackToMicOnly, enabled: showNotification)
    }

    private func targetStillFrontmost() -> Bool {
        // The coordinator owns the one session snapshot. OutputContext carries
        // presentation settings only; callers cannot overwrite this target at
        // finalization time.
        let capturedTarget = target
        guard let capturedTarget else { return true }
        guard let frontmost = workspaceReader.frontmostApplication else { return true }
        if frontmost.processIdentifier == processIdentifier { return true }
        return capturedTarget.processIdentifier == frontmost.processIdentifier
    }
}

@MainActor
protocol OutputCoordinating: AnyObject {
    func captureTarget() -> ApplicationIdentity?
    func setTarget(_ target: ApplicationIdentity?)
    func clearTarget()
    func handleFinal(text: String, context: OutputContext) -> OutputResult
    func cancel()
    func handleAppAudioLost(showNotification: Bool)
    func handleFallbackToMicOnly(showNotification: Bool)
}
