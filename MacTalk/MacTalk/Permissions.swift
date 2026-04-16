//
//  Permissions.swift
//  MacTalk
//
//  System permissions management
//

import AppKit
import AVFoundation
import ScreenCaptureKit
@preconcurrency import ApplicationServices
import CoreGraphics

enum Permissions {
    // MARK: - Microphone Permission

    static func ensureMic(completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        switch microphonePermissionState() {
        case .granted:
            Task { @MainActor in
                NotificationCenter.default.post(name: .permissionsDidChange, object: nil)
                completion(true)
            }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in
                    NotificationCenter.default.post(name: .permissionsDidChange, object: nil)
                    completion(granted)
                }
            }
        case .denied, .restricted, .unknown:
            Task { @MainActor in
                NotificationCenter.default.post(name: .permissionsDidChange, object: nil)
                completion(false)
            }
        }
    }

    static func isMicrophoneAuthorized() -> Bool {
        microphonePermissionState() == .granted
    }

    /// Get the current microphone authorization status
    static func microphoneAuthorizationStatus() -> AVAuthorizationStatus {
        #if os(macOS)
        return AVCaptureDevice.authorizationStatus(for: .audio)
        #else
        return .denied
        #endif
    }

    static func microphonePermissionState() -> MicrophonePermissionState {
        switch microphoneAuthorizationStatus() {
        case .authorized:
            return .granted
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        @unknown default:
            return .unknown
        }
    }

    @MainActor
    static func showMicrophonePermissionGuidance() {
        let alert = NSAlert()
        alert.messageText = "Microphone Permission Required"
        alert.informativeText = "MacTalk needs microphone access before it can start recording. You can enable it in System Settings > Privacy & Security > Microphone."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open Microphone Settings")
        alert.addButton(withTitle: "Not Now")

        if alert.runModal() == .alertFirstButtonReturn {
            openMicrophoneSettings()
        }
    }

    // MARK: - Screen Recording Permission

    /// Check if screen recording permission is granted
    /// Uses CGPreflightScreenCaptureAccess() for reliable, synchronous check
    /// This will NOT hang like SCShareableContent can
    static func checkScreenRecordingPermission() -> Bool {
        NSLog("[Permissions] Checking screen recording permission with CGPreflightScreenCaptureAccess...")
        let hasPermission = CGPreflightScreenCaptureAccess()
        NSLog(hasPermission ? "[Permissions] Screen recording permission GRANTED" : "[Permissions] Screen recording permission NOT granted")
        return hasPermission
    }

    /// Request screen recording permission from the user
    /// This will trigger the system permission dialog if not already granted
    static func requestScreenRecordingPermission() {
        NSLog("[Permissions] Requesting screen recording permission...")
        CGRequestScreenCaptureAccess()
    }

    /// Show informational alert about screen recording permission
    @MainActor
    static func ensureScreenRecordingGuide() {
        NSLog("[Permissions] ensureScreenRecordingGuide() called - showing permission guide dialog")
        let alert = NSAlert()
        alert.messageText = "Screen Recording Permission Required"
        alert.informativeText = """
        To capture app audio (Mic + App mode), MacTalk needs Screen Recording permission.

        Steps:
        1. Open System Settings
        2. Go to Privacy & Security > Screen Recording
        3. Enable MacTalk
        4. Restart MacTalk

        Would you like to open System Settings now?
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSLog("[Permissions] User chose to open System Settings")
            openScreenRecordingSettings()
        } else {
            NSLog("[Permissions] User cancelled permission request")
        }
    }

    // MARK: - Accessibility Permission

    /// Check if accessibility permission is trusted
    /// Routes through PermissionsActor for thread-safe access
    static func isAccessibilityTrusted() -> Bool {
        let trusted = PermissionsActor.shared.isAccessibilityTrusted()
        NSLog("[Permissions] Accessibility permission check: \(trusted ? "TRUSTED" : "NOT TRUSTED")")
        return trusted
    }

    /// Request accessibility permission with optional prompt
    /// - Parameter showPrompt: If true, shows the system permission dialog
    /// - Returns: true if already trusted
    static func requestAccessibility(showPrompt: Bool = true) -> Bool {
        return PermissionsActor.shared.requestAccessibility(showPrompt: showPrompt)
    }

    /// Get accessibility diagnostics for troubleshooting
    static func getAccessibilityDiagnostics() -> PermissionDiagnostics {
        return PermissionsActor.shared.getDiagnostics()
    }

    @MainActor
    static func requestAccessibilityPermission(
        onGranted: (@MainActor @Sendable () -> Void)? = nil
    ) {
        NSLog("[Permissions] Requesting accessibility permission from user...")

        if isAccessibilityTrusted() {
            NotificationCenter.default.post(name: .permissionsDidChange, object: nil)
            onGranted?()
            return
        }

        Task { @MainActor in
            let isTrusted = PermissionsActor.shared.isAccessibilityTrusted()
            let hasRequestedThisSession = await PermissionsActor.shared.hasRequestedAccessibilityPromptThisSession()
            let action = PermissionFlowGate.accessibilityAction(
                isTrusted: isTrusted,
                hasRequestedThisSession: hasRequestedThisSession
            )

            switch action {
            case .none:
                NotificationCenter.default.post(name: .permissionsDidChange, object: nil)
                onGranted?()
            case .showSystemPrompt:
                await PermissionsActor.shared.markAccessibilityPromptRequestedThisSession()
                _ = PermissionsActor.shared.requestAccessibility(showPrompt: true)
                await startAccessibilityPolling(onGranted: onGranted)
            case .openSettings:
                let alert = NSAlert()
                alert.messageText = "Accessibility Permission Required"
                alert.informativeText = "Enable MacTalk in System Settings > Privacy & Security > Accessibility to allow auto-paste."
                alert.alertStyle = .informational
                alert.addButton(withTitle: "Open Accessibility Settings")
                alert.addButton(withTitle: "Not Now")

                if alert.runModal() == .alertFirstButtonReturn {
                    openAccessibilitySettings()
                    await startAccessibilityPolling(onGranted: onGranted)
                }
            }
        }
    }

    @MainActor
    private static func startAccessibilityPolling(
        onGranted: (@MainActor @Sendable () -> Void)?
    ) async {
        await PermissionsActor.shared.startPollingForGrant(
            onGranted: {
                NotificationCenter.default.post(name: .permissionsDidChange, object: nil)
                onGranted?()
            },
            onTimeout: {
                NotificationCenter.default.post(name: .permissionsDidChange, object: nil)
            }
        )
    }

    // MARK: - System Settings

    @MainActor
    static func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    @MainActor
    static func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    @MainActor
    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Permission Status Summary

    struct PermissionStatus {
        let microphone: Bool
        let accessibility: Bool

        var allGranted: Bool {
            return microphone && accessibility
        }
    }

    static func getPermissionStatus(completion: @escaping @MainActor (PermissionStatus) -> Void) {
        let status = PermissionStatus(
            microphone: isMicrophoneAuthorized(),
            accessibility: isAccessibilityTrusted()
        )
        Task { @MainActor in
            completion(status)
        }
    }
}
