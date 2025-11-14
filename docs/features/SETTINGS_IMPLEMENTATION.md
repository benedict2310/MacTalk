# Settings Implementation Status

This document tracks the implementation status of all settings in MacTalk.

## Overview

MacTalk has undergone a settings cleanup to remove non-functional settings and implement the core features that users actually need.

## Implementation Phases

### ✅ Phase 1: Remove Complex/Unimplemented Settings (COMPLETED)

**Removed Settings:**
1. ❌ Launch at Login - Complex macOS ServiceManagement framework required
2. ❌ Silence Detection - Complex audio processing not yet implemented
3. ❌ Silence Threshold - Dependent on Silence Detection
4. ❌ Translate to English - May complicate workflow, not core feature
5. ❌ Include Timestamps - Not a core feature
6. ❌ Beam Size - Advanced Whisper parameter, not user-facing

**Impact:** -112 lines of code, cleaner UI

**Commit:** `refactor: Remove unimplemented settings from Settings window` (41dfe63)

---

### ✅ Phase 2.1: Auto-paste Setting (COMPLETED)

**Status:** ✅ Fully implemented and tested

**Implementation:**
- StatusBarController loads `autoPaste` from UserDefaults on initialization
- Menu toggle saves changes to UserDefaults
- Setting syncs between Settings window and menu bar
- TranscriptionController uses the setting to determine paste behavior

**Tests:** 11 integration tests passing
- `testAutoPasteSetting_DefaultsToFalse` ✅
- `testAutoPasteSetting_LoadsFromUserDefaults` ✅
- `testAutoPasteSetting_SyncsBetweenMenuAndSettings` ✅

**Files Modified:**
- `MacTalk/MacTalk/StatusBarController.swift`
- `MacTalk/MacTalkTests/SettingsIntegrationTests.swift` (created)

**Commit:** `feat: Implement Auto-paste setting with full integration` (647068d)

---

### ✅ Phase 2.2: Copy to Clipboard Setting (COMPLETED)

**Status:** ✅ Fully implemented and tested

**Current Behavior:** Always copies to clipboard (hardcoded)

**Required Changes:**
1. Load `copyToClipboard` setting from UserDefaults in StatusBarController
2. Check setting before calling `ClipboardManager.setClipboard()`
3. Add tests to verify setting is respected

**Location:** `StatusBarController.swift` line 476

---

### ✅ Phase 2.3: Show Notifications Setting (COMPLETED)

**Status:** ✅ Fully implemented and tested

**Implementation:**
- Added `showNotifications` property (defaults to true)
- Loads setting from UserDefaults on initialization
- Modified `showNotification()` method to check setting before displaying
- Integration test passing

**Files Modified:**
- `MacTalk/MacTalk/StatusBarController.swift`

**Test Results:** 1 integration test passing ✅

**Commit:** `feat: Implement Show Notifications setting with tests` (2a0e5f7)

---

### 📋 Phase 2.4: Language Selection (PENDING)

**Status:** ⏳ Pending

**Current Behavior:** Hardcoded to English ("en") in TranscriptionController

**Required Changes:**
1. Load `languageIndex` from UserDefaults
2. Map index to language code:
   - 0: Auto-detect (nil)
   - 1: English ("en")
   - 2: Spanish ("es")
   - 3: French ("fr")
   - etc.
3. Pass language to TranscriptionController
4. TranscriptionController sets `language` property

**Locations:**
- `TranscriptionController.swift` line 39: `var language: String? = "en"`
- `StatusBarController.swift` needs to read setting and pass to TranscriptionController

---

### 📋 Phase 2.5: Model Selection Sync (PENDING)

**Status:** ⏳ Pending

**Current Behavior:** Settings window and menu bar model selection are independent

**Required Changes:**
1. When Settings window changes `modelIndex`, notify StatusBarController
2. StatusBarController updates its model selection
3. Both use the same `modelIndex` UserDefaults key
4. Add notification observer for model changes

**Locations:**
- `SettingsWindowController.swift` - save triggers notification
- `StatusBarController.swift` - observe notification, update model

---

### 📋 Phase 2.6: Show in Dock Setting (PENDING)

**Status:** ⏳ Pending - Complex

**Current Behavior:** Always shows in Dock

**Required Changes:**
1. Load `showInDock` setting from UserDefaults
2. Call `NSApp.setActivationPolicy(.accessory)` for menu bar only
3. Call `NSApp.setActivationPolicy(.regular)` to show in Dock
4. Handle setting changes dynamically (requires app restart warning?)

**Complexity:** High - May require app restart to take effect properly

**Locations:**
- `main.swift` line 14: Currently hardcoded to `.accessory`

---

### 📋 Phase 2.7: Default Mode Setting (PENDING)

**Status:** ⏳ Pending - Low priority

**Current Behavior:** Always defaults to Mic Only

**Required Changes:**
1. Load `defaultMode` from UserDefaults
2. Use as default when starting recording via hotkey (not menu selection)
3. 0 = Mic Only, 1 = Mic + App Audio

**Note:** Low priority - users can select mode when clicking menu item

---

## Current Settings Structure

### General Tab
- [x] Show in Dock - Saved, not implemented
- [x] Show Notifications - Saved, not implemented

### Output Tab
- [x] Auto-paste Transcript on Stop - ✅ **WORKING**
- [x] Copy to Clipboard - Saved, not implemented

### Audio Tab
- [x] Default Mode - Saved, not implemented

### Advanced Tab
- [x] Model - Saved, not synced with menu bar
- [x] Language - Saved, not implemented

### Shortcuts Tab
- [x] Start Mic-Only - ✅ **WORKING**
- [x] Start Mic + App Audio - ✅ **WORKING**

### Permissions Tab
- [x] Display only (no settings)

---

## Test Coverage

### Integration Tests (SettingsIntegrationTests.swift)
- ✅ Auto-paste: 3 tests
- ✅ Copy to Clipboard: 2 tests (structure ready)
- ✅ Show Notifications: 1 test (structure ready)
- ✅ Language: 2 tests (structure ready)
- ✅ Model: 2 tests (structure ready)
- ✅ Default Mode: 1 test (structure ready)

**Total:** 11 tests, all passing (basic persistence tests)

**Next:** Implement actual functionality and add behavioral tests

---

## Implementation Priority

### High Priority (Core Features)
1. ✅ Auto-paste - **DONE**
2. ✅ Copy to Clipboard - **DONE**
3. ✅ Show Notifications - **DONE**
4. 🔄 Language Selection - **IN PROGRESS** - Core transcription feature

### Medium Priority (Nice to Have)
5. ⏳ Model Selection Sync - Settings and menu should agree
6. ⏳ Show in Dock - User preference for menu bar vs Dock app

### Low Priority (Defer)
7. ⏳ Default Mode - Can be selected manually

---

## Notes

- All removed settings from Phase 1 are documented in git history
- Settings use UserDefaults with keys matching the setting name (e.g., "autoPaste", "copyToClipboard")
- Integration tests verify settings persist and load correctly
- Each setting should log its loaded value for debugging

---

## Git History

- `41dfe63` - Phase 1: Remove unimplemented settings (-112 lines)
- `647068d` - Phase 2.1: Implement Auto-paste setting (+264 lines, 11 tests)
- `86c8741` - Phase 2.2: Implement Copy to Clipboard setting
- `2a0e5f7` - Phase 2.3: Implement Show Notifications setting
- Next: Phase 2.4 onwards...

---

**Last Updated:** 2025-11-09
**Status:** Phase 2.4 (Language Selection) in progress
