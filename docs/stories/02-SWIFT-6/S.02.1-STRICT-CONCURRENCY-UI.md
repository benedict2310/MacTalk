# S.02.1 - Strict Concurrency (UI & Settings)

**Epic:** Swift 6 Migration
**Status:** Complete ✅
**Date:** 2025-10-27
**Last Updated:** 2025-12-15
**Completed:** 2025-12-15
**Dependencies:** S.02.0 (strategy), S.02.1a (Utilities) ✅

---

## 1. Objective
Keep strict concurrency enabled (`-strict-concurrency=complete`) and finish isolating all UI-touching code on the Main Actor, leveraging the newly actorized utilities from S.02.1a.

---

## 2. Current Baseline (post S.02.1a)
- Build config already sets `SWIFT_STRICT_CONCURRENCY: complete` in `project.yml`.
- Utilities are now actor-safe: `ModelManager` @MainActor, `ModelDownloader` main-actor callbacks, `PerformanceMonitor` actor, `ClipboardManager` @MainActor, `DebugLogger` @unchecked Sendable.
- Already @MainActor UI classes: `AppDelegate`, `StatusBarController`, `HUDWindowController`, `AppPickerWindowController`, `AudioLevelMeterView` (+ `DualChannelLevelMeterView`), `AudioWaveView`, `ShortcutRecorderView`.
- Still non-isolated / warning-prone:
  - `SettingsWindowController`: pure AppKit code with notification posts and shortcut callbacks; not marked `@MainActor`.
  - `TranscriptionController`: six UI callbacks are plain, non-`@Sendable` closures invoked from audio threads.
  - `HotkeyManager`: `HotkeyHandler` not main-actor bound; Carbon callback executes handler directly.
  - `Permissions`: completion-based helpers and alerts lack actor isolation.
  - `StatusBarController`: already @MainActor but still uses `DispatchQueue.main.async` for model download progress and HUD callbacks; NotificationCenter observers do not specify `queue: .main`.

---

## 3. Implementation Summary

### All Items Complete
- `SettingsWindowController` is `@MainActor` with main-actor shortcut callbacks.
- `ShortcutRecorderView.onShortcutChanged` callback typed `@Sendable @MainActor`.
- `TranscriptionController` UI callbacks (`onPartial`, `onFinal`, `onMicLevel`, `onAppLevel`) typed `@Sendable @MainActor` and marshalled via `Task { @MainActor ... }` from audio threads.
- `HotkeyManager.HotkeyHandler` is `@MainActor @Sendable`; Carbon events hop onto the main actor via `Task`.
- `Permissions` UI helpers (`showAccessibilityAlert`, `showPermissionAlert`, `ensureScreenRecordingGuide`, etc.) are `@MainActor`; permission completions delivered on the main actor.
- `ModelManager.onDownloadState` callback type marked `@MainActor @Sendable` (from S.02.1a).
- `StatusBarController` uses `ModelManager` callback directly (no redundant dispatch needed since both are `@MainActor`).
- NotificationCenter observers specify `queue: .main` for main-thread delivery.
- `DispatchQueue.main.asyncAfter` calls retained for timer functionality (auto-hide messages).

---

## 4. Acceptance Criteria
- [x] `SWIFT_STRICT_CONCURRENCY=complete` is set.
- [x] Core UI controllers and views (AppDelegate, StatusBarController, HUD, AppPicker, ShortcutRecorder, audio meters/wave) are @MainActor.
- [x] `SettingsWindowController` is @MainActor with main-actor shortcut callbacks; notification posts are main-thread.
- [x] `TranscriptionController` UI callbacks are `@Sendable @MainActor` and invoked from background work via `Task { @MainActor ... }`.
- [x] `HotkeyManager` and permission APIs deliver handlers on the main actor.
- [x] Build succeeds; remaining warnings are in audio/whisper layer (separate story S.02.2).

---

## 5. Resolved Gaps (Previously Identified)

All gaps from the original assessment have been addressed:

- ✅ `SettingsWindowController.swift`: Now `@MainActor`; shortcut callbacks properly typed.
- ✅ `TranscriptionController.swift`: Callbacks typed `@Sendable @MainActor`; audio threads use `Task { @MainActor ... }` for UI updates.
- ✅ `HotkeyManager.swift`: `HotkeyHandler` is `@MainActor @Sendable`; Carbon callbacks hop to main actor via `Task`.
- ✅ `Permissions.swift`: Alert helpers and System Settings openers are `@MainActor`; completions delivered on main actor.
- ✅ `StatusBarController.swift`: Uses `@MainActor` callbacks directly from `ModelManager`; NotificationCenter observers specify `queue: .main`.

---

## 6. Migration Sequence (updated)
1. Annotate `SettingsWindowController` and update shortcut callback types; verify alert flows.
2. Update `TranscriptionController` callback signatures and invocations; simplify HUD/menu callbacks in `StatusBarController`.
3. Fix `HotkeyManager` and `Permissions` actor boundaries; ensure Carbon callbacks hop to main.
4. Sweep `StatusBarController` for redundant main-queue dispatch and add `.main` queues for observers.
5. Rebuild with strict concurrency + run UI tests and smoke manual flows.

---

## 7. Testing Notes
- Build with `xcodebuild -project MacTalk.xcodeproj -scheme MacTalk -configuration Release` to surface strict-concurrency warnings.
- Focused tests: HUD/StatusBar/Settings, TranscriptionController callback tests; enable Main Thread Checker + Thread Sanitizer when running UI flows.
- Manual checks: start/stop recording in both modes, download model UI, shortcut registration, permissions sheet.

---

## 8. Risk Assessment
- **TranscriptionController callbacks (High):** Background audio queues crossing into @MainActor StatusBarController; improper annotation will keep warnings alive.
- **SettingsWindowController (Medium):** Large file; need to ensure bindings and notifications remain functional after actorization.
- **Hotkey/Permissions (Medium):** System callbacks arrive off-main; missing hops will trigger main-thread checker once strict mode enforced.
- **StatusBarController cleanup (Low/Medium):** Redundant dispatch removal should be safe but needs regression checks for model download UI.

---

## 9. Completion Notes

All UI concurrency work for this story is complete. The following stories continue the Swift 6 migration:

- **S.02.1a** ✅ - Utilities & Singleton Concurrency (complete)
- **S.02.1** ✅ - Strict Concurrency UI & Settings (this story - complete)
- **S.02.2** - Audio Pipeline Concurrency (pending)
- **S.02.3** - Whisper Engine Concurrency (pending)
