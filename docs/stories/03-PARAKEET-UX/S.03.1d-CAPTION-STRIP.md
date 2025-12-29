# S.03.1d - Caption Strip / Window Pinning

**Epic:** Real-Time Streaming Transcription
**Status:** Draft
**Date:** 2025-12-14
**Dependency:** S.03.1a
**Priority:** Medium

---

## 1. Objective

Provide a minimal caption overlay that pins to a specific window or app, enabling live captions for video calls, media playback, etc.

**Goal:** Users can attach a caption strip to any window that follows the window as it moves/resizes.

---

## 2. Architecture Context & Reuse

- Reuse `ScreenCaptureKit` types already used by `AppPickerWindowController` for window enumeration and selection.
- Keep the caption strip as a separate `NSWindowController` in `MacTalk/MacTalk/UI` (do not overload the HUD bubble).
- Poll window frames at a modest rate (e.g., 30Hz) and avoid any work on the audio callback thread.

## 3. Acceptance Criteria

- [ ] Caption strip can be pinned to any visible window
- [ ] Strip follows window movement in real-time
- [ ] Strip repositions on window resize
- [ ] Auto-hides when target window is minimized/closed
- [ ] Shows on correct display in multi-monitor setup
- [ ] Minimal, non-intrusive design (slim bar at bottom of window)
- [ ] Transcription latency <1s when pinned to app audio source

---

## 4. Design

### Caption Strip Layout

```
┌─────────────────────────────────────────────────────┐
│                                                     │
│                  [Target Window]                    │
│                                                     │
│                                                     │
├─────────────────────────────────────────────────────┤
│  [A] Hello, this is the live transcription...       │ ← Caption strip
└─────────────────────────────────────────────────────┘
```

### Strip Modes

1. **Pinned to Window** - Follows specific window
2. **Pinned to Screen** - Fixed position on screen (current HUD behavior)
3. **Floating** - Draggable, stays where user places it

---

## 5. Implementation Plan

### Step 1: Window Tracking Service

```swift
/// Tracks a target window's position and visibility
final class WindowTracker {
    private var targetWindow: SCWindow?
    private var displayLink: CVDisplayLink?
    private var lastFrame: CGRect = .zero

    var onFrameChanged: ((CGRect) -> Void)?
    var onWindowClosed: (() -> Void)?
    var onWindowMinimized: (() -> Void)?

    func track(window: SCWindow) async throws {
        self.targetWindow = window

        // Start polling window position
        // Note: No direct API for window move notifications
        // Use display link or timer for smooth tracking
        startTracking()
    }

    func stopTracking() {
        displayLink = nil
        targetWindow = nil
    }

    private func startTracking() {
        // Use Timer for simplicity (display link for smoother tracking)
        Timer.scheduledTimer(withTimeInterval: 1.0/30.0, repeats: true) { [weak self] _ in
            self?.checkWindowFrame()
        }
    }

    private func checkWindowFrame() {
        guard let window = targetWindow else { return }

        // Get current window frame via ScreenCaptureKit or Accessibility API
        Task {
            let content = try? await SCShareableContent.current
            if let current = content?.windows.first(where: { $0.windowID == window.windowID }) {
                let frame = current.frame
                if frame != lastFrame {
                    lastFrame = frame
                    await MainActor.run {
                        onFrameChanged?(frame)
                    }
                }
            } else {
                // Window closed
                await MainActor.run {
                    onWindowClosed?()
                }
            }
        }
    }
}
```

**File:** `MacTalk/MacTalk/UI/WindowTracker.swift`

### Step 2: Caption Strip Window Controller

