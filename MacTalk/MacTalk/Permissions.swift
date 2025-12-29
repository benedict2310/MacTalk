//
//  Permissions.swift
//  MacTalk
//
//  System permissions management
//

import AVFoundation
import ScreenCaptureKit
@preconcurrency import ApplicationServices
import CoreGraphics

enum Permissions {
    // MARK: - Microphone Permission

    static func ensureMic(completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        #if os(macOS)
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            Task { @MainActor in
                completion(true)
            }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in
                    completion(granted)
                }
            }
        case .denied, .restricted:
            Task { @MainActor in
                completion(false)
            }
        @unknown default:
            Task { @MainActor in
                completion(false)
            }
        }
        #else
        Task { @MainActor in
            completion(false)
        }
        #endif
    }

    static func isMicrophoneAuthorized() -> Bool {
        #if os(macOS)
        return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        #else
        return false
        #endif
    }

    /// Get the current microphone authorization status
    static func microphoneAuthorizationStatus() -> AVAuthorizationStatus {
        #if os(macOS)
        return AVCaptureDevice.authorizationStatus(for: .audio)
        #else
        return .denied
        #endif
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

    /// Trigger the system accessibility prompt
    /// Note: Uses PermissionsActor for proper memory management
    @MainActor
    static func ensureAccessibilityPrompt() {
        _ = PermissionsActor.shared.requestAccessibility(showPrompt: true)
    }

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
    static func requestAccessibilityPermission() {
        NSLog("[Permissions] Requesting accessibility permission from user...")

        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Required"
        alert.informativeText = """
        To enable auto-paste functionality, MacTalk needs Accessibility permission.

        Steps:
        1. Open System Settings
        2. Go to Privacy & Security > Accessibility
        3. Enable MacTalk

        Permission will take effect immediately - no restart needed.

        Would you like to open System Settings now?
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSLog("[Permissions] User chose to open System Settings")
            // Trigger the system prompt first
            _ = PermissionsActor.shared.requestAccessibility(showPrompt: true)
            openAccessibilitySettings()
        } else {
            NSLog("[Permissions] User cancelled permission request")
        }
    }

    // MARK: - System Settings

    @MainActor
    static func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    @MainActor
    static func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    @MainActor
    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
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
        ensureMic { micGranted in
            let status = PermissionStatus(
                microphone: micGranted,
                accessibility: isAccessibilityTrusted()
            )
            completion(status)
        }
    }
}
