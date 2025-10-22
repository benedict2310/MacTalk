# MacTalk Accessibility Guide

**Version:** 1.0
**Last Updated:** 2025-10-22
**Target:** Phase 5 - Accessibility & Localization

---

## Overview

MacTalk is designed to be accessible to all users, including those using assistive technologies like VoiceOver. This document outlines our accessibility features, testing procedures, and guidelines.

---

## Accessibility Features

### VoiceOver Support

All major UI elements have proper accessibility labels, roles, and help text:

#### HUD Window
- **Label:** "MacTalk HUD"
- **Role:** Window
- **Help:** "Live transcription overlay showing partial transcripts and audio levels"

**Elements:**
- Live Transcript (Static Text): Shows current transcription
- Audio Level Meters (Level Indicator): Displays mic and app audio levels

#### Settings Window
- **Label:** "MacTalk Settings"
- **Role:** Window
- **Help:** "Configure MacTalk preferences and options"

**Tabs:**
- General: Application preferences
- Output: Transcript handling options
- Audio: Audio capture settings
- Advanced: Model and language configuration
- Permissions: System permission status

#### Menu Bar
- All menu items have descriptive titles
- Keyboard shortcuts displayed
- Submenus clearly labeled

### Keyboard Navigation

**Global Hotkeys:**
- `Cmd+Shift+Space`: Start/Stop recording (customizable)

**Window Navigation:**
- `Cmd+,`: Open Settings
- `Tab`: Navigate between fields
- `Space`: Toggle checkboxes
- `Enter`: Activate buttons
- `Esc`: Close windows

### Text Alternatives

- All icons have text descriptions
- Status indicators have accessible labels
- Error messages are screen reader friendly

---

## Testing with VoiceOver

### Enable VoiceOver

```bash
# Enable VoiceOver
sudo defaults write com.apple.Accessibility voiceOverOnOffKey -bool true

# Or: System Settings → Accessibility → VoiceOver → Enable
```

**Quick Toggle:** `Cmd+F5` or triple-press Touch ID

### Testing Checklist

#### Basic Navigation

- [ ] **Menu Bar**
  - [ ] VoiceOver announces "MacTalk menu"
  - [ ] All menu items readable
  - [ ] Submenus navigable
  - [ ] Keyboard shortcuts announced

- [ ] **HUD Window**
  - [ ] Window title announced
  - [ ] Live transcript text readable
  - [ ] Level meters status announced
  - [ ] Can close with keyboard

- [ ] **Settings Window**
  - [ ] Window title announced
  - [ ] Tab navigation works
  - [ ] All settings readable
  - [ ] Checkboxes/sliders accessible
  - [ ] Changes announced

#### Workflow Testing

- [ ] **Start Recording (Mode A)**
  1. Press `Cmd+Shift+Space`
  2. VoiceOver announces "Recording started"
  3. HUD appears and is announced
  4. Transcript updates are announced
  5. Press `Cmd+Shift+Space` again
  6. "Recording stopped" announced

- [ ] **Open Settings**
  1. Press `Cmd+,`
  2. Settings window announced
  3. Tab through all settings
  4. Make changes
  5. Close with `Esc`

- [ ] **Change Model**
  1. Open menu bar
  2. Navigate to "Model" submenu
  3. Select different model
  4. Selection confirmed

#### Advanced Testing

- [ ] **App Picker (Mode B)**
  - [ ] Window title announced
  - [ ] Table of apps readable
  - [ ] Search field accessible
  - [ ] Selection announced

- [ ] **Permission Dialogs**
  - [ ] Permission requests clear
  - [ ] Buttons accessible
  - [ ] Status updates announced

- [ ] **Error States**
  - [ ] Error messages readable
  - [ ] Recovery actions clear

---

## Accessibility Testing Tools

### Built-in Tools

#### Accessibility Inspector

```bash
# Open Accessibility Inspector
open /Applications/Xcode.app/Contents/Applications/Accessibility\ Inspector.app
```

**Features:**
- Inspect accessibility hierarchy
- Audit accessibility issues
- Test VoiceOver behavior

**Usage:**
1. Target MacTalk.app
2. Run Audit
3. Review warnings and errors
4. Fix issues

#### Accessibility Keyboard

System Settings → Accessibility → Keyboard → Accessibility Keyboard

Test all functionality without mouse.

### Third-Party Tools