```swift
/// Minimal caption overlay that pins to windows
final class CaptionStripController: NSWindowController {
    private let textField = NSTextField(labelWithString: "")
    private let windowTracker = WindowTracker()
    private var targetWindowFrame: CGRect = .zero

    override func loadWindow() {
        // Create borderless, transparent window
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 44),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = NSColor.black.withAlphaComponent(0.7)
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.hasShadow = true

        // Round corners
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.cornerRadius = 8

        setupTextField()
        self.window = window
    }

    private func setupTextField() {
        textField.font = .systemFont(ofSize: 16, weight: .medium)
        textField.textColor = .white
        textField.alignment = .center
        textField.lineBreakMode = .byTruncatingHead
        textField.maximumNumberOfLines = 2

        window?.contentView?.addSubview(textField)
        // Layout constraints...
    }

    func pinTo(window: SCWindow) async throws {
        try await windowTracker.track(window: window)

        windowTracker.onFrameChanged = { [weak self] frame in
            self?.targetWindowFrame = frame
            self?.updatePosition()
        }

        windowTracker.onWindowClosed = { [weak self] in
            self?.detach()
        }

        // Initial position
        targetWindowFrame = window.frame
        updatePosition()
        self.window?.orderFront(nil)
    }

    func detach() {
        windowTracker.stopTracking()
        window?.orderOut(nil)
    }

    private func updatePosition() {
        guard let window = self.window else { return }

        // Position at bottom of target window
        let stripHeight: CGFloat = 44
        let padding: CGFloat = 8

        let newFrame = NSRect(
            x: targetWindowFrame.origin.x + padding,
            y: targetWindowFrame.origin.y - stripHeight - padding,
            width: targetWindowFrame.width - (padding * 2),
            height: stripHeight
        )

        window.setFrame(newFrame, display: true, animate: false)
    }

    func updateText(_ text: String) {
        textField.stringValue = text
    }

    func updatePartial(_ text: String) {
        textField.stringValue = text
        textField.textColor = NSColor.white.withAlphaComponent(0.7)
    }

    func updateFinal(_ text: String) {
        textField.stringValue = text
        textField.textColor = .white

        // Brief highlight animation
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            textField.animator().alphaValue = 0.5
        } completionHandler: {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                self.textField.animator().alphaValue = 1.0
            }
        }
    }
}
```

**File:** `MacTalk/MacTalk/UI/CaptionStripController.swift`

### Step 3: Window Picker Integration

Extend existing `AppPickerWindowController` to support window selection for caption pinning:

```swift
// In AppPickerWindowController or new WindowPickerController
func showWindowPicker(completion: @escaping (SCWindow?) -> Void) {
    Task {
        let content = try await SCShareableContent.current

        // Filter to visible windows
        let windows = content.windows.filter {
            $0.isOnScreen && $0.frame.width > 100 && $0.frame.height > 100
        }

        // Show picker UI
        await MainActor.run {
            // Present picker with window thumbnails
            // User selects window
            // Call completion with selected window
        }
    }
}
```

### Step 4: Menu Integration

Add caption strip controls to menu bar:

```swift
// In StatusBarController menu setup
let captionMenu = NSMenu()

let pinToWindowItem = NSMenuItem(title: "Pin to Window...", action: #selector(selectWindowForCaption), keyEquivalent: "")
let detachItem = NSMenuItem(title: "Detach Caption Strip", action: #selector(detachCaptionStrip), keyEquivalent: "")
detachItem.isEnabled = captionStripController?.window?.isVisible ?? false

captionMenu.addItem(pinToWindowItem)
captionMenu.addItem(detachItem)

let captionSubmenu = NSMenuItem(title: "Caption Strip", action: nil, keyEquivalent: "")
captionSubmenu.submenu = captionMenu
menu.addItem(captionSubmenu)
```

### Step 5: Audio Source Linking

When pinning to a window, offer to capture that app's audio:

```swift
func pinWithAudioCapture(window: SCWindow) async throws {
    // Pin caption strip
    try await captionStripController.pinTo(window: window)

    // Offer to capture app audio
    if let app = window.owningApplication {
        let alert = NSAlert()
        alert.messageText = "Capture Audio?"
        alert.informativeText = "Would you like to transcribe audio from \(app.applicationName)?"
        alert.addButton(withTitle: "Yes")
        alert.addButton(withTitle: "No, Mic Only")

        if alert.runModal() == .alertFirstButtonReturn {
            try await screenAudioCapture.selectApp(app: app)
        }
    }
}
```

---

## 6. Settings

```swift
extension AppSettings {
    var captionStripEnabled: Bool { ... }
    var captionStripOpacity: Float { ... }      // 0.5 - 1.0
    var captionStripFontSize: CGFloat { ... }   // 12 - 24
    var captionStripPosition: CaptionPosition { ... }  // .bottom, .top

    enum CaptionPosition: String, Codable {
        case bottom, top
    }
}
```

---

## 7. Test Plan

### Unit Tests
- `WindowTrackerTests` - Frame change detection, closure handling
- `CaptionStripControllerTests` - Positioning calculations

### Integration Tests
- Pin to window, verify strip follows
- Window resize updates strip width
- Window close triggers detach

### Manual Testing
- Pin to Zoom window, verify captions appear
- Move window across monitors
- Minimize/restore target window

---

## 8. Files Summary

### New Files
- `MacTalk/MacTalk/UI/WindowTracker.swift`
- `MacTalk/MacTalk/UI/CaptionStripController.swift`
- `MacTalk/MacTalkTests/WindowTrackerTests.swift`

### Modified Files
- `MacTalk/MacTalk/StatusBarController.swift` - Menu items
- `MacTalk/MacTalk/UI/AppPickerWindowController.swift` - Window selection
- `MacTalk/MacTalk/SettingsWindowController.swift` - Caption settings
