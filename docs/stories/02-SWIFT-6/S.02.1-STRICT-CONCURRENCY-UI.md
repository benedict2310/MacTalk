# S.02.1 - Strict Concurrency (UI & Settings)

**Epic:** Swift 6 Migration
**Status:** Pending
**Date:** 2025-10-27

---

## 1. Objective
Enable Strict Concurrency checking and isolate the UI layer to the Main Actor.

**Goal:** Compile with `-strict-concurrency=complete` and resolve all UI-related warnings.

---

## 2. Implementation Plan

### Step 1: Build Settings
1.  Update `project.yml`: `SWIFT_STRICT_CONCURRENCY: complete`.
2.  Regenerate project and build to see the baseline warning count.

### Step 2: Main Actor Isolation
1.  Annotate all `NSWindowController` subclasses (`HUDWindowController`, `Settings...`) with `@MainActor`.
2.  Annotate `StatusBarController` with `@MainActor`.
3.  Fix call sites: Ensure background threads use `await MainActor.run { ... }` when updating UI.

### Step 3: Global State
1.  Review `Permissions.swift` and `HotkeyManager.swift`.
2.  If they touch UI (alerts, status bar), mark them `@MainActor` or isolate specific methods.

---

## 3. Acceptance Criteria
*   [ ] Build settings enable strict concurrency.
*   [ ] No warnings related to UI classes accessing main-thread properties from background.

---

## 4. Current State Audit

### UI Classes Inventory

#### Window Controllers
1. **HUDWindowController** (265 lines)
   - NSWindowController subclass
   - Manages floating bubble UI with animations
   - Properties: waveView, backgroundView, stopButton
   - Threading: All UI updates on main, CATransaction callbacks

2. **SettingsWindowController** (767 lines)
   - NSWindowController subclass with tabbed interface
   - Complex UI with 6 tabs, many controls
   - NotificationCenter observers (2): engineStatusDidChange, engineDownloadDidChange
   - Threading: Callback-heavy with async completion handlers

3. **AppPickerWindowController** (270 lines)
   - NSWindowController subclass
   - Table view with search and selection
   - Properties: allAudioSources, filteredSources (mutable state)
   - Threading: Main thread assumed

4. **StatusBarController** (1300 lines)
   - NOT an NSView/NSWindowController but manages NSStatusItem
   - Creates and manages HUDWindowController, SettingsWindowController
   - NotificationCenter observers (3): shortcutsDidChange, settingsDidChange, providerDidChange
   - Threading: Complex async/await code in prepareParakeetEngine, loadAudioSources
   - State management: engineState, isRecording with NSLock
   - Callbacks: onDownloadState, onSelection closures

#### Custom Views
5. **AudioLevelMeterView** (202 lines)
   - NSView subclass for level visualization
   - Properties: rmsLevel, peakLevel, peakHoldLevel (mutable)
   - Threading: update() called from background, dispatches to main

6. **AudioWaveView** (119 lines)
   - NSView subclass for wave animation
   - Properties: smoothedLevel, currentAudioLevel (mutable)
   - Threading: updateAudioLevel() called from callbacks, CALayer animations

7. **ShortcutRecorderView** (325 lines)
   - NSView subclass for keyboard shortcut capture
   - Properties: shortcut, isRecording, eventMonitor (mutable)
   - Threading: Event monitor runs on main, state changes from events

8. **DualChannelLevelMeterView** (287 lines)
   - NSView subclass containing two AudioLevelMeterView instances
   - Threading: Delegates to child meters

#### Supporting Classes
9. **TranscriptionController** (258 lines)
   - NOT a UI class but has UI callbacks
   - Closures: onPartial, onFinal, onMicLevel, onAppLevel, onAppAudioLost, onFallbackToMicOnly
   - Threading: Engine callbacks on background, dispatches to main for UI updates
   - Critical: Lines 172-174 (DispatchQueue.main.async for onFinal)

10. **AppDelegate** (104 lines)
    - NSApplicationDelegate
    - Creates StatusBarController
    - Threading: Main thread lifecycle methods

11. **Permissions** (177 lines)
    - Enum with static methods
    - Shows NSAlert dialogs (main thread required)
    - Threading: Completion handlers may come from system threads

12. **HotkeyManager** (194 lines)
    - Manages global hotkeys via Carbon API
    - Threading: Carbon event callbacks dispatched to main (line 124)

