import AppKit
import Foundation

/// Stable identity captured at the output boundary. AppKit objects never escape the
/// workspace adapter into status-bar business logic.
struct ApplicationIdentity: Equatable, Sendable {
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    let displayName: String

    init(processIdentifier: pid_t, bundleIdentifier: String? = nil, displayName: String = "unknown") {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
    }

    init(_ application: NSRunningApplication) {
        self.init(
            processIdentifier: application.processIdentifier,
            bundleIdentifier: application.bundleIdentifier,
            displayName: application.localizedName ?? application.bundleIdentifier ?? "unknown"
        )
    }
}

enum StatusBarIntent: Equatable, Sendable {
    case startMicOnly
    case startMicPlusAppAudio
    case stop
    case toggleAutoPaste
    case showSettings
    case showAbout
    case quit
}

enum PermissionEffect: Equatable, Sendable {
    case requestAccessibility
    case openAccessibilitySettings
    case resetStaleAccessibilityApproval
}

enum StatusBarEffect: Equatable, Sendable {
    case permission(PermissionEffect)
    case showMicrophoneGuidance
    case showScreenRecordingGuidance
}

enum AutoInsertOutcome: Equatable, Sendable {
    case notAttempted
    case axSetValueSuccess
    case cmdVFallback
    case permissionDenied
    case failed
    case skippedTargetChanged
}

struct OutputContext: Equatable, Sendable {
    let target: ApplicationIdentity?
    let autoPastePreference: Bool
    let showNotifications: Bool
}

struct OutputResult: Equatable, Sendable {
    let clipboardWritten: Bool
    let insertOutcome: AutoInsertOutcome
    let userMessage: String
    let permissionEffect: PermissionEffect?
}

enum ModelRequirement: Equatable, Sendable {
    case whisper(ModelSpec)
    case parakeet(modelID: String, revision: String)
}

enum RecordingPhase: Equatable, Sendable {
    case idle
    case authorizing
    case recording
    case finalizing
}

struct StatusBarViewState: Equatable, Sendable {
    let recordingPhase: RecordingPhase
    let startEnabled: Bool
    let stopEnabled: Bool
    let recordingIcon: Bool
    let provider: ASRProvider
    let whisperModelID: String
    let effectiveAutoPaste: Bool
}

enum StartPermissionResult: Equatable, Sendable {
    case granted
    case deniedMicrophone
    case deniedScreenRecording
}

enum AutoPasteEnableResult: Equatable, Sendable {
    case enabled
    case promptRequested
    case settingsRequired
    case unavailable
}

enum AccessibilityPromptDecision: Equatable, Sendable {
    case requestPrompt
    case openSettings
    case throttled
}

struct PermissionViewState: Equatable, Sendable {
    let microphone: MicrophonePermissionState
    let screenRecordingGranted: Bool
    let accessibilityTrusted: Bool
    let effectiveAutoPaste: Bool
}

struct PermissionStatusReport: Equatable, Sendable {
    let microphoneGranted: Bool
    let screenRecordingGranted: Bool
    let accessibilityTrusted: Bool
    let effectiveAutoPaste: Bool
}
