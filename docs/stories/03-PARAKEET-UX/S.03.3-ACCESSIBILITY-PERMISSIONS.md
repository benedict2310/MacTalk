# S.03.3 - Accessibility Permissions & Auto-Insert Infrastructure

**Epic:** Real-Time Streaming Transcription
**Status:** Ready
**Date:** 2025-12-23
**Dependency:** None (foundational)
**Priority:** Critical
**Blocks:** S.03.1f (Paste Safety)

---

## 1. Summary

Make Accessibility permissions reliable and observable in-app (no restart required) and introduce a robust auto-insert pipeline that uses AX SetValue first and falls back to Cmd+V. Provide diagnostics that explain common TCC/signing failures and ensure Settings shows real-time status.

---

## 2. Architecture Context & Reuse

### Existing Code to Reuse
- `MacTalk/MacTalk/Permissions.swift`
  - Current Accessibility checks/prompting live here; keep this as the public facade.
  - Screen recording uses `CGPreflightScreenCaptureAccess` + `CGRequestScreenCaptureAccess` (do not change).
- `MacTalk/MacTalk/ClipboardManager.swift`
  - Contains Cmd+V simulation; reuse this for fallback rather than re-implementing.
- `MacTalk/MacTalk/StatusBarController.swift`
  - Auto-paste is triggered in `onFinal`; wire the new insert path here.
- `MacTalk/MacTalk/SettingsWindowController.swift`
  - Permissions tab exists but status labels are static. Follow its AppKit layout style.
- `MacTalk/MacTalkTests/PermissionsTests.swift`
  - Extend these tests instead of creating parallel test files where possible.

### Constraints & Conventions
- Swift 6 strict concurrency: `@MainActor` for UI/NSPasteboard, `actor` for shared state.
- Explicit `self` is intentional; do not remove.
- 4-space indentation.
- No new dependencies or tooling without confirmation.
- App is NOT sandboxed; do not add entitlements or sandbox changes.

---

## 3. Goals & Non-Goals

### Goals
- Accessibility permission check updates in-app without restart.
- Settings displays live status for Microphone/Screen Recording/Accessibility.
- Auto-insert uses AX SetValue first; fallback to Cmd+V if needed.
- Diagnostics surface signing/TCC problems (Xcode run, ad-hoc signing, Team ID).
- Deep-link to System Settings > Privacy & Security > Accessibility.

### Non-Goals
- Do not change screen recording behavior or permissions flow.
- Do not add new persistence layers or settings storage.
- Do not alter the global auto-paste trigger location (`StatusBarController.onFinal`).

---

## 4. Implementation Plan

### Step 1: Add `PermissionsActor` (Thread-Safe Permission Core)
**File:** `MacTalk/MacTalk/Utilities/PermissionsActor.swift`

Create an actor that owns polling and diagnostics. Keep `Permissions` as the synchronous API surface.

Key requirements:
- `nonisolated func isAccessibilityTrusted() -> Bool` uses `AXIsProcessTrusted()`.
- `nonisolated func requestAccessibility(showPrompt: Bool) -> Bool` uses `AXIsProcessTrustedWithOptions`.
  - Use `kAXTrustedCheckOptionPrompt.takeUnretainedValue()` (not `takeRetainedValue()`).
- `startPollingForGrant(timeout:pollInterval:onGranted:onTimeout:)` using `Task.sleep`.
  - Poll every 0.5s; stop on grant or timeout.
  - Store and cancel poll task.
- `getDiagnostics()` returns a `PermissionDiagnostics` struct with:
  - `bundleIdentifier`, `teamIdentifier`, `isAdHocSigned`, `isRunningFromXcode`, `executablePath`, `isAccessibilityTrusted`.
  - Use `Security` APIs with official keys:
    - `kSecCodeInfoTeamIdentifier` for Team ID
    - `kSecCodeInfoFlags` + `kSecCodeSignatureAdhoc` to detect ad-hoc signing
  - `isRunningFromXcode` should check bundle path for `DerivedData` or `Xcode`.

### Step 2: Update `Permissions.swift` to Use Actor
**File:** `MacTalk/MacTalk/Permissions.swift`