### Current Threading Patterns

#### Explicit Main Thread Dispatch
- StatusBarController: 16 instances of DispatchQueue.main.async
- TranscriptionController: 3 instances (onFinal, callbacks)
- HotkeyManager: 1 instance (handleHotkeyPressed)
- AudioLevelMeterView: 2 instances (update, reset)

#### Async/Await Usage
- StatusBarController.showAppPicker: Task { @MainActor in ... }
- StatusBarController.prepareParakeetEngine: Task { ... } with MainActor.run
- TranscriptionController.start: async throws method

#### NotificationCenter Patterns
All observers registered synchronously, handlers assume main thread:
- SettingsWindowController: 2 observers, handlers update UI directly
- StatusBarController: 3 observers, handlers update UI directly
- No @MainActor isolation on handlers

#### Closure Callbacks from Background
- TranscriptionController: 6 callback properties called from engine threads
- StatusBarController: ModelManager.onDownloadState, appPickerController.onSelection
- SettingsWindowController: ShortcutRecorderView.onShortcutChanged

### Concurrency Hazards Identified

#### Critical Issues (Will cause warnings/errors)

1. **StatusBarController (Lines 105-117, 119-138)**
   - `postEngineStatus()` and `postEngineDownload()` dispatch to main but are called from background
   - Methods themselves not isolated, callers may be on any thread

2. **SettingsWindowController (Lines 671-720)**
   - NotificationCenter handlers `engineStatusDidChange` and `engineDownloadDidChange` update UI
   - No guarantee these notifications arrive on main thread
   - Direct property access: engineStatusLabel.stringValue, engineStatusSpinner

3. **StatusBarController (Lines 369-371, 374-378)**
   - HUD controller setup with closures that call stopRecording()
   - onDownloadState closure updates UI via handleDownloadState
   - No MainActor isolation

4. **TranscriptionController (Lines 50-52, 172-174, 211-213, 230-232)**
   - engine.setPartialHandler closure updates UI indirectly
   - onFinal, onAppAudioLost, onFallbackToMicOnly closures dispatch to main manually
   - Should be @MainActor closures

5. **AudioLevelMeterView (Lines 58-76)**
   - update() and reset() called from background threads
   - Manually dispatch to main for needsDisplay
   - Properties accessed from both threads without isolation

6. **AppPickerWindowController (Lines 28, 208-212)**
   - onSelection closure called without isolation guarantee
   - Closes window (UI operation) from arbitrary thread

#### State Management Issues

1. **StatusBarController (Lines 67-98)**
   - NSLock used for engineState and isRecording
   - Mixing lock-based and actor-based concurrency will cause issues
   - Properties accessed via computed properties with locks

2. **ShortcutRecorderView (Lines 16-21, 27-28)**
   - shortcut property has didSet that calls onShortcutChanged closure
   - isRecording and eventMonitor mutable from event callbacks
   - No isolation guarantees

3. **SettingsWindowController (Lines 212-226)**
   - ShortcutRecorderView.onShortcutChanged closures capture self
   - saveShortcut method posts notifications without isolation

#### Notification Threading

1. **All NotificationCenter.default.post() calls**
   - StatusBarController: Lines 107, 132, 466, 503, 758
   - SettingsWindowController: Line 503, 758
   - Observers assume main thread but no guarantee

2. **NotificationCenter observers**
   - SettingsWindowController init (Lines 59-70): 2 observers
   - StatusBarController init (Lines 184-205): 3 observers
   - None use queue parameter, default to posting thread

---

## 5. Detailed File-by-File Analysis

### 5.1 HUDWindowController.swift

**Current Threading:**
- All methods implicitly main-thread (NSWindowController lifecycle)
- CATransaction callbacks (lines 228-230, 237-239) run on main
- No explicit threading code

**Migration Required:**
```swift
// BEFORE
final class HUDWindowController: NSWindowController {
    func updateMicLevel(rms: Float, peak: Float, peakHold: Float) {
        waveView.updateAudioLevel(rms)
    }
}

// AFTER
@MainActor
final class HUDWindowController: NSWindowController {
    func updateMicLevel(rms: Float, peak: Float, peakHold: Float) {
        waveView.updateAudioLevel(rms)
    }
}
```

**Risks:** Low - already main-thread only

---

### 5.2 SettingsWindowController.swift

**Current Threading:**
- NotificationCenter callbacks (lines 671-720) update UI directly
- Alert sheets (line 655) require main thread
- Popup changes trigger async downloads

