# S.01.4 Model Selection UX - Apple Documentation Best Practices

**Research Date:** December 14, 2025
**Based On:** Apple Developer Documentation via DocC API
**Frameworks Researched:** AppKit, NSAlert, NSProgressIndicator, NSPopUpButton, NSTextField, NSControl

---

## Executive Summary

This document provides Apple-recommended best practices for implementing the model selection UX in MacTalk's Settings window. The recommendations are derived from official Apple documentation for key AppKit controls used in settings interfaces.

**Key Findings:**
- Use **NSPopUpButton** for model selection with dynamic item management
- Use **NSProgressIndicator** (indeterminate style) for loading states
- Use **NSAlert** with sheet modality for confirmation dialogs
- Use **NSTextField** (read-only label) for non-editable status display
- Leverage **NSControl** target-action pattern for state notifications

---

## 1. Model Selection Dropdown (NSPopUpButton)

### Apple Recommendation
[NSPopUpButton](https://developer.apple.com/documentation/appkit/nspopupbutton) is "A control for selecting an item from a list."

### Key Features from Apple Docs

**Programmatic Menu Management:**
- `addItem(withTitle:)` - Add items dynamically
- `removeAllItems()` / `removeItem(at:)` - Clear or remove specific items
- `selectItem(at:)` / `selectItem(withTitle:)` - Set selection programmatically
- `titleOfSelectedItem` / `indexOfSelectedItem` - Read current selection

**State Synchronization:**
- `synchronizeTitleAndSelectedItem()` - Keep title and selection in sync after changes
- `willPopUpNotification` - Handle menu state changes

**Item Configuration:**
- `autoenablesItems` - Automatically enable/disable items based on state
- `itemArray` - Access menu items as array

### Design Pattern for MacTalk

**When Whisper is selected:**
```
Provider: [Whisper ▼]
Model:    [small | base | medium | large ▼]  ← Show dropdown
```

**When Parakeet is selected:**
```
Provider: [Parakeet ▼]
Model:    Parakeet TDT 0.6B (Core ML)         ← Show read-only label instead
```

### Implementation Strategy

1. **Keep two controls in layout:**
   - `NSPopUpButton` for Whisper models (visible when Whisper selected)
   - `NSTextField` read-only label for Parakeet (visible when Parakeet selected)

2. **Use control visibility toggling:**
   ```swift
   modelDropdown.isHidden = isParakeetSelected
   parakeetLabel.isHidden = !isParakeetSelected
   ```

3. **Programmatically populate on provider change:**
   ```swift
   func updateModelDropdown(forProvider provider: String) {
       modelDropdown.removeAllItems()
       if provider == "Whisper" {
           modelDropdown.addItems(withTitles: ["tiny", "base", "small", "medium", "large"])
       }
       modelDropdown.synchronizeTitleAndSelectedItem()
   }
   ```

---

## 2. Loading State Indicator (NSProgressIndicator)

### Apple Recommendation
[NSProgressIndicator](https://developer.apple.com/documentation/appkit/nsprogressindicator) "provides visual feedback to the user about the status of an ongoing task."

### Key Features from Apple Docs

**Two Indicator Types:**
- **Determinate:** Shows completion percentage (when you have progress data)
- **Indeterminate:** Shows that app is busy without duration estimate

**For MacTalk Loading States (Indeterminate Recommended):**
- `isIndeterminate = true` - Show spinner without progress percentage
- `startAnimation(_:)` - Begin the animation
- `stopAnimation(_:)` - Stop animation when complete
- `isDisplayedWhenStopped` - Control visibility when not animating

**Styling:**
- `controlSize` - Small/regular/large sizes (use `.small` for settings)
- `controlTint` - Color (system default recommended)
- `isBezeled` - Add border (false recommended for minimal style)

### Design Pattern for MacTalk

**Add status row below provider dropdown:**

```
Inference Engine:
  Status: [◉ spinner] Loading engine...
          OR
  Status: [✓] Ready
          OR
  Status: [!] Error: Failed to initialize
```

### Implementation Strategy

1. **Create status display row with indicator and label:**
   ```swift
   let spinner = NSProgressIndicator()
   spinner.style = .spinning
   spinner.controlSize = .small
   spinner.isIndeterminate = true

   let statusLabel = NSTextField(labelWithString: "")
   ```

2. **Show/hide based on engine state:**
   ```swift
   func updateEngineStatus(_ state: EngineState) {
       switch state {
       case .idle:
           spinner.stopAnimation(nil)
           statusLabel.stringValue = "Ready"
           statusLabel.textColor = .systemGreen

       case .loading:
           spinner.startAnimation(nil)
           statusLabel.stringValue = "Loading engine..."
           statusLabel.textColor = .controlTextColor

       case .error(let msg):
           spinner.stopAnimation(nil)
           statusLabel.stringValue = "Error: \(msg)"
           statusLabel.textColor = .systemRed
       }
   }
   ```

3. **Wire up to engine state notifications:**
   - Listen to `ParakeetBootstrap.isLoading` property
   - Listen to engine initialization errors
   - Update UI on main thread

---

## 3. Confirmation Dialog (NSAlert)

### Apple Recommendation
[NSAlert](https://developer.apple.com/documentation/appkit/nsalert) is "A modal dialog or sheet attached to a document window."

### Key Features from Apple Docs

**Alert Properties:**
- `alertStyle` - Conveys importance (warning, informational, critical)
- `messageText` - Main message title
- `informativeText` - Additional context
- `addButton(withTitle:)` - Add response buttons (OK, Cancel, etc.)

**Presentation Methods:**
- `beginSheetModal(for:completionHandler:)` - Preferred for settings window
- `runModal()` - Full app-modal dialog (less preferred for settings)

**Design Guidance:**
> "An `NSAlert` object is intended for a single alert—that is, an alert with a unique combination of title, buttons, and so on—that is displayed upon a particular condition."

### Design Pattern for MacTalk

**Before downloading Parakeet model:**

```
┌─────────────────────────────────────────┐
│  Download Parakeet Model?               │
├─────────────────────────────────────────┤
│  This will download approximately 600MB │
│  of model files. Continue?              │
│                                         │
│  [Cancel]  [Download]                   │
└─────────────────────────────────────────┘
```

### Implementation Strategy

1. **Create reusable alert factory:**
   ```swift
   func showDownloadConfirmation(
       modelName: String,
       size: String,
       window: NSWindow,
       completion: @escaping (Bool) -> Void
   ) {
       let alert = NSAlert()
       alert.alertStyle = .informational
       alert.messageText = "Download \(modelName)?"
       alert.informativeText = "This will download \(size) of model files."

       alert.addButton(withTitle: "Download")
       alert.addButton(withTitle: "Cancel")

       alert.beginSheetModal(for: window) { response in
           completion(response == .alertFirstButtonReturn)
       }
   }
   ```

2. **Use sheet modal (not app modal) for settings window:**
   - More user-friendly than blocking entire app
   - Allows users to see context while deciding
   - Recommended by Apple for secondary windows

3. **Provide clear, concise messaging:**
   - messageText: What will happen (action verb)
   - informativeText: Why and what to expect (size, time estimate if known)

---

## 4. Status Display (NSTextField)

### Apple Recommendation
[NSTextField](https://developer.apple.com/documentation/appkit/nstextfield) is used for "Text the user can select or edit to send an action message."

### Key Features from Apple Docs

**Read-Only Label Creation:**
- `init(labelWithString:)` - Creates non-editable label
- `isEditable = false` - Explicitly disable editing
- `isSelectable = false` - Disable text selection
- `textColor` - Control label color

**For Status Display:**
- No bezeled border for labels (clean appearance)
- Use system colors for semantic meaning
- Supports multi-line wrapping if needed

### Design Pattern for MacTalk

**For Parakeet model info:**

```swift
let modelLabel = NSTextField(labelWithString: "")
modelLabel.stringValue = "Parakeet TDT 0.6B (Core ML)"
modelLabel.isEditable = false
modelLabel.isSelectable = false
modelLabel.textColor = .secondaryLabelColor  // Subtle styling
```

**For status messaging:**

```
Status Messages:
- "Ready" → textColor = .systemGreen or default
- "Loading..." → textColor = .systemOrange or .controlTextColor
- "Error: ..." → textColor = .systemRed
```

### Implementation Strategy

1. **Use NSTextField.init(labelWithString:) for read-only display:**
   ```swift
   let statusLabel = NSTextField(labelWithString: "Status: Ready")
   // Automatically sets isEditable = false
   ```

2. **Semantic coloring for states:**
   ```swift
   func updateStatusLabel(_ label: NSTextField, state: String) {
       switch state {
       case "Ready":
           label.stringValue = "Ready"
           label.textColor = .secondaryLabelColor
       case "Loading":
           label.stringValue = "Loading..."
           label.textColor = .controlTextColor
       case "Error":
           label.stringValue = "Error initializing engine"
           label.textColor = .systemRed
       }
   }
   ```

---

## 5. Target-Action Pattern (NSControl)

### Apple Recommendation
[NSControl](https://developer.apple.com/documentation/appkit/nscontrol) "notifies your app of relevant events using the target-action design pattern."

### Key Features from Apple Docs

**Notification System:**
- `action` and `target` properties - Define action to trigger
- `sendAction(_:to:)` - Programmatically send action
- Control subclasses notify via `willPopUpNotification` and similar

**For MacTalk:**
- Use target-action for provider/model selection changes
- Wire up to update dependent UI elements
- Avoid tight coupling between controls

### Implementation Strategy

1. **Set up provider dropdown action:**
   ```swift
   providerDropdown.target = self
   providerDropdown.action = #selector(providerSelectionChanged(_:))

   @objc func providerSelectionChanged(_ sender: NSPopUpButton) {
       let selectedProvider = sender.titleOfSelectedItem ?? ""
       updateModelDropdown(forProvider: selectedProvider)
       updateEngineStatus()
   }
   ```

2. **Leverage notifications for state changes:**
   ```swift
   NotificationCenter.default.addObserver(
       self,
       selector: #selector(engineStateDidChange(_:)),
       name: NSNotification.Name("ParakeetEngineStateChanged"),
       object: nil
   )
   ```

---

## 6. Download Progress Feedback

### Pattern for Unified Download Experience

While NSProgressIndicator doesn't provide built-in progress percentage display in settings, follow this pattern:

**Option A: Indeterminate Spinner with Text (Recommended for Phase A)**
```
Downloading Parakeet...
[◉ spinner]
Status: Downloading (file 1 of 5)
```

**Option B: Determinate Bar with Percentage (Phase B)**
```
Downloading Parakeet...
[████████░░] 60%
Status: Downloading Encoder (3 of 5 files)
```

### Implementation Notes

- Use `NSProgressIndicator` with `isIndeterminate = false` for Option B
- Set `minValue = 0.0` and `maxValue = 100.0`
- Update `doubleValue` as progress updates
- Use `observedProgress` property to bind to `Progress` object

---

## 7. Summary of Controls by Use Case

| Use Case | Control | Apple Class | Notes |
|----------|---------|-------------|-------|
| Whisper model selection | Dropdown | NSPopUpButton | Dynamic item management |
| Parakeet model display | Label | NSTextField | Read-only, fixed model |
| Engine loading feedback | Spinner | NSProgressIndicator | Indeterminate style |
| Download confirmation | Dialog | NSAlert | Sheet modal preferred |
| Status messaging | Label | NSTextField | Semantic colors |
| Download progress | Progress bar | NSProgressIndicator | Determinate for Phase B |

---

## 8. Accessibility Considerations

From Apple documentation best practices:

1. **Always provide meaningful labels** - Use `accessibilityLabel` for controls
2. **Progress indicator animation** - Announce when loading completes
3. **Alert accessibility** - NSAlert automatically handles focus for dialogs
4. **Color alone isn't enough** - Combine status colors with text labels
5. **Keep controls keyboard navigable** - Default for AppKit controls

---

## 9. Implementation Priority

### Phase A (Quick Win - Recommended First)
1. ✅ Hide model dropdown when Parakeet selected (already in spec)
2. ✅ Show fixed "Parakeet TDT 0.6B" label instead
3. ✅ Add loading indicator with status text
4. ✅ Wire up state notifications

**Apple Controls Used:** NSTextField, NSProgressIndicator, NSPopUpButton

### Phase B (Full Download Parity)
1. Show download confirmation dialog before Parakeet download
2. Implement progress tracking with determinate progress bar
3. Update menu bar status during download
4. Show verification state

**Additional Apple Controls:** NSAlert (sheet modal), NSProgressIndicator (determinate)

---

## References

- [NSPopUpButton Documentation](https://developer.apple.com/documentation/appkit/nspopupbutton)
- [NSProgressIndicator Documentation](https://developer.apple.com/documentation/appkit/nsprogressindicator)
- [NSAlert Documentation](https://developer.apple.com/documentation/appkit/nsalert)
- [NSTextField Documentation](https://developer.apple.com/documentation/appkit/nstextfield)
- [NSControl Documentation](https://developer.apple.com/documentation/appkit/nscontrol)

---

**Document Status:** ✅ Complete
**Last Updated:** 2025-12-14
**Applicable Story:** S.01.4 Model Selection UX & Download Experience
