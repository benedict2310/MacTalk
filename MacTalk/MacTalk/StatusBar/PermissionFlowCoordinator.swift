import Foundation

/// Owns permission state and user-prompt policy. The coordinator never presents
/// AppKit alerts and is consequently safe to exercise with a fake client.
@MainActor
final class PermissionFlowCoordinator: PermissionFlowCoordinating {
    private let client: any PermissionClient
    private let now: @MainActor () -> Date
    private let backoff: [TimeInterval]
    private var storedAutoPaste: Bool
    private var lastPermissionPromptTime: Date?
    private var permissionPromptBackoffStep = 0
    private var hasRequestedAccessibilityPromptThisSession = false

    init(
        client: any PermissionClient,
        storedAutoPaste: Bool = false,
        clock: @escaping @MainActor () -> Date = { Date() },
        backoff: [TimeInterval] = [30, 60, 120, 300]
    ) {
        self.client = client
        self.storedAutoPaste = storedAutoPaste
        self.now = clock
        self.backoff = backoff
    }

    var effectiveAutoPaste: Bool {
        AutoPastePermissionPolicy.effectiveAutoPaste(
            storedPreference: storedAutoPaste,
            accessibilityTrusted: client.accessibilityTrusted
        )
    }

    func refresh(storedAutoPaste: Bool) -> PermissionViewState {
        self.storedAutoPaste = storedAutoPaste
        return PermissionViewState(
            microphone: client.microphoneState,
            screenRecordingGranted: client.screenRecordingGranted,
            accessibilityTrusted: client.accessibilityTrusted,
            effectiveAutoPaste: effectiveAutoPaste
        )
    }

    func requestEnableAutoPaste() async -> AutoPasteEnableResult {
        storedAutoPaste = true
        if client.accessibilityTrusted {
            return .enabled
        }

        if AutoPastePermissionPolicy.shouldResetStaleAccessibilityApproval(
            accessibilityTrusted: client.accessibilityTrusted,
            diagnostics: client.accessibilityDiagnostics
        ) {
            _ = client.resetAccessibilityApproval(reason: "stale local Accessibility approval")
        }

        if hasRequestedAccessibilityPromptThisSession {
            client.openAccessibilitySettings()
            return .settingsRequired
        }

        hasRequestedAccessibilityPromptThisSession = true
        _ = await client.requestAccessibilitySystemPrompt()
        return client.accessibilityTrusted ? .enabled : .promptRequested
    }

    func permissionDeniedByInsert(at date: Date) -> AccessibilityPromptDecision {
        guard !client.accessibilityTrusted else { return .requestPrompt }

        if let lastPermissionPromptTime {
            let elapsed = date.timeIntervalSince(lastPermissionPromptTime)
            if elapsed < currentPermissionPromptCooldown {
                return .throttled
            }
        }

        lastPermissionPromptTime = date
        permissionPromptBackoffStep = min(permissionPromptBackoffStep + 1, backoff.count)
        return .requestPrompt
    }

    func recordSuccessfulInsert() {
        lastPermissionPromptTime = nil
        permissionPromptBackoffStep = 0
    }

    func statusReport() -> PermissionStatusReport {
        PermissionStatusReport(
            microphoneGranted: client.microphoneState == .granted,
            screenRecordingGranted: client.screenRecordingGranted,
            accessibilityTrusted: client.accessibilityTrusted,
            effectiveAutoPaste: effectiveAutoPaste
        )
    }

    func authorizeStart(mode: TranscriptionController.Mode) async -> StartPermissionResult {
        switch PermissionFlowGate.microphoneAction(for: client.microphoneState) {
        case .proceed:
            break
        case .requestPermission:
            guard await client.requestMicrophone() else { return .deniedMicrophone }
        case .openSettings:
            client.openMicrophoneSettings()
            return .deniedMicrophone
        }

        if mode == .micPlusAppAudio, !client.screenRecordingGranted {
            client.openScreenRecordingSettings()
            return .deniedScreenRecording
        }
        return .granted
    }

    private var currentPermissionPromptCooldown: TimeInterval {
        guard !backoff.isEmpty else { return .infinity }
        let index = max(permissionPromptBackoffStep - 1, 0)
        return backoff[min(index, backoff.count - 1)]
    }
}

@MainActor
protocol PermissionFlowCoordinating: AnyObject {
    var effectiveAutoPaste: Bool { get }
    func refresh(storedAutoPaste: Bool) -> PermissionViewState
    func requestEnableAutoPaste() async -> AutoPasteEnableResult
    func permissionDeniedByInsert(at now: Date) -> AccessibilityPromptDecision
    func recordSuccessfulInsert()
    func statusReport() -> PermissionStatusReport
}

@MainActor
protocol RecordingPermissionAuthorizing: AnyObject {
    func authorizeStart(mode: TranscriptionController.Mode) async -> StartPermissionResult
}
