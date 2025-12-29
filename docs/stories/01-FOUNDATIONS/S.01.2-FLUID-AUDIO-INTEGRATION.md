# S.01.2 - FluidAudio & Parakeet Engine Integration

**Epic:** Add Parakeet (Core ML) Provider
**Status:** Done
**Date:** 2025-12-09
**Dependency:** S.01.1

---

## 1. Objective
Integrate the **FluidAudio** SDK and implement the Parakeet Core ML engine.

**Goal:** A working `ParakeetEngine` class that runs on the Apple Neural Engine (ANE) using the `parakeet-tdt-0.6b-v3` model.

---

## 2. Implementation Plan

### Step 1: Add Dependency
1.  Add `FluidAudio` via Swift Package Manager (SPM).
    *   URL: `https://github.com/FluidInference/FluidAudio` (Verify URL/Version).
    *   Target: `MacTalk`.

### Step 2: `ParakeetBootstrap`
Create a singleton to handle the one-time model download/load process.
```swift
import FluidAudio

final class ParakeetBootstrap {
    static let shared = ParakeetBootstrap()
    private(set) var models: AsrModels?
    
    // Called when user selects Parakeet or app launches in Parakeet mode
    func prepareModels() async throws {
        if models == nil {
            // Downloads from HF Hub -> Cache -> Load
            models = try await AsrModels.downloadAndLoad()
        }
    }
}
```

### Step 3: `ParakeetEngine` Implementation
Create `Whisper/ParakeetEngine.swift` conforming to `ASREngine`.

1.  **Initialization:**
    *   Check `ParakeetBootstrap.shared.models`.
    *   Init `AsrManager` with `MLModelConfiguration.computeUnits = .cpuAndNeuralEngine`.
2.  **Streaming (`process`)**:
    *   **Resampling:** Parakeet expects **16kHz**. Use `AVAudioConverter` to downsample the 48kHz mic input before feeding `AsrManager`.
    *   **Push:** Call `asrManager.transcribeStreaming(pcm: ...)` (or equivalent API).
    *   **Callback:** Emit partials via the handler.
3.  **Finalize (`stop`)**:
    *   Call `asrManager.finalize()`.
    *   Map result to `[ASRFinalSegment]` (Text + Timestamps).

### Step 4: Unit Testing
1.  Create `ParakeetEngineTests`.
2.  Test `initialize()` (Model download simulation).
3.  Test `process()` with a generated 16kHz buffer.

---

## 3. Acceptance Criteria
*   [x] `FluidAudio` linked successfully.
*   [x] `ParakeetEngine` compiles and conforms to `ASREngine`.
*   [x] Audio resampling (48k -> 16k) logic is implemented correctly within the engine.
*   [x] Model downloads and loads on the ANE (verify via logs/instruments).

## 4. Implementation Notes

### FluidAudio API Changes
The actual FluidAudio API differs slightly from the story's initial plan:
- `AsrModelVersion` is a top-level enum (not `AsrModels.ModelVersion`)
- `AsrManager` uses `ASRConfig.default` for configuration
- Streaming is not yet available in FluidAudio - batch transcription is used instead
- Token timings are provided via `result.tokenTimings` which maps to `ASRWord`

### Files Created
- `MacTalk/MacTalk/Whisper/ParakeetBootstrap.swift` - Model download/loading singleton
- `MacTalk/MacTalk/Whisper/ParakeetEngine.swift` - ASREngine implementation
- `MacTalk/MacTalkTests/ParakeetEngineTests.swift` - 15 unit tests

### Configuration Changes
- Added `FluidAudio` SPM package (v0.7.9+) to `project.yml`

---

## 5. Test Results

All 15 ParakeetEngineTests pass successfully:

- **ParakeetEngineTests:** 15 tests ✅

The Parakeet Core ML engine implementation is fully functional and verified.
