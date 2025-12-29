//
//  ClipboardManager.swift
//  MacTalk
//
//  Clipboard operations and auto-paste functionality
//

import AppKit
import ApplicationServices

/// Clipboard manager for handling clipboard operations and auto-paste
/// @MainActor ensures all NSPasteboard operations happen on the main thread
/// and provides thread-safe access to clipboard history state.
@MainActor
enum ClipboardManager {
    // MARK: - Clipboard Operations

    /// Set text to system clipboard
    static func setClipboard(_ text: String) {
        NSLog("📋 [ClipboardManager] Setting clipboard with text: \(text.prefix(50))...")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let success = pasteboard.setString(text, forType: .string)
        if success {
            NSLog("✅ [ClipboardManager] Clipboard set successfully")
        } else {
            NSLog("❌ [ClipboardManager] Failed to set clipboard")
        }
    }

    /// Get current clipboard text
    static func getClipboard() -> String? {
        let pasteboard = NSPasteboard.general
        return pasteboard.string(forType: .string)
    }

    // MARK: - Auto-Paste

    /// Attempt to paste clipboard content using Cmd+V simulation
    static func pasteIfAllowed() {
        NSLog("🔍 [ClipboardManager] pasteIfAllowed() called - checking accessibility permission...")

        let isGranted = Permissions.isAccessibilityTrusted()
        NSLog("🔍 [ClipboardManager] Accessibility permission status: \(isGranted ? "GRANTED ✅" : "NOT GRANTED ❌")")

        guard isGranted else {
            NSLog("❌ [ClipboardManager] Accessibility permission not granted - cannot auto-paste")
            NSLog("🚨 [ClipboardManager] Requesting accessibility permission from user...")
            Permissions.requestAccessibilityPermission()
            return
        }

        NSLog("📝 [ClipboardManager] Accessibility granted - executing Cmd+V...")
        sendCommandV()
        NSLog("✅ [ClipboardManager] Auto-paste executed (Cmd+V sent)")
    }

    /// Simulate Command+V key press
    private static func sendCommandV() {
        let source = CGEventSource(stateID: .hidSystemState)

        // Virtual key code for 'V' key
        let vKeyCode: CGKeyCode = 9

        // Create key down event
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true) else {
            print("Failed to create key down event")
            return
        }
        keyDown.flags = .maskCommand

        // Create key up event
        guard let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) else {
            print("Failed to create key up event")
            return
        }
        keyUp.flags = .maskCommand

        // Post events to system
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    // MARK: - Alternative Paste Methods

    /// Attempt to paste via AppleScript (fallback method)
    static func pasteViaAppleScript() -> Bool {
        let script = """
        tell application "System Events"
            keystroke "v" using command down
        end tell
        """

        var error: NSDictionary?
        if let scriptObject = NSAppleScript(source: script) {
            scriptObject.executeAndReturnError(&error)
            if let error = error {
                print("AppleScript paste error: \(error)")
                return false
            }
            return true
        }
        return false
    }

    /// Check if a specific app supports paste
    static func canPasteInFrontmostApp() -> Bool {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            return false
        }

        // List of known apps that don't support simulated paste well
        let problematicApps = [
            "com.apple.loginwindow",
            "com.apple.SecurityAgent"
        ]

        return !problematicApps.contains(frontmostApp.bundleIdentifier ?? "")
    }

    // MARK: - Clipboard History (Future Enhancement)

    private static var clipboardHistory: [String] = []
    private static let maxHistorySize = 10

    /// Add to clipboard history
    static func addToHistory(_ text: String) {
        clipboardHistory.insert(text, at: 0)
        if clipboardHistory.count > maxHistorySize {
            clipboardHistory.removeLast()
        }
    }

    /// Get clipboard history
    static func getHistory() -> [String] {
        return clipboardHistory
    }

    /// Clear clipboard history
    static func clearHistory() {
        clipboardHistory.removeAll()
    }
}