**Migration Required:**
```swift
// BEFORE
@objc private func engineStatusDidChange(_ notification: Notification) {
    // Updates UI properties directly
    engineStatusLabel.stringValue = "Loading engine…"
}

// AFTER
@MainActor
final class SettingsWindowController: NSWindowController {
    @objc private func engineStatusDidChange(_ notification: Notification) {
        // Now isolated to main actor
        engineStatusLabel.stringValue = "Loading engine…"
    }
}
```

**Additional Changes:**
- Lines 655-657: Alert beginSheetModal already main-thread
- Lines 212-226: Closure callbacks need @MainActor or nonisolated

**Risks:** Medium - notification handlers must be verified main-thread

---

### 5.3 StatusBarController.swift

**Current Threading:**
- Most complex file with mixed threading
- NSLock for state (lines 67-98)
- Task { @MainActor in } pattern (line 940)
- Many DispatchQueue.main.async calls
- Async/await for SCShareableContent

**Migration Strategy:**
This class is problematic because it's NOT an NSViewController but manages UI.

```swift
// OPTION 1: Mark entire class @MainActor (breaks background work)
@MainActor
final class StatusBarController { ... }

// OPTION 2: Selective isolation (recommended)
final class StatusBarController {
    // State properties isolated
    @MainActor private var hudController: HUDWindowController?
    @MainActor private var settingsController: SettingsWindowController?

    // Thread-safe state (keep locks for now, migrate later)
    private var engineState: EngineState { ... }

    // UI methods
    @MainActor
    private func setupMenu() { ... }

    @MainActor
    private func showAppPicker() { ... }

    // Background-safe methods
    nonisolated
    private func prepareParakeetEngine(restartRecording: Bool = false) {
        Task { @MainActor in
            // UI updates here
        }
    }
}
```

**Critical Lines:**
- 105-117: postEngineStatus - should be @MainActor
- 369-371: HUD callback setup - already on main
- 520-534: checkPermissions - NSAlert needs @MainActor
- 671-720: Notification handlers - need @MainActor

**Risks:** HIGH - most complex migration, many background operations

---

### 5.4 TranscriptionController.swift

**Current Threading:**
- Background audio processing
- Main thread callbacks via DispatchQueue.main.async
- Engine callbacks on background threads

**Migration Required:**
```swift
// BEFORE
var onFinal: ((String) -> Void)?

private func processFinalSegments(_ segments: [ASRFinalSegment]) {
    // ...
    DispatchQueue.main.async {
        self.onFinal?(cleaned)
    }
}

// AFTER
@MainActor
var onFinal: ((String) -> Void)?

nonisolated
private func processFinalSegments(_ segments: [ASRFinalSegment]) {
    // ...
    Task { @MainActor in
        self.onFinal?(cleaned)
    }
}
```

**Risks:** Medium - needs careful callback isolation

---

### 5.5 AudioLevelMeterView.swift

**Current Threading:**
- update() called from background (line 58)
- Manually dispatches to main for needsDisplay (line 64)

**Migration Required:**
```swift
// BEFORE
func update(rms: Float, peak: Float, peakHold: Float) {
    self.rmsLevel = rms
    self.peakLevel = peak
    self.peakHoldLevel = peakHold

    DispatchQueue.main.async {
        self.needsDisplay = true
    }
}

// AFTER
@MainActor
final class AudioLevelMeterView: NSView {
    func update(rms: Float, peak: Float, peakHold: Float) {
        self.rmsLevel = rms
        self.peakLevel = peak
        self.peakHoldLevel = peakHold
        self.needsDisplay = true
    }
}

// Call sites must await or use Task:
Task { @MainActor in
    levelMeterView.update(rms: rms, peak: peak, peakHold: peakHold)
}
```

**Risks:** Low - straightforward isolation

---

### 5.6 AudioWaveView.swift

**Current Threading:**
- Similar pattern to AudioLevelMeterView
- CALayer animations (lines 109-116)

**Migration Required:**
```swift
// AFTER
@MainActor
final class AudioWaveView: NSView {
    func updateAudioLevel(_ level: Float) {
        // All CALayer operations already main-thread
        smoothedLevel = smoothedLevel * (1.0 - smoothingFactor) + level * smoothingFactor
        // ...
    }
}
```

**Risks:** Low - CALayer requires main thread anyway

