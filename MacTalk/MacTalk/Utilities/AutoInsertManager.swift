//
//  AutoInsertManager.swift
//  MacTalk
//
//  Auto-insert text using AX SetValue first, with Cmd+V fallback
//

import AppKit
import ApplicationServices

/// Result of an auto-insert operation
enum AutoInsertResult: Sendable {
    case axSetValueSuccess
    case cmdVFallback
    case permissionDenied
    case failed(String)

    var succeeded: Bool {
        switch self {
        case .axSetValueSuccess, .cmdVFallback:
            return true
        case .permissionDenied, .failed:
            return false
        }
    }

    var description: String {
        switch self {
        case .axSetValueSuccess:
            return "Inserted via AX SetValue"
        case .cmdVFallback:
            return "Inserted via Cmd+V"
        case .permissionDenied:
            return "Accessibility permission not granted"
        case .failed(let reason):
            return "Failed: \(reason)"
        }
    }
}

/// Manager for auto-inserting text into the focused application
/// Uses AX SetValue first for direct insertion, falls back to Cmd+V if needed
@MainActor
enum AutoInsertManager {

    // MARK: - Public API

    /// Insert text into the currently focused text field
    /// - Parameter text: The text to insert
    /// - Returns: Result indicating which method was used or failure reason
    static func insertText(_ text: String) -> AutoInsertResult {
        NSLog("[AutoInsertManager] insertText called with \(text.count) characters")

        // Check accessibility permission first
        let isTrusted = PermissionsActor.shared.isAccessibilityTrusted()
        NSLog("[AutoInsertManager] AXIsProcessTrusted() returned: \(isTrusted)")

        // Log diagnostics for debugging
        let diagnostics = PermissionsActor.shared.getDiagnostics()
        NSLog("[AutoInsertManager] Bundle ID: \(diagnostics.bundleIdentifier)")
        NSLog("[AutoInsertManager] Team ID: \(diagnostics.teamIdentifier.isEmpty ? "(none)" : diagnostics.teamIdentifier)")
        NSLog("[AutoInsertManager] Ad-hoc signed: \(diagnostics.isAdHocSigned)")
        NSLog("[AutoInsertManager] Running from Xcode: \(diagnostics.isRunningFromXcode)")

        guard isTrusted else {
            NSLog("[AutoInsertManager] Accessibility permission not trusted - returning permissionDenied")
            return .permissionDenied
        }

        // Try AX SetValue first
        if tryAXSetValue(text) {
            NSLog("[AutoInsertManager] AX SetValue succeeded")
            return .axSetValueSuccess
        }

        NSLog("[AutoInsertManager] AX SetValue failed, falling back to Cmd+V")

        // Fallback to Cmd+V using existing ClipboardManager
        // Use async dispatch with small delay to avoid blocking main thread
        // and to ensure clipboard write is visible to the system
        ClipboardManager.setClipboard(text)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            Self.sendCommandV()
        }
        return .cmdVFallback
    }

    /// Insert text and request permission if needed
    /// - Parameters:
    ///   - text: The text to insert
    ///   - requestPermission: If true, will request permission if not granted
    /// - Returns: Result indicating which method was used or failure reason
    static func insertTextWithPermissionRequest(_ text: String, requestPermission: Bool = true) -> AutoInsertResult {
        // Check accessibility permission
        if !PermissionsActor.shared.isAccessibilityTrusted() {
            if requestPermission {
                NSLog("[AutoInsertManager] Requesting accessibility permission")
                _ = PermissionsActor.shared.requestAccessibility(showPrompt: true)
            }
            return .permissionDenied
        }

        return insertText(text)
    }

    // MARK: - AX SetValue Implementation

    /// Try to insert text at cursor position using Accessibility API
    /// CR-01: Properly inserts at cursor position instead of replacing entire field
    /// CR-02: Checks role/editability before attempting insertion
    /// - Parameter text: The text to insert
    /// - Returns: true if successful
    private static func tryAXSetValue(_ text: String) -> Bool {
        // Get the system-wide accessibility element
        let systemWide = AXUIElementCreateSystemWide()

        // Get the focused UI element
        var focusedElement: AnyObject?
        let focusResult = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )

        guard focusResult == .success, let element = focusedElement else {
            NSLog("[AutoInsertManager] Failed to get focused element: \(focusResult.rawValue)")
            return false
        }

        let axElement = element as! AXUIElement

        // CR-02: Check if element is an editable text field
        guard isEditableTextField(axElement) else {
            NSLog("[AutoInsertManager] Focused element is not an editable text field")
            return false
        }

        // CR-01: Try to insert at selection/cursor position instead of replacing all text
        if tryInsertAtSelection(axElement, text: text) {
            NSLog("[AutoInsertManager] AX insert at selection succeeded")
            return true
        }

        // Fallback: If insert at selection doesn't work, don't try to replace entire value
        // This prevents accidental data loss - let Cmd+V handle it instead
        NSLog("[AutoInsertManager] AX insert at selection not supported, falling back to Cmd+V")
        return false
    }

    /// CR-02: Check if the element is an editable text field
    private static func isEditableTextField(_ element: AXUIElement) -> Bool {
        // Get the role
        var roleValue: AnyObject?
        let roleResult = AXUIElementCopyAttributeValue(
            element,
            kAXRoleAttribute as CFString,
            &roleValue
        )

        guard roleResult == .success, let role = roleValue as? String else {
            NSLog("[AutoInsertManager] Could not get element role")
            return false
        }

        // Check if it's a text field, text area, or combo box
        let textRoles = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXComboBoxRole as String,
            "AXSearchField" // Common in search bars
        ]

        guard textRoles.contains(role) else {
            NSLog("[AutoInsertManager] Element role '\(role)' is not a text input type")
            return false
        }

        // Check if the element has a settable value
        var isSettable: DarwinBoolean = false
        let settableResult = AXUIElementIsAttributeSettable(
            element,
            kAXValueAttribute as CFString,
            &isSettable
        )

        guard settableResult == .success, isSettable.boolValue else {
            NSLog("[AutoInsertManager] Element value is not settable")
            return false
        }

        return true
    }

    /// CR-01: Insert text at the current selection/cursor position
    private static func tryInsertAtSelection(_ element: AXUIElement, text: String) -> Bool {
        // Get current value
        var currentValue: AnyObject?
        let valueResult = AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &currentValue
        )

        guard valueResult == .success, let currentText = currentValue as? String else {
            NSLog("[AutoInsertManager] Could not get current value")
            return false
        }

        // Try to get the selected text range
        var selectedRangeValue: AnyObject?
        let rangeResult = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &selectedRangeValue
        )

        // If we can't get selection range, we can't safely insert
        guard rangeResult == .success else {
            NSLog("[AutoInsertManager] Could not get selected text range: \(rangeResult.rawValue)")
            return false
        }

        // Extract the range from the AXValue
        var range = CFRange(location: 0, length: 0)
        guard let axValue = selectedRangeValue,
              AXValueGetValue(axValue as! AXValue, .cfRange, &range) else {
            NSLog("[AutoInsertManager] Could not extract range from AXValue")
            return false
        }

        NSLog("[AutoInsertManager] Selection range: location=\(range.location), length=\(range.length)")

        // Build the new text by replacing the selected range with our text
        let startIndex = currentText.index(currentText.startIndex, offsetBy: range.location, limitedBy: currentText.endIndex) ?? currentText.endIndex
        let endIndex = currentText.index(startIndex, offsetBy: range.length, limitedBy: currentText.endIndex) ?? currentText.endIndex

        var newText = currentText
        newText.replaceSubrange(startIndex..<endIndex, with: text)

        // Set the new value
        let setResult = AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            newText as CFTypeRef
        )

        guard setResult == .success else {
            NSLog("[AutoInsertManager] Failed to set new value: \(setResult.rawValue)")
            return false
        }

        // Move cursor to end of inserted text
        let newCursorPosition = range.location + text.count
        var newRange = CFRange(location: newCursorPosition, length: 0)
        if let newRangeValue = AXValueCreate(.cfRange, &newRange) {
            _ = AXUIElementSetAttributeValue(
                element,
                kAXSelectedTextRangeAttribute as CFString,
                newRangeValue
            )
        }

        return true
    }

    // MARK: - Cmd+V Fallback

    /// Simulate Command+V key press (same as ClipboardManager.sendCommandV)
    private static func sendCommandV() {
        let source = CGEventSource(stateID: .hidSystemState)

        // Virtual key code for 'V' key
        let vKeyCode: CGKeyCode = 9

        // Create key down event
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true) else {
            NSLog("[AutoInsertManager] Failed to create key down event")
            return
        }
        keyDown.flags = .maskCommand

        // Create key up event
        guard let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) else {
            NSLog("[AutoInsertManager] Failed to create key up event")
            return
        }
        keyUp.flags = .maskCommand

        // Post events to system
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
