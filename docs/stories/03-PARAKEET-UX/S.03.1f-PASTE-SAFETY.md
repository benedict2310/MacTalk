# S.03.1f - Paste Safety & App Blacklist

**Epic:** Real-Time Streaming Transcription
**Status:** Draft
**Date:** 2025-12-14
**Dependency:** S.01.2 (independent feature)
**Priority:** Medium

---

## 1. Objective

Improve the auto-paste feature with safety guards to prevent accidental pasting into sensitive applications.

**Goal:** Users can trust auto-paste won't interfere with Terminal, IDE command palettes, or other sensitive contexts.

---

## 2. Architecture Context & Reuse

- Auto-paste is triggered in `MacTalk/MacTalk/StatusBarController.swift` after final transcription.
- Clipboard operations are centralized in `MacTalk/MacTalk/ClipboardManager.swift` (`@MainActor`).
- The auto-paste toggle is stored in `UserDefaults` under the `autoPaste` key via Settings.

## 3. Acceptance Criteria

- [ ] App blacklist prevents auto-paste into specified apps
- [ ] Default blacklist includes Terminal, iTerm, IDE terminals
- [ ] Paste timeout: only paste if focus hasn't changed for 3s
- [ ] Visual indicator shows paste target before executing
- [ ] Manual "paste now" option always available
- [ ] Clipboard always updated regardless of auto-paste status
- [ ] User can customize blacklist in Settings

---

## 4. Default Blacklist

### Always Blocked (Hard-coded)
- Terminal.app
- iTerm.app
- Hyper
- Alacritty
- Kitty
- Warp

### Default Blocked (User can override)
- Xcode (command palette context)
- Visual Studio Code
- IntelliJ IDEA
- Sublime Text
- Nova
- BBEdit

### Context-Aware Blocking
- Password fields (detected via Accessibility)
- Search fields in Spotlight/Alfred
- URL bars in browsers

---

## 5. Implementation Plan

### Step 1: PasteSafetyManager

```swift
/// Manages auto-paste safety and app blacklisting
final class PasteSafetyManager {
    static let shared = PasteSafetyManager()

    // MARK: - Blacklist

    private let hardcodedBlacklist: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "co.zeit.hyper",
        "io.alacritty",
        "net.kovidgoyal.kitty",
        "dev.warp.Warp-Stable"
    ]

    private var userBlacklist: Set<String> {
        get {
            Set(UserDefaults.standard.stringArray(forKey: "pasteBlacklist") ?? [
                "com.apple.dt.Xcode",
                "com.microsoft.VSCode",
                "com.jetbrains.intellij"
            ])
        }
        set {
            UserDefaults.standard.set(Array(newValue), forKey: "pasteBlacklist")
        }
    }

    var fullBlacklist: Set<String> {
        hardcodedBlacklist.union(userBlacklist)
    }

    // MARK: - Focus Stability

    private var lastFocusedBundleId: String?
    private var focusStableSince: Date?
    private let requiredStabilityDuration: TimeInterval = 3.0

    // MARK: - Safety Checks

    /// Check if auto-paste is safe for the current frontmost app
    func isSafeToAutoPaste() -> PasteSafetyResult {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            return .blocked(reason: "No frontmost application")
        }

        let bundleId = frontmostApp.bundleIdentifier ?? ""
        let appName = frontmostApp.localizedName ?? "Unknown"

        // Check blacklist
        if fullBlacklist.contains(bundleId) {
            return .blocked(reason: "'\(appName)' is in the paste blacklist")
        }

        // Check for password/sensitive field via Accessibility
        if isPasswordFieldFocused() {
            return .blocked(reason: "Password field detected")
        }

        // Check focus stability
        guard isFocusStable(bundleId: bundleId) else {
            return .blocked(reason: "Focus changed recently")
        }

        return .safe(app: appName, bundleId: bundleId)
    }

    /// Check if a password field is focused (requires Accessibility permission)
    private func isPasswordFieldFocused() -> Bool {
        guard let focusedElement = getFocusedElement() else { return false }

        var isSecure: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            focusedElement,
            kAXIsSecureTextFieldAttribute as CFString,
            &isSecure
        )

        return result == .success && (isSecure as? Bool) == true
    }

    private func getFocusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedElement: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )

        guard result == .success else { return nil }
        return (focusedElement as! AXUIElement)
    }

    private func isFocusStable(bundleId: String) -> Bool {
        if bundleId != lastFocusedBundleId {
            lastFocusedBundleId = bundleId
            focusStableSince = Date()
            return false
        }

        guard let stableSince = focusStableSince else {
            focusStableSince = Date()
            return false
        }

        return Date().timeIntervalSince(stableSince) >= requiredStabilityDuration
    }

    // MARK: - Blacklist Management

    func addToBlacklist(_ bundleId: String) {
        userBlacklist.insert(bundleId)
    }

    func removeFromBlacklist(_ bundleId: String) {
        userBlacklist.remove(bundleId)
    }

    func isBlacklisted(_ bundleId: String) -> Bool {
        fullBlacklist.contains(bundleId)
    }
}

enum PasteSafetyResult {
    case safe(app: String, bundleId: String)
    case blocked(reason: String)

    var isSafe: Bool {
        if case .safe = self { return true }
        return false
    }
}
```