---

### 5.7 AppPickerWindowController.swift

**Current Threading:**
- Table view delegate/data source (main thread)
- onSelection closure (line 28) called from button click (main)
- Sources passed in constructor (preloaded pattern)

**Migration Required:**
```swift
// AFTER
@MainActor
final class AppPickerWindowController: NSWindowController {
    var onSelection: ((AudioSource) -> Void)?

    @objc private func selectButtonClicked() {
        guard let source = selectedSource else { return }
        onSelection?(source)
        close()
    }
}
```

**Risks:** Low - already main-thread

---

### 5.8 ShortcutRecorderView.swift

**Current Threading:**
- Event monitor (line 125) runs on main
- Property didSet (line 18) triggers callback
- NSEvent handling (lines 113-174)

**Migration Required:**
```swift
// AFTER
@MainAactor
final class ShortcutRecorderView: NSView {
    var shortcut: KeyboardShortcut? {
        didSet {
            updateDisplay()
            onShortcutChanged?(shortcut)
        }
    }

    var onShortcutChanged: ((KeyboardShortcut?) -> Void)?
}
```

**Risks:** Low - NSEvent always main-thread

---

### 5.9 AppDelegate.swift

**Current Threading:**
- All delegate methods on main thread (NSApplicationDelegate)
- Creates StatusBarController (line 51)

**Migration Required:**
```swift
// AFTER
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Already on main thread
    }
}
```

**Risks:** None - already main-thread

---

### 5.10 Permissions.swift

**Current Threading:**
- Static methods that show NSAlert (lines 65-88, 110-133)
- Completion handlers from system APIs (AVFoundation, CoreGraphics)

**Migration Required:**
```swift
// BEFORE
enum Permissions {
    static func ensureMic(completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            completion(granted)
        }
    }
}

// AFTER
enum Permissions {
    @MainActor
    static func ensureMic() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    // Or if keeping completion style:
    static func ensureMic(completion: @escaping @MainActor (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Task { @MainActor in
                completion(granted)
            }
        }
    }

    @MainActor
    static func ensureScreenRecordingGuide() {
        // NSAlert already requires main thread
    }
}
```

**Risks:** Medium - System callback threading uncertain

---

### 5.11 HotkeyManager.swift

**Current Threading:**
- Carbon event handler (lines 87-108) runs on background
- Dispatches to main for handler execution (line 124)

**Migration Required:**
```swift
// BEFORE
private func handleHotkeyPressed(id: UInt32) {
    guard let (_, handler) = hotkeys[id] else { return }
    DispatchQueue.main.async {
        handler()
    }
}

// AFTER
final class HotkeyManager {
    typealias HotkeyHandler = @MainActor () -> Void

    private func handleHotkeyPressed(id: UInt32) {
        guard let (_, handler) = hotkeys[id] else { return }
        Task { @MainActor in
            handler()
        }
    }
}
```

**Risks:** Low - Carbon callback isolation well-defined

---

## 6. Migration Sequence

### Phase 1: Foundation (Low Risk)
**Order:** Bottom-up, least dependent first

1. **AppDelegate.swift**
   - Add `@MainActor` to class
   - Zero dependencies on other UI classes

2. **AudioWaveView.swift**
   - Add `@MainActor` to class
   - Update call sites in HUDWindowController

3. **AudioLevelMeterView.swift** + **DualChannelLevelMeterView**
   - Add `@MainActor` to both classes
   - Update call sites in HUDWindowController, AppPickerWindowController

4. **ShortcutRecorderView.swift**
   - Add `@MainActor` to class
   - Update callback type to `@MainActor` closure

### Phase 2: Window Controllers (Medium Risk)

5. **HUDWindowController.swift**
   - Add `@MainActor` to class
   - Update callback in StatusBarController

6. **AppPickerWindowController.swift**
   - Add `@MainActor` to class
   - Update onSelection closure type
   - Update call site in StatusBarController.showAppPicker

7. **SettingsWindowController.swift**
   - Add `@MainActor` to class
   - Update notification handlers
   - Update shortcut recorder callbacks

### Phase 3: Controllers (High Risk)

8. **TranscriptionController.swift**
   - Mark callback properties as `@MainActor` closures
   - Update processFinalSegments to use Task { @MainActor }
   - Keep class itself nonisolated (background audio work)