- Keep public methods but route through `PermissionsActor.shared`.
- Fix the current prompt option to use `takeUnretainedValue()`.
- Add new helper:
  - `static func getAccessibilityDiagnostics() -> PermissionDiagnostics`
- Keep screen recording helpers unchanged.

### Step 3: Add Auto-Insert Path (AX SetValue + Cmd+V)
**Option A (preferred):** Add `AutoInsertManager` for clarity.
**File:** `MacTalk/MacTalk/Utilities/AutoInsertManager.swift`

Behavior:
- `insertText(_:)` checks Accessibility trust via actor.
- Try AX SetValue:
  - Get focused element via `AXUIElementCreateSystemWide` + `kAXFocusedUIElementAttribute`.
  - Verify `kAXValueAttribute` is settable via `AXUIElementIsAttributeSettable`.
  - Call `AXUIElementSetAttributeValue`.
- If AX SetValue fails, call existing `ClipboardManager.sendCommandV` path (do not duplicate CGEvent code).

**Option B (acceptable):** Extend `ClipboardManager` with AX-first insert method, but keep existing Cmd+V helper and avoid duplicated event logic.

### Step 4: Wire Auto-Insert into `StatusBarController`
**File:** `MacTalk/MacTalk/StatusBarController.swift`

- In `onFinal`, keep clipboard copy first.
- If auto-paste is enabled, call the new auto-insert method and log which method succeeded.
- If permission is denied, trigger the permission request flow and show a notification.

### Step 5: Fix Settings Permission Status UI
**File:** `MacTalk/MacTalk/SettingsWindowController.swift`

- Store permission status labels as properties (not locals).
- Add `refreshPermissionStatus()`:
  - Accessibility: `Permissions.isAccessibilityTrusted()` (updates immediately).
  - Microphone: `AVCaptureDevice.authorizationStatus`.
  - Screen Recording: use existing `Permissions.checkScreenRecordingPermission()`.
- Call `refreshPermissionStatus()`:
  - After creating the permissions tab.
  - When the Settings window becomes key (subscribe to `NSWindow.didBecomeKeyNotification`).
  - Add a “Refresh” button that calls `refreshPermissionStatus()`.
- Add an “Open Accessibility Settings” button and a “Diagnostics…” button:
  - Diagnostics should show `PermissionDiagnostics.formattedReport` and allow copying to clipboard.

### Step 6: Optional Permission Sheet (Only If Useful)
**File:** `MacTalk/MacTalk/UI/AccessibilityPermissionSheet.swift`

- Only show when a parent window is available.
- Start polling via `PermissionsActor` while the sheet is visible.
- Dismiss automatically on grant; stop polling on dismiss.
- If no window is available, fall back to the existing alert + deep-link flow.

---

## 5. File Touch List

### New Files
- `MacTalk/MacTalk/Utilities/PermissionsActor.swift` — actor for polling + diagnostics.
- `MacTalk/MacTalk/Utilities/AutoInsertManager.swift` — AX SetValue + Cmd+V fallback.
- `MacTalk/MacTalk/UI/AccessibilityPermissionSheet.swift` — optional sheet for permission flow.

### Modified Files
- `MacTalk/MacTalk/Permissions.swift` — route to actor, fix prompt option, diagnostics helper.
- `MacTalk/MacTalk/ClipboardManager.swift` — integrate AX insertion or delegate to AutoInsertManager.
- `MacTalk/MacTalk/StatusBarController.swift` — use new insert flow in `onFinal`.
- `MacTalk/MacTalk/SettingsWindowController.swift` — live permission status UI and diagnostics.
- `MacTalk/MacTalkTests/PermissionsTests.swift` — extend tests for diagnostics and actor APIs.
- `docs/testing/TESTING.md` — document signed-bundle testing + `tccutil reset`.

---

## 6. Acceptance Criteria

### Permission Checking
- [ ] Accessibility check uses `AXIsProcessTrustedWithOptions` with prompt option.
- [ ] Permission status updates without restart (poll detects grant within 500ms).
- [ ] Settings shows real-time status for Mic/Screen Recording/Accessibility.
- [ ] “Open Accessibility Settings” deep-link works.