**File:** `MacTalk/MacTalk/Utilities/PasteSafetyManager.swift`

### Step 2: StatusBarController Integration

```swift
// In StatusBarController.onFinal
let safety = PasteSafetyManager.shared.isSafeToAutoPaste()

switch safety {
case .safe:
    ClipboardManager.pasteIfAllowed()
case .blocked(let reason):
    showNotification(title: "Auto-paste skipped", message: reason)
}
```

### Step 3: Pre-Paste Indicator

Show a brief indicator before auto-pasting:

```swift
// In HUDWindowController or separate overlay
func showPastePreview(text: String, targetApp: String, completion: @escaping () -> Void) {
    // Show small overlay: "Pasting to [App Name]..."
    // After 1 second, execute completion (the actual paste)
    // User can press Escape to cancel

    let previewWindow = PastePreviewWindow()
    previewWindow.show(text: text, targetApp: targetApp)

    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        if !previewWindow.wasCancelled {
            completion()
        }
        previewWindow.close()
    }
}
```

### Step 4: Settings UI

```swift
// In SettingsWindowController - Security/Privacy section
func setupPasteSafetySettings() {
    // Toggle: Enable auto-paste
    // Slider: Focus stability duration (1-5 seconds)
    // List: Blacklisted apps with add/remove buttons

    // "Add Current App" button - adds frontmost app to blacklist
    // "Reset to Defaults" button
}
```

---

## 6. User Notifications

When paste is blocked, show a subtle notification:

```swift
func notifyPasteBlocked(reason: String, text: String) {
    showNotification(
        title: "Auto-paste blocked",
        message: "\(reason). Text copied to clipboard."
    )
}
```

---

## 7. Test Plan

### Unit Tests
- `PasteSafetyManagerTests` - Blacklist logic, safety checks
- Bundled ID matching
- Focus stability timing

### Integration Tests
- Paste blocked for Terminal
- Paste allowed for TextEdit
- Clipboard always updated

### Manual Testing
- Open Terminal, verify paste blocked
- Switch apps rapidly, verify stability timeout works
- Test with password field in Safari

---

## 8. Files Summary

### New Files
- `MacTalk/MacTalk/Utilities/PasteSafetyManager.swift`
- `MacTalk/MacTalkTests/PasteSafetyManagerTests.swift`

### Modified Files
- `MacTalk/MacTalk/StatusBarController.swift` - Safety gating before auto-paste
- `MacTalk/MacTalk/SettingsWindowController.swift` - Blacklist UI
