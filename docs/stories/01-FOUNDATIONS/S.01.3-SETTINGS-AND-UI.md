# S.01.3 - UI Integration & Settings

**Epic:** Add Parakeet (Core ML) Provider
**Status:** Complete
**Dependency:** S.01.2

---

## 1. Objective
Expose the Parakeet engine to the user and handle runtime switching.

**Goal:** Users can toggle between "Whisper" and "Parakeet" in Settings, and the app seamlessly switches engines.

---
    
## 2. Implementation Plan

### Step 1: Provider Enum
1.  Define `enum ASRProvider: String, CaseIterable, Codable { case whisper, parakeet }`.
2.  Add `provider` property to `AppSettings` (persisted in UserDefaults).

### Step 2: Settings UI
1.  Update `SettingsWindowController` / `GeneralSettingsView`.
2.  Add a "Provider" Picker/PopUpButton.
3.  **Description Text:** Update UI to explain trade-offs (e.g., "Parakeet: Better for English/EU, uses Neural Engine. Whisper: Standard.").

### Step 3: Hot-Swapping Logic
1.  Update `TranscriptionController` to observe `AppSettings.provider`.
2.  **Switching Flow:**
    *   If recording: `stop()`.
    *   Deinit current engine.
    *   `engine = (newProvider == .parakeet) ? ParakeetEngine() : NativeWhisperEngine()`.
    *   `engine.initialize()` (Trigger model load if needed).
    *   If was recording: `start()`.

### Step 4: HUD Updates
1.  Ensure `HUDWindowController` handles `ASRFinalSegment` correctly (showing final text).
2.  (Optional) Visualize which engine is active (e.g., small icon).

---

## 3. Acceptance Criteria
*   [x] User can select Parakeet in Settings.
*   [x] App persists selection across restarts.
*   [x] Changing provider at runtime works without crashing.
*   [x] Dictation works with both engines.

---

## 4. Implementation Details

### Files Created
- `MacTalk/Utilities/AppSettings.swift` - Centralized settings with thread-safe provider management

### Files Modified
- `MacTalk/SettingsWindowController.swift` - Added Provider picker in Advanced tab
- `MacTalk/StatusBarController.swift` - Added hot-swapping logic with proper state management

### Key Features
1. **Thread-Safe Settings**: `AppSettings` uses `NSLock` to protect provider changes and prevent race conditions
2. **Thread-Safe State**: `StatusBarController` uses computed properties with locks for `engineState` and `isRecording`
3. **Task Cancellation**: Rapid provider switching cancels pending initialization tasks
4. **Memory Safety**: All async closures use `[weak self]` to prevent retain cycles
5. **Observer Cleanup**: Both controllers have `deinit` to remove notification observers
6. **Tag-Based UI Lookups**: Settings UI uses view tags instead of fragile string matching

### Thread Safety Implementation
- `AppSettings.provider`: Protected by `NSLock`, notification posted outside lock
- `StatusBarController.engineState`: Thread-safe computed property with `stateLock`
- `StatusBarController.isRecording`: Thread-safe computed property with `stateLock`
- All MainActor.run blocks use `[weak self]` guards