9. **HotkeyManager.swift**
   - Update HotkeyHandler typealias to `@MainActor () -> Void`
   - Update handleHotkeyPressed to use Task { @MainActor }

10. **Permissions.swift**
    - Mark alert methods as `@MainActor`
    - Update completion handler threading
    - Consider async/await refactor

### Phase 4: StatusBarController (Highest Risk)

11. **StatusBarController.swift** (LAST)
    - Selective @MainActor isolation:
      - UI properties: hudController, settingsController
      - UI methods: setupMenu, showAppPicker, updateMenuBarIcon, all show* methods
    - Keep nonisolated:
      - prepareParakeetEngine, loadAudioSources (background work)
      - Use Task { @MainActor } for UI updates within
    - Remove NSLock, use actors or @MainActor isolation
    - Update all notification handlers with @MainActor

### Phase 5: Verification

12. **Build and test**
    - Compile with -strict-concurrency=complete
    - Run full test suite
    - Manual testing of all UI flows
    - Verify no runtime crashes

---

## 7. Edge Cases & Gotchas

### 7.1 NotificationCenter Threading

**Problem:** NotificationCenter observers receive notifications on posting thread, not main thread.

**Files Affected:**
- SettingsWindowController (2 observers)
- StatusBarController (3 observers)

**Solution:**
```swift
// BEFORE
NotificationCenter.default.addObserver(
    self,
    selector: #selector(engineStatusDidChange(_:)),
    name: .engineStatusDidChange,
    object: nil
)

// AFTER - Option 1: Use queue parameter
NotificationCenter.default.addObserver(
    self,
    selector: #selector(engineStatusDidChange(_:)),
    name: .engineStatusDidChange,
    object: nil,
    queue: .main  // Force main thread delivery
)

// AFTER - Option 2: Mark handler @MainActor (only if posting is always main)
@MainActor
@objc private func engineStatusDidChange(_ notification: Notification) {
    // ...
}
```

**Recommendation:** Use queue parameter for safety, as posting thread is uncertain.

---

### 7.2 NSWindowController Lifecycle

**Problem:** NSWindowController methods like showWindow(), close() implicitly require main thread.

**Files Affected:** All window controllers

**Solution:** @MainActor isolation on entire class ensures lifecycle methods are safe.

---

### 7.3 CATransaction Completion Blocks

**Problem:** CATransaction callbacks in HUDWindowController (lines 228-230).

**Current Code:**
```swift
CATransaction.begin()
CATransaction.setCompletionBlock {
    completion()  // What thread is this?
}
```

**Analysis:** CATransaction completion blocks run on main thread (documented behavior).

**Solution:** Mark completion parameter as @MainActor:
```swift
private func animateOut(completion: @escaping @MainActor () -> Void) {
    CATransaction.setCompletionBlock {
        completion()  // Safe - CATransaction guarantees main thread
    }
}
```

---

### 7.4 NSAlert Modal vs Sheet

**Problem:** NSAlert.runModal() blocks main thread, beginSheetModal requires window.

**Files Affected:**
- StatusBarController (many modal alerts)
- SettingsWindowController (sheet alerts)
- Permissions (modal alerts)

**Solution:** Both require @MainActor, no change needed beyond class isolation.

---

### 7.5 Task { @MainActor in } vs await MainActor.run

**Problem:** Two patterns for running code on main actor from background.

**Current Usage:**
- StatusBarController uses both (line 940: Task { @MainActor }, line 1224: await MainActor.run)

**Best Practice:**
```swift
// From async context - use await
nonisolated func backgroundWork() async {
    await MainActor.run {
        updateUI()
    }
}

// From sync context - use Task
nonisolated func backgroundWorkSync() {
    Task { @MainActor in
        updateUI()
    }
}
```

---

### 7.6 NSLock vs Actor Isolation

**Problem:** StatusBarController uses NSLock for engineState and isRecording (lines 67-98).

**Issue:** Mixing locks and actors causes warnings in Swift 6.

**Solution:**
```swift
// BEFORE
private var _engineState: EngineState = .idle
private let stateLock = NSLock()
private var engineState: EngineState {
    get {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _engineState
    }
    set { /* ... */ }
}

// AFTER - Option 1: Move to dedicated actor
actor EngineStateManager {
    private(set) var state: EngineState = .idle
    private(set) var isRecording = false

    func updateState(_ newState: EngineState) {
        self.state = newState
    }

    func setRecording(_ recording: Bool) {
        self.isRecording = recording
    }
}

// StatusBarController uses:
private let stateManager = EngineStateManager()

// Access:
let recording = await stateManager.isRecording
await stateManager.setRecording(true)

// AFTER - Option 2: Use @MainActor (if always accessed from main)
@MainActor
private var engineState: EngineState = .idle

@MainActor
private var isRecording = false
```

