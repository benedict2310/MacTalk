# MacTalk Known Issues

**Last Updated:** 2025-10-26
**Version:** v1.0-alpha

---

## Overview

This document tracks known bugs and limitations in MacTalk that are pending fixes. Issues are prioritized by severity and impact on user experience.

**Priority Levels:**
- **P0 (Critical):** Blocks core functionality, must fix before release
- **P1 (High):** Major feature broken or degraded, fix soon
- **P2 (Medium):** Minor feature issue or workaround available
- **P3 (Low):** Cosmetic or edge case, fix when convenient

---

## Active Issues

### P1: Keyboard Shortcuts Shown But Don't Work
**Status:** Open
**Priority:** P1 (High)
**Discovered:** 2025-10-26
**Affects:** All users

**Description:**
The menu bar displays keyboard shortcuts (e.g., "⌘R" for Start Recording), but pressing these shortcuts does not trigger the corresponding actions.

**Steps to Reproduce:**
1. Click menu bar icon
2. Observe shortcuts shown in menu (e.g., "Start Recording ⌘R")
3. Close menu
4. Press ⌘R
5. Nothing happens - recording does not start

**Expected Behavior:**
Pressing ⌘R should start recording, matching the displayed shortcut.

**Current Workaround:**
Use the menu bar dropdown to manually click "Start Recording".

**Root Cause:**
Keyboard shortcuts are displayed in NSMenu but not actually registered with NSApplication or as global hotkeys. The HotkeyManager is implemented but not connected to menu items.

**Proposed Fix:**
1. Register menu item keyboard equivalents with NSApplication
2. OR: Use HotkeyManager for global hotkeys and update menu display
3. Ensure shortcuts work even when app is not frontmost (use global hotkeys)

**Files to Modify:**
- `StatusBarController.swift` - Connect menu items to HotkeyManager
- `HotkeyManager.swift` - Register shortcuts for menu actions

---

### P1: Recordings Appear Duplicated on Paste
**Status:** Open
**Priority:** P1 (High)
**Discovered:** 2025-10-26
**Affects:** Users with auto-paste enabled

**Description:**
When recording and auto-pasting transcriptions, the text appears duplicated (e.g., "test" becomes "test test").

**Steps to Reproduce:**
1. Enable auto-paste in Settings
2. Start recording
3. Say "test"
4. Stop recording
5. Observe pasted text - shows "test test" instead of "test"

**Expected Behavior:**
Pasted text should appear once only.

**Current Workaround:**
Disable auto-paste and manually paste from clipboard (⌘V).

**Root Cause (Hypothesis):**
1. Streaming transcription may be calling auto-paste multiple times
2. OR: Final transcript includes accumulated partial results
3. OR: ClipboardManager.autoPaste() is being called twice

**Proposed Fix:**
1. Review TranscriptionController callback flow
2. Ensure onFinalTranscript only triggers once
3. Add deduplication logic in ClipboardManager
4. Add test to verify single paste per recording

**Files to Investigate:**
- `TranscriptionController.swift` - Check callback flow
- `ClipboardManager.swift` - Review autoPaste() implementation
- `StatusBarController.swift` - Check action handlers

---

### P2: No Keyboard Shortcut to Stop Recording
**Status:** Open
**Priority:** P2 (Medium)
**Discovered:** 2025-10-26
**Affects:** All users

**Description:**
Users can start recording via keyboard shortcut (once P1 is fixed) but there's no shortcut to stop recording. Must use menu bar to stop.

**Steps to Reproduce:**
1. Start recording (via menu or future shortcut)
2. Try to stop recording with keyboard
3. No shortcut works - must click menu bar icon → "Stop Recording"

**Expected Behavior:**
Should be able to stop recording with same or different keyboard shortcut.

**Current Workaround:**
Click menu bar → "Stop Recording".

**Common Patterns:**
- **Push-to-talk:** Hold key to record, release to stop
- **Toggle:** Same key starts/stops
- **Separate keys:** Different keys for start and stop

**Proposed Fix:**
1. Add toggle behavior to HotkeyManager (same key starts/stops)
2. OR: Add separate stop hotkey
3. OR: Implement push-to-talk mode (hold to record)
4. Make configurable in Settings

**Files to Modify:**
- `HotkeyManager.swift` - Add toggle or separate stop shortcut
- `SettingsWindowController.swift` - Add hotkey configuration UI
- `StatusBarController.swift` - Update menu display

---

### P2: App Audio Selection Limited to First Window
**Status:** Open
**Priority:** P2 (Medium)
**Discovered:** 2025-10-26
**Affects:** Users using Mode B (Mic + App Audio)

**Description:**
When selecting an app for audio capture (e.g., Zoom), the system only captures audio from the first window. If the app has multiple windows or uses system audio, only the first window's audio is captured.