- **VoiceOver Utility:** Fine-tune VoiceOver settings
- **Keyboard Maestro:** Test complex keyboard workflows
- **AccessibilityKit:** Programmatic testing (for automated tests)

---

## Implementation Guidelines

### Adding Accessibility to New UI Elements

```swift
// Set accessibility label
element.setAccessibilityLabel("Brief description")

// Set role
element.setAccessibilityRole(.button)  // or .staticText, .checkbox, etc.

// Set help text
element.setAccessibilityHelp("Detailed explanation of what this does")

// Set identifier (for automated testing)
element.setAccessibilityIdentifier("unique.identifier")

// Custom accessibility
element.setAccessibilityValue("Current value")  // For sliders, progress bars
element.setAccessibilityEnabled(true)  // Enable/disable
```

### Keyboard Navigation

```swift
// Set tab order
window.initialFirstResponder = firstField
field1.nextKeyView = field2
field2.nextKeyView = field3

// Handle keyboard shortcuts
override func keyDown(with event: NSEvent) {
    switch event.charactersIgnoringModifiers {
    case " ":  // Space
        toggleAction()
    case "\r": // Enter
        confirmAction()
    case "\u{1b}": // Escape
        cancelAction()
    default:
        super.keyDown(with: event)
    }
}
```

### Announcements

```swift
// Announce changes to screen readers
NSAccessibility.post(
    element: element,
    notification: .announcementRequested
)

// Announce value changes
element.setAccessibilityValue(newValue)
NSAccessibility.post(
    element: element,
    notification: .valueChanged
)
```

---

## Common Issues & Solutions

### Issue: VoiceOver doesn't read element

**Solutions:**
1. Check `setAccessibilityLabel()` is set
2. Verify element is in accessibility hierarchy
3. Check `setAccessibilityEnabled(true)`

### Issue: Tab navigation skips elements

**Solutions:**
1. Set `nextKeyView` chain
2. Check `canBecomeKeyView` returns true
3. Verify element is not hidden

### Issue: Announcements not working

**Solutions:**
1. Use correct notification type
2. Ensure element is in view hierarchy
3. Check VoiceOver is enabled

---

## Localization Prep

MacTalk is prepared for localization with:

### String Externalization

All user-facing strings use `NSLocalizedString`:

```swift
// ✅ Good
let title = NSLocalizedString("recording.start",
                               comment: "Button to start recording")

// ❌ Bad
let title = "Start Recording"
```

### Supported Languages (Future)

Planned for v1.1+:
- English (en) - Default
- Spanish (es)
- French (fr)
- German (de)
- Japanese (ja)
- Chinese Simplified (zh-Hans)

### Localization Testing

```bash
# Export strings
genstrings -o en.lproj *.swift

# Verify strings
plutil -lint en.lproj/Localizable.strings

# Test pseudo-localization
# Use Double-Length Strings to test layout
```

---

## Compliance

### Standards

MacTalk aims to comply with:
- **WCAG 2.1 Level AA:** Web Content Accessibility Guidelines
- **Section 508:** US Federal accessibility standards
- **EN 301 549:** European accessibility standard

### Key Requirements Met

✅ Keyboard accessible
✅ Screen reader support
✅ Sufficient color contrast
✅ Text alternatives for non-text content
✅ Clear focus indicators
✅ Error identification and suggestions

---

## Resources

### Apple Documentation

- [Accessibility Programming Guide](https://developer.apple.com/library/archive/documentation/Accessibility/Conceptual/AccessibilityMacOSX/)
- [VoiceOver Testing Guide](https://developer.apple.com/documentation/accessibility/voiceover)
- [Accessibility Inspector](https://developer.apple.com/library/archive/documentation/Accessibility/Conceptual/AccessibilityMacOSX/OSXAXTestingApps.html)

### External Resources

- [WebAIM: VoiceOver Testing](https://webaim.org/articles/voiceover/)
- [A11Y Project](https://www.a11yproject.com/)
- [Inclusive Design Principles](https://inclusivedesignprinciples.org/)

---

## Feedback

If you encounter accessibility issues, please report them:

- GitHub Issues: Tag with `accessibility` label
- Email: accessibility@mactalk.app
- Include: VoiceOver version, macOS version, steps to reproduce

---

**Document Version:** 1.0
**Last Updated:** 2025-10-22
**Next Review:** After accessibility audit