**Recommendation:** Option 2 if state is only UI-driven, Option 1 if background threads need read access.

---

### 7.7 Sendable Closures

**Problem:** Closures passed across isolation domains must be Sendable.

**Files Affected:**
- TranscriptionController (6 callback properties)
- StatusBarController (onDownloadState, onSelection)

**Solution:**
```swift
// BEFORE
var onFinal: ((String) -> Void)?

// AFTER
var onFinal: (@Sendable @MainActor (String) -> Void)?
```

---

### 7.8 SCShareableContent Threading

**Problem:** SCShareableContent.excludingDesktopWindows can hang indefinitely (line 1001).

**Current Mitigation:** withTimeout wrapper (line 1000).

**Isolation:** Call from background, return to @MainActor:
```swift
nonisolated
private func loadAudioSources() async throws -> [AppPickerWindowController.AudioSource] {
    // Background work
    let content = try await SCShareableContent.excludingDesktopWindows(...)
    return sources
}

@MainActor
private func showAppPicker() {
    Task {
        let sources = try await loadAudioSources()  // Background
        let picker = AppPickerWindowController(sources: sources)  // Main
        picker.showWindow(nil)  // Main
    }
}
```

**Current Implementation:** Already correct (line 940).

---

### 7.9 Combine/Async Sequences

**Files Affected:** None currently, but watch for future additions.

**Best Practice:** Mark AsyncSequence elements as Sendable, consume with @MainActor isolation.

---

### 7.10 AppKit-Specific Threading

**NSView.needsDisplay:** Must be set on main thread (already enforced by @MainActor).

**NSControl.action:** Selector always called on main thread (safe).

**NSTableView delegate/dataSource:** Always called on main thread (safe).

**NSEvent.addLocalMonitorForEvents:** Monitor block runs on main thread (ShortcutRecorderView line 125).

---

## 8. Testing Strategy

### 8.1 Compilation Testing

**Baseline:**
1. Build with -strict-concurrency=minimal: Count warnings
2. Build with -strict-concurrency=targeted: Count warnings
3. Build with -strict-concurrency=complete: Count warnings (target: 0)

**Per-File Migration:**
1. Apply @MainActor to one file
2. Build and count new warnings
3. Fix warnings before moving to next file
4. Track progress in spreadsheet

### 8.2 Runtime Testing

**Critical Flows:**
1. **Mic-Only Recording:**
   - Start recording via menu
   - Start recording via hotkey
   - Stop recording
   - Verify HUD shows/hides
   - Verify transcript copies to clipboard

2. **Mic+App Recording:**
   - Start recording via menu
   - App picker appears
   - Select app
   - Recording starts
   - Stop recording
   - Verify audio mixing

3. **Settings Changes:**
   - Change provider (Whisper ↔ Parakeet)
   - Change model
   - Change shortcuts
   - Enable/disable auto-paste
   - Verify UI updates

4. **Edge Cases:**
   - Rapid start/stop cycles
   - Provider switch during recording
   - App audio lost during recording
   - Download progress updates

### 8.3 Concurrency Testing

**Thread Sanitizer:**
- Enable in scheme (Diagnostics tab)
- Run all test flows
- Check for data races

**Main Thread Checker:**
- Enabled by default in Xcode
- Catches UI updates from background threads
- Should show no warnings after migration

### 8.4 Automated Testing

**Existing Tests:**
- HUDWindowControllerTests.swift
- SettingsWindowControllerTests.swift
- StatusBarControllerTests.swift
- TranscriptionControllerTests.swift

**Test Updates Required:**
```swift
// BEFORE
func test_hudShowsAndHides() {
    let hud = HUDWindowController()
    hud.showWindow(nil)
    XCTAssertTrue(hud.window?.isVisible == true)
}

// AFTER
@MainActor
func test_hudShowsAndHides() {
    let hud = HUDWindowController()
    hud.showWindow(nil)
    XCTAssertTrue(hud.window?.isVisible == true)
}
```

**New Tests:**
- Verify callbacks are @MainActor
- Test async/await flows
- Test notification delivery on main thread