**Steps to Reproduce:**
1. Open app with multiple windows (e.g., Zoom with multiple calls)
2. Start Mode B recording
3. Select target app
4. Only first window's audio is captured

**Expected Behavior:**
Should be able to:
1. Select all windows from an app (combined audio)
2. OR: Choose specific window
3. OR: Capture all system audio

**Current Workaround:**
Ensure target app has only one active audio window.

**Root Cause:**
ScreenAudioCapture.swift uses `selectFirstWindow(named:)` which hardcodes selection of first window. ScreenCaptureKit can capture:
- Specific window audio
- All windows from an app
- System audio (all apps)

**Proposed Fix:**
1. Implement app picker UI (deferred from Phase 4)
2. Show list of all windows with audio capability
3. Add "All Windows" and "System Audio" options
4. Store user preference per app

**Files to Modify:**
- `ScreenAudioCapture.swift` - Add window selection API
- New file: `AppPickerWindowController.swift` - App/window picker UI
- `StatusBarController.swift` - Trigger picker before recording

---

## Fixed Issues (History)

### ✅ P0: Menu Bar Icon Not Appearing (macOS 26)
**Status:** Fixed (2025-10-26)
**Priority:** P0 (Critical)

**Description:**
App built successfully but menu bar icon never appeared. Process ran but no Swift code executed.

**Root Cause:**
1. Code signature Team ID mismatch between app and whisper.cpp dylibs
2. @main attribute not working with C++ bridging header
3. setActivationPolicy not called at right time

**Fix Applied:**
1. Automated dylib re-signing in post-build script (project.yml)
2. Replaced @main with explicit main.swift entry point
3. Set activation policy before creating status item
4. Added comprehensive debug logging

**Files Modified:**
- `main.swift` (new)
- `AppDelegate.swift` (removed @main)
- `StatusBarController.swift` (fixed status item creation)
- `project.yml` (post-build script)

**Verification:**
Menu bar icon now appears correctly. App launches successfully on macOS 26.

---

### ✅ P0: BLANK_AUDIO Transcription Errors
**Status:** Fixed (2025-10-26)
**Priority:** P0 (Critical)

**Description:**
whisper.cpp would return "[BLANK_AUDIO]" when processing recorded audio, even when user was speaking.

**Root Cause:**
Audio samples contained excessive silence or low-volume content being sent to whisper.cpp without filtering.

**Fix Applied:**
Implemented Voice Activity Detection (VAD) to filter silence before transcription.

**Files Modified:**
- Added VAD logic to audio processing pipeline

**Verification:**
Transcriptions now return actual speech instead of BLANK_AUDIO.

---

## Future Enhancements

These are not bugs but improvements to consider:

### Enhancement: Customizable Keyboard Shortcuts
Allow users to configure their own keyboard shortcuts in Settings window.

**Priority:** P3 (Low)
**Effort:** Medium
**Files:** SettingsWindowController.swift, HotkeyManager.swift

### Enhancement: Multi-Window App Audio
Allow selecting all windows from an app, not just one.

**Priority:** P2 (Medium)
**Effort:** High (requires new UI)
**Files:** AppPickerWindowController.swift (new), ScreenAudioCapture.swift

### Enhancement: Push-to-Talk Mode
Hold hotkey to record, release to stop and transcribe.

**Priority:** P3 (Low)
**Effort:** Low
**Files:** HotkeyManager.swift, TranscriptionController.swift

### Enhancement: Real-time Streaming Display
Show live partial transcripts in HUD as user speaks (currently only shows final).

**Priority:** P2 (Medium)
**Effort:** Low (infrastructure exists, just need to wire up)
**Files:** HUDWindowController.swift, StatusBarController.swift

---

## Reporting New Issues

If you discover a new issue:

1. **Check if it's already listed** in this document or GitHub Issues
2. **Gather information:**
   - macOS version (run `sw_vers`)
   - MacTalk version
   - Steps to reproduce
   - Expected vs actual behavior
   - Debug log (`/tmp/mactalk_debug.log`)
3. **File an issue** on GitHub or add to this document
4. **Include logs:**
   ```bash
   # Debug log
   cat /tmp/mactalk_debug.log

   # System log
   log show --predicate 'process == "MacTalk"' --last 5m
   ```

---

## Issue Triage Process

### P0 (Critical) - Fix Immediately
- App crashes on launch
- Core feature completely broken
- Data loss or security issue
- Blocks all users

### P1 (High) - Fix in Next Release
- Major feature degraded
- Impacts most users
- Workaround exists but awkward

### P2 (Medium) - Fix When Possible
- Minor feature issue
- Affects some users
- Easy workaround available

### P3 (Low) - Fix Eventually
- Cosmetic issue
- Edge case scenario
- Enhancement request

---

**Document Version Control:**
- v1.0 (2025-10-26): Initial known issues document