### Auto-Insert Behavior
- [ ] AX SetValue is attempted first; Cmd+V is fallback.
- [ ] Cmd+V uses existing event logic (no duplicated CGEvent code).
- [ ] Auto-insert gated by permission check; clipboard is always updated.

### Diagnostics & UX
- [ ] Diagnostics show bundle ID, Team ID, ad-hoc signing, Xcode-run detection.
- [ ] UI exposes diagnostics via Settings (alert or copy-to-clipboard).
- [ ] “Re-authorize” flow documented (`tccutil reset`).

### Development Workflow
- [ ] Docs clearly state permission testing must use signed app bundle (not Xcode).
- [ ] `tccutil reset Accessibility com.mactalk.app` instructions included.

---

## 7. Tests and Validation

### Unit Tests
- Extend `MacTalk/MacTalkTests/PermissionsTests.swift`:
  - Diagnostics fields are non-empty.
  - `isAccessibilityTrusted()` returns consistently across repeated calls.
  - `requestAccessibility(showPrompt: false)` returns without blocking.

### Manual Tests
1. `tccutil reset Accessibility com.mactalk.app`
2. `./build.sh run`
3. Enable auto-paste and verify prompt appears.
4. Grant Accessibility permission; verify Settings updates within 0.5s.
5. Confirm auto-insert works without restart.

---

## 8. Risks and Open Questions

- Should diagnostics be shown as an NSAlert or a small sheet? (Prefer alert unless a parent window exists.)
- AX SetValue may fail for non-text controls; ensure fallback to Cmd+V is logged.
- Polling must be stopped when UI closes to avoid background tasks.
- Existing `NSUserNotification` usage is deprecated but consistent with current app; keep for now.

---

## 9. Code Review Findings (2025-02-14)

### High
- **CR-01: AX “insert” will replace full field content.** `AXUIElementSetAttributeValue` on `kAXValueAttribute` overwrites the entire value, which breaks “insert at cursor” semantics and can wipe existing text. Define insertion behavior explicitly by reading `kAXValueAttribute` + `kAXSelectedTextRangeAttribute`, performing a range replace, and writing the new value; if a selection range is unavailable, treat it as unsupported and fall back to Cmd+V. **Location:** Section 4, Step 3 (Auto-Insert Path).
- **CR-02: Focused element may not be an editable text field.** The plan only checks `AXUIElementIsAttributeSettable` for `kAXValueAttribute`, which is insufficient for complex apps (web views, chat apps, secure fields). Require role/editability checks (`kAXRoleAttribute`, `kAXEditableAttribute`, or `kAXTextArea/AXTextField`) and treat any mismatch as a hard failure that triggers the Cmd+V fallback. **Location:** Section 4, Step 3 (Auto-Insert Path).

### Medium
- **CR-03: Permission prompt/notification can loop in `onFinal`.** If permission is denied and auto-insert triggers on every transcription, the current plan will repeatedly prompt and notify. Add a per-session throttle or explicit user-initiated re-prompt flow to avoid spam. **Location:** Section 4, Step 4 (Wire Auto-Insert).
- **CR-04: Polling callbacks are not constrained to the main actor.** `onGranted`/`onTimeout` are likely to update UI; the story does not require dispatching back to `MainActor`. Add a requirement that all UI updates from polling are wrapped in `await MainActor.run { ... }`. **Location:** Section 4, Step 1 (PermissionsActor) and Step 6 (Permission Sheet).
- **CR-05: Test expectations are too strict for signed/debug environments.** “Diagnostics fields are non-empty” will fail under ad-hoc signing, unit test hosts, or Xcode-run bundles (Team ID may be nil). Update tests to assert presence where applicable and allow nil/empty values with explicit reasons. **Location:** Section 7 (Unit Tests).

### Low
- **CR-06: Xcode-run detection is a brittle heuristic.** Checking the bundle path for `DerivedData` or `Xcode` can yield false positives/negatives; mark this as a heuristic in diagnostics and avoid using it as a hard decision gate. **Location:** Section 4, Step 1 (Diagnostics).
- **CR-07: Polling timeout uses `Task.sleep` without clock semantics.** A time-change or cancellation should be handled explicitly; prefer a `ContinuousClock` loop with cancellation checks to avoid unexpected delays. **Location:** Section 4, Step 1 (Polling).