### 8.5 Manual Testing Checklist

**UI Responsiveness:**
- [ ] HUD animations smooth during recording
- [ ] Settings window responds instantly
- [ ] App picker search filters without lag
- [ ] Menu bar icon updates immediately

**Notifications:**
- [ ] Engine status updates in Settings
- [ ] Download progress shows in menu
- [ ] Transcription complete notification appears

**Hotkeys:**
- [ ] Global shortcuts trigger instantly
- [ ] Shortcuts work during full-screen apps
- [ ] Recording indicator updates

**Error Handling:**
- [ ] Permission denied alerts appear
- [ ] Model download errors show
- [ ] App audio loss fallback works

---

## 9. Risk Assessment

### 9.1 High-Risk Areas

**1. StatusBarController (Risk: 8/10)**
- **Why:** Most complex file, 1300 lines, mixed threading
- **Impact:** Core app functionality, breaks recording if wrong
- **Mitigation:**
  - Migrate last after all dependencies
  - Extensive manual testing
  - Incremental changes with frequent builds
  - Consider splitting into smaller classes first

**2. NotificationCenter Observers (Risk: 7/10)**
- **Why:** Posting thread undefined, affects 5 handlers
- **Impact:** UI updates from wrong thread cause crashes
- **Mitigation:**
  - Use queue: .main parameter
  - Mark all handlers @MainActor
  - Add logging to verify thread

**3. TranscriptionController Callbacks (Risk: 6/10)**
- **Why:** Called from background audio threads
- **Impact:** Race conditions in UI updates
- **Mitigation:**
  - Make callbacks @MainActor + @Sendable
  - Update all call sites to use Task { @MainActor }
  - Test with Thread Sanitizer

### 9.2 Medium-Risk Areas

**4. SettingsWindowController (Risk: 5/10)**
- **Why:** Complex UI with many controls, async downloads
- **Impact:** Settings corruption if state races
- **Mitigation:**
  - @MainActor class isolation
  - Test provider switching extensively
  - Verify download UI updates

**5. Permissions (Risk: 4/10)**
- **Why:** System callback threading uncertain
- **Impact:** Alerts may appear on wrong thread
- **Mitigation:**
  - Mark all public methods @MainActor
  - Test permission flows on clean system
  - Verify completion handlers

### 9.3 Low-Risk Areas

**6. AudioLevelMeterView (Risk: 2/10)**
- **Why:** Simple property updates, clear threading
- **Impact:** Visual glitches only
- **Mitigation:** @MainActor isolation, straightforward

**7. HUDWindowController (Risk: 2/10)**
- **Why:** Already main-thread only, simple structure
- **Impact:** Animation issues only
- **Mitigation:** @MainActor isolation, test animations

**8. AppDelegate (Risk: 1/10)**
- **Why:** Standard app delegate, minimal logic
- **Impact:** App launch only
- **Mitigation:** @MainActor class, no changes needed

### 9.4 Overall Assessment

**Total Estimated Effort:** 16-24 hours
- Phase 1 (Foundation): 2-3 hours
- Phase 2 (Window Controllers): 3-4 hours
- Phase 3 (Controllers): 4-6 hours
- Phase 4 (StatusBarController): 5-8 hours
- Phase 5 (Testing): 2-3 hours

**Success Probability:** 85%
- Clear migration path exists
- Existing code already uses main thread for UI
- No fundamental architectural issues
- Risk: StatusBarController complexity

**Rollback Plan:**
- Commit after each file migration
- Keep feature branch until fully tested
- Can disable strict concurrency if critical bugs found

### 9.5 Pre-Migration Checklist

**Before Starting:**
- [ ] Create feature branch: feat/swift-6-ui-isolation
- [ ] Document current warning count (baseline)
- [ ] Review all NSLock usage
- [ ] Identify all NotificationCenter usages
- [ ] Map all async/await call chains
- [ ] Backup current working build

**During Migration:**
- [ ] One file at a time, commit frequently
- [ ] Build after each file
- [ ] Run tests after each phase
- [ ] Update this document with findings
- [ ] Track warning reduction

**After Migration:**
- [ ] Full test suite passes
- [ ] Manual testing complete
- [ ] No Thread Sanitizer warnings
- [ ] No Main Thread Checker warnings
- [ ] Performance benchmarks unchanged
- [ ] Create PR with detailed summary