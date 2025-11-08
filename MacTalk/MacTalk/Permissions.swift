//
//  Permissions.swift
//  MacTalk
//
//  System permissions management
//

import AVFoundation
import ScreenCaptureKit
import ApplicationServices

enum Permissions {
    // MARK: - Microphone Permission

    static func ensureMic(completion: @escaping (Bool) -> Void) {
        #if os(macOS)
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                completion(granted)
            }
        case .denied, .restricted:
            completion(false)
        @unknown default:
            completion(false)
        }
        #else
        completion(false)
        #endif
    }

    static func isMicrophoneAuthorized() -> Bool {
        #if os(macOS)
        return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        #else
        return false
        #endif
    }

    // MARK: - Screen Recording Permission

    static func ensureScreenRecordingGuide() {
        // ScreenCaptureKit will automatically trigger the system prompt
        // when attempting to capture screen content
        let alert = NSAlert()
        alert.messageText = "Screen Recording Permission Required"
        alert.informativeText = """
        To capture app audio (Mode B), MacTalk needs Screen Recording permission.

        When you start capturing app audio, macOS will prompt you to grant this permission.

        You can also enable it manually:
        System Settings > Privacy & Security > Screen Recording > MacTalk
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    static func checkScreenRecordingPermission() async -> Bool {
        // Try to get shareable content - this will trigger permission if needed
        NSLog("🔍 [Permissions] Checking screen recording permission...")
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            NSLog("✅ [Permissions] Screen recording permission GRANTED")
            NSLog("🔍 [Permissions] Available: \(content.displays.count) displays, \(content.applications.count) apps, \(content.windows.count) windows")
            return true
        } catch let error as NSError {
            NSLog("❌ [Permissions] Screen recording permission check FAILED")
            NSLog("❌ [Permissions]   Domain: \(error.domain)")
            NSLog("❌ [Permissions]   Code: \(error.code)")
            NSLog("❌ [Permissions]   Description: \(error.localizedDescription)")
            NSLog("❌ [Permissions]   User Info: \(error.userInfo)")
            return false
        }
    }

    // MARK: - Accessibility Permission

    static func ensureAccessibilityPrompt() {
        let options = [
            kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true
        ] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func isAccessibilityTrusted() -> Bool {
        return AXIsProcessTrusted()
    }

    static func requestAccessibilityPermission() {
        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Required"
        alert.informativeText = """
        To enable auto-paste functionality, MacTalk needs Accessibility permission.

        Steps:
        1. Open System Settings
        2. Go to Privacy & Security > Accessibility
        3. Enable MacTalk

        Would you like to open System Settings now?
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            openAccessibilitySettings()
        }
    }

    // MARK: - System Settings

    static func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

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

    static func getPermissionStatus(completion: @escaping (PermissionStatus) -> Void) {
        ensureMic { micGranted in
            let status = PermissionStatus(
                microphone: micGranted,
                accessibility: isAccessibilityTrusted()
            )
            completion(status)
        }
    }
}
