# S.01.4 - Model Selection UX & Download Experience

**Epic:** Add Parakeet (Core ML) Provider
**Status:** Complete
**Dependency:** S.01.3
**Design Reference:** [MODEL-SELECTION-UX-BEST-PRACTICES.md](../design/MODEL-SELECTION-UX-BEST-PRACTICES.md)

---

## 1. Objective

Improve the model selection UX in Settings and provide a consistent download/loading experience for both Whisper and Parakeet engines.

**Goals:**
1. Users can clearly see which engine/model is selected
2. Users receive visual feedback when models are downloading or loading
3. Download experience is consistent between Whisper and Parakeet

---

## 2. Problems to Fix

### Issue 1: Confusing Model Dropdown
**Current behavior:** When Parakeet is selected as the provider, the model dropdown shows "Parakeet TDT (Fixed)" but the visual presentation is confusing. The dropdown appears to still show Whisper context, creating a mismatch between what users see and what's actually running.

**Expected behavior:** The model dropdown should clearly reflect the selected provider's available models, with distinct visual treatment.

### Issue 2: No Loading State Indicator
**Current behavior:** When Parakeet is selected and the model/engine is loading (which can take several seconds), there is no visual feedback. Users have no way to know the engine is initializing.

**Expected behavior:** A loading indicator (spinner or progress text) should appear while the engine is initializing.

### Issue 3: Inconsistent Download Experience
**Current behavior:** Whisper models show download confirmation dialog, progress percentage, and verification status. Parakeet downloads silently with no feedback.

**Expected behavior:** Both engines should have similar download UX with progress feedback.

---

## 3. FluidAudio API Investigation Results

**Finding:** FluidAudio does NOT expose progress callbacks. The API is:
```swift
public static func downloadAndLoad(
    to directory: URL? = nil,
    configuration: MLModelConfiguration? = nil,
    version: AsrModelVersion = .v3
) async throws -> AsrModels
```

**Available methods we can leverage:**
| Method | Purpose |
|--------|---------|
| `AsrModels.modelsExist(at:)` | Check if models already downloaded |
| `AsrModels.download()` | Download only (separate from load) |
| `AsrModels.load(from:)` | Load pre-downloaded models |
| `AsrModels.defaultCacheDirectory()` | Get cache location |

**Models source:** `https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml`

**Model files required:**
- Preprocessor.mlmodelc
- Encoder.mlmodelc
- Decoder.mlmodelc
- JointDecision.mlmodelc
- parakeet_vocab.json

---

## 4. Implementation Plan

### Phase A: Basic UI Improvements (Quick Win)

#### Step A1: Improve Model Dropdown Clarity
**AppKit Controls:** `NSPopUpButton` (Whisper) + `NSTextField` (Parakeet)

1. Hide the model dropdown (`NSPopUpButton`) entirely when Parakeet is selected
2. Show read-only `NSTextField(labelWithString:)` with "Parakeet TDT 0.6B (Core ML)"
3. When Whisper is selected, show the model dropdown normally
4. Use visibility toggling: `modelDropdown.isHidden` / `parakeetLabel.isHidden`

**Implementation Pattern:**
```swift
// Keep two controls in layout, toggle visibility
modelDropdown.isHidden = isParakeetSelected
parakeetLabel.isHidden = !isParakeetSelected

// For Parakeet label - subtle secondary color
parakeetLabel.textColor = .secondaryLabelColor
```

#### Step A2: Add Loading State Indicator in Settings
**AppKit Controls:** `NSProgressIndicator` (spinning) + `NSTextField` (status)

1. Add status row below the provider dropdown showing engine state
2. Use `NSProgressIndicator` with `.spinning` style, `.small` controlSize, indeterminate
3. Display states with semantic colors:
   - "Ready" → `.secondaryLabelColor` or `.systemGreen`
   - "Loading..." → `.controlTextColor`
   - "Error: ..." → `.systemRed`
4. Wire up to existing `ParakeetBootstrap.isLoading` and engine state notifications

**Implementation Pattern:**
```swift
let spinner = NSProgressIndicator()
spinner.style = .spinning
spinner.controlSize = .small
spinner.isIndeterminate = true

func updateEngineStatus(_ state: EngineState) {
    switch state {
    case .idle:
        spinner.stopAnimation(nil)
        statusLabel.stringValue = "Ready"
    case .loading:
        spinner.startAnimation(nil)
        statusLabel.stringValue = "Loading engine..."
    case .error(let msg):
        spinner.stopAnimation(nil)
        statusLabel.stringValue = "Error: \(msg)"
        statusLabel.textColor = .systemRed
    }
}
```

### Phase B: Unified Download Experience (More Involved)

#### Step B1: Create Parakeet Model Specs
1. Add `ParakeetModelSpec` to define model metadata (size, URLs, checksums)
2. Model files are `.mlmodelc` bundles (tar archives on HuggingFace)
3. Total download size: ~600MB for v3 model

#### Step B2: Implement Parakeet Download with Progress
1. Check `AsrModels.modelsExist()` before downloading
2. If not present, download via our `ModelDownloader` with progress
3. Download individual model files from HuggingFace with progress tracking
4. After download complete, use `AsrModels.load(from:)` to initialize

#### Step B3: Unify Download UI
**AppKit Controls:** `NSAlert` (sheet modal) + `NSProgressIndicator` (determinate)

1. Show confirmation dialog using `NSAlert.beginSheetModal(for:completionHandler:)`
   - Use sheet modal (not app modal) for settings window context
   - `alertStyle = .informational`
   - `messageText = "Download Parakeet Model?"`
   - `informativeText = "This will download approximately 600MB of model files."`