## 10. Debug Logging

### AutoInsertManager Logging

When auto-paste is triggered, `AutoInsertManager` logs detailed diagnostic information to help troubleshoot permission issues:

```
[AutoInsertManager] insertText called with <N> characters
[AutoInsertManager] AXIsProcessTrusted() returned: true/false
[AutoInsertManager] Bundle ID: com.mactalk.app
[AutoInsertManager] Team ID: 9SXL4GJ4TZ (or "(none)" if ad-hoc)
[AutoInsertManager] Ad-hoc signed: true/false
[AutoInsertManager] Running from Xcode: true/false
```

If AX insertion is attempted:
```
[AutoInsertManager] Element role 'AXTextField' is a text input type
[AutoInsertManager] Selection range: location=5, length=0
[AutoInsertManager] AX insert at selection succeeded
```

Or on fallback:
```
[AutoInsertManager] Focused element is not an editable text field
[AutoInsertManager] AX insert at selection not supported, falling back to Cmd+V
```

### StatusBarController Logging

Permission prompt throttling is logged:
```
[StatusBar] Permission prompt throttled (last prompt 15s ago)
```

### Viewing Logs

1. Open **Console.app**
2. Filter by process "MacTalk" or message containing "AutoInsertManager"
3. Trigger auto-paste to see diagnostic output

### Troubleshooting with Logs

| Log Message | Meaning | Fix |
|:--|:--|:--|
| `AXIsProcessTrusted() returned: false` | TCC denies permission | Reset with `tccutil reset Accessibility com.mactalk.app` and re-grant |
| `Team ID: (none)` | Ad-hoc signed build | Use release build with stable Team ID |
| `Running from Xcode: true` | DerivedData path detected | Run via `./build.sh run` instead |
| `Element role '...' is not a text input type` | Focused element isn't a text field | AX insert not possible; Cmd+V fallback used |
| `Could not get selected text range` | App doesn't expose selection | AX insert not possible; Cmd+V fallback used |

---

## 11. TCC Permission Persistence (CDHash Issue)

### Root Cause

macOS TCC (Transparency, Consent, and Control) tracks Accessibility permissions by **bundle ID + CDHash** (code directory hash). The CDHash is a cryptographic hash of the executable's code signature. When the app is rebuilt:

1. The code changes, producing a new CDHash
2. TCC sees this as a "different" app
3. The old permission grant (with the old CDHash) no longer applies
4. `AXIsProcessTrusted()` returns `false` even though System Settings shows the toggle "on"

This is why permissions seem to "disappear" after rebuilding, even with stable Team ID signing.

### Build Script Usage

| Command | When to Use |
|:--|:--|
| `./build.sh` | Build only, don't launch |
| `./build.sh run` | Build and launch (kills old instance first) |
| `./build.sh clean` | Start fresh (removes DerivedData) |
| `./build.sh reset-perms` | After rebuild when auto-paste stops working |

### Common Workflows

**Normal development (no auto-paste changes):**
```bash
./build.sh run
```

**After code changes that affect auto-paste, or when permission prompt keeps appearing:**
```bash
./build.sh reset-perms
./build.sh run
# Grant permission when prompted
```

**Fresh start (new clone, weird build issues):**
```bash
./build.sh clean
./build.sh reset-perms
./build.sh run
```

### Why `reset-perms` is Needed

TCC tracks permissions by CDHash. Every rebuild produces a new CDHash, so:
- Old permission grant → doesn't apply to new build
- System Settings shows toggle "on" → but for the OLD build
- `reset-perms` clears the stale entry → next grant applies to current build

**Tip**: The 30-second prompt throttle prevents spam if you forget to reset.

---

## 12. Reference Notes

- Deep-link URL (macOS 13+): `x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility`
- Deep-link URL (legacy): `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`
- TCC uses bundle ID + code signature; stable Team ID is required (already set in `project.yml`).