2. Display download progress with determinate `NSProgressIndicator`:
   - `isIndeterminate = false`
   - `minValue = 0.0`, `maxValue = 100.0`
   - Update `doubleValue` as progress updates
3. Show verification/loading state after download completes

**Confirmation Dialog Pattern:**
```swift
func showDownloadConfirmation(window: NSWindow, completion: @escaping (Bool) -> Void) {
    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = "Download Parakeet Model?"
    alert.informativeText = "This will download approximately 600MB of model files."
    alert.addButton(withTitle: "Download")
    alert.addButton(withTitle: "Cancel")

    alert.beginSheetModal(for: window) { response in
        completion(response == .alertFirstButtonReturn)
    }
}
```

---

## 5. Acceptance Criteria

## Progress Update (2025-12-14)

### Implemented (Code)

- **Settings → Advanced**
  - Provider dropdown includes **Whisper** and **Parakeet**
  - When **Parakeet** selected: Whisper model dropdown is hidden and a read-only label `Parakeet TDT 0.6B (Core ML)` is shown
  - Added `Engine:` status row (spinner + text) reflecting `loading/downloading/verifying/ready/error`
- **Parakeet downloads now show progress**
  - Confirmation shown before download (sheet in Settings, fallback alert when switching provider outside Settings)
  - Download progress shown in the menu bar progress row and is forwarded to Settings via notifications
  - Implemented a progress-backed downloader by enumerating HuggingFace repo files and downloading them sequentially
- **Whisper model selection is now wired to the running engine**
  - Changing Whisper model in Settings reloads Whisper engine (and triggers the same download flow as the menu “Model” submenu)
- **About menu includes version**
  - Menu item shows `About MacTalk (vX.Y.Z)` and the dialog shows version + build

### Menu Bar Provider Selection

- The menu bar now shows both **Model** submenu (Whisper models) and **Parakeet TDT 0.6B (Core ML)** as peer items
- Checkmarks indicate active provider: either a Whisper model is checked OR Parakeet is checked
- Clicking Parakeet switches to Parakeet provider
- Clicking any Whisper model while Parakeet is active switches back to Whisper with that model

### Phase A (Basic)
- [x] Model dropdown hidden when Parakeet selected, shows info text instead (Settings)
- [x] Menu bar shows Parakeet as peer item to Model submenu with correct checkmarks
- [x] Loading indicator appears in Settings when engine initializing
- [x] Loading indicator disappears when engine is ready
- [x] Error state is displayed if engine fails to initialize

### Phase B (Full Download Parity)
- [x] Download confirmation dialog shown before Parakeet model download
- [x] Download progress shown in menu bar (same as Whisper)
- [x] Download can be monitored via Settings UI
- [x] Both engines have consistent download/loading UX

---

## 6. Files to Modify

### Phase A
- `MacTalk/MacTalk/SettingsWindowController.swift` - Hide dropdown for Parakeet, add loading indicator + engine status row
- `MacTalk/MacTalk/StatusBarController.swift` - Post engine/download status notifications and wire Settings model selection to engine reload

### Phase B
- `MacTalk/MacTalk/Whisper/ParakeetBootstrap.swift` - Download-if-needed + load (using progress-backed downloader)
- `MacTalk/MacTalk/Whisper/ParakeetModelDownloader.swift` - HuggingFace file enumeration + progress download for Parakeet
- `MacTalk/MacTalk/Utilities/NotificationNames.swift` - Shared notification names for engine/download status

---

## 7. Technical Notes

- FluidAudio caches models at: `~/Library/Application Support/FluidAudio/Models/`
- Whisper caches at: `~/Library/Application Support/MacTalk/Models/`
- For Phase B, we could either:
  - Download to FluidAudio's cache location, OR
  - Download to our location and pass path to `AsrModels.load(from:)`
- The second option gives us more control and consistency

---

## 8. Apple AppKit Control Reference

Based on Apple Developer Documentation research (see [Best Practices](../design/MODEL-SELECTION-UX-BEST-PRACTICES.md)):

| Use Case | Control | Apple Class | Key Properties |
|----------|---------|-------------|----------------|
| Whisper model selection | Dropdown | `NSPopUpButton` | `addItem(withTitle:)`, `selectItem(at:)`, `synchronizeTitleAndSelectedItem()` |
| Parakeet model display | Label | `NSTextField` | `init(labelWithString:)`, `textColor = .secondaryLabelColor` |
| Engine loading feedback | Spinner | `NSProgressIndicator` | `style = .spinning`, `controlSize = .small`, `isIndeterminate = true` |
| Download confirmation | Dialog | `NSAlert` | `beginSheetModal(for:completionHandler:)`, `alertStyle = .informational` |
| Status messaging | Label | `NSTextField` | Semantic colors: `.systemGreen`, `.systemRed`, `.controlTextColor` |
| Download progress | Progress bar | `NSProgressIndicator` | `isIndeterminate = false`, `doubleValue`, `observedProgress` |

### Accessibility Considerations (Apple Best Practices)

1. **Provide meaningful labels** - Use `accessibilityLabel` for all controls
2. **Progress indicator** - Announce when loading completes
3. **Color isn't enough** - Combine status colors with text labels (e.g., "Ready" + green, not just green)
4. **Keyboard navigation** - Default for AppKit controls, ensure tab order is logical

### Key Apple Documentation Links

- [NSPopUpButton](https://developer.apple.com/documentation/appkit/nspopupbutton)
- [NSProgressIndicator](https://developer.apple.com/documentation/appkit/nsprogressindicator)
- [NSAlert](https://developer.apple.com/documentation/appkit/nsalert)
- [NSTextField](https://developer.apple.com/documentation/appkit/nstextfield)
