# S.03.0 - Parakeet Foundation Recovery (Swift 6)

**Epic:** Parakeet Integration & Real-Time UX
**Status:** Ready for Implementation
**Date:** 2025-12-21
**Priority:** CRITICAL (Blocks all Parakeet features)
**Type:** Recovery & Migration Story

---

## 1. Context & Background

### What Happened
During the Swift 6 migration (S.02.x series), the Parakeet implementation from S.01.1-S.01.4 was stashed instead of properly committed. The implementation exists in `git stash@{0}` with message: "WIP: model-selection-ux changes before Swift 6 migration".

### What Was Implemented (Stash Contents)
The stash contains a working Parakeet integration with:

1. ASREngine protocol - abstraction layer for Whisper and Parakeet
2. NativeWhisperEngine - Whisper.cpp wrapped as ASREngine
3. ParakeetEngine - FluidAudio wrapped as ASREngine
4. ParakeetBootstrap - model download/loading singleton
5. ParakeetModelDownloader - HuggingFace download with progress
6. AppSettings - thread-safe provider management
7. NotificationNames - shared notification constants
8. Settings UI - provider picker, engine status, download progress
9. Menu Bar - Parakeet selection alongside Whisper models

### Files in Stash (expected)
```
MacTalk/MacTalk/MacTalk/Whisper/WhisperEngine.swift (renamed to NativeWhisperEngine + ParakeetEngine)
MacTalk/MacTalk/MacTalk/Whisper/ParakeetBootstrap.swift (NEW)
MacTalk/MacTalk/MacTalk/Whisper/ParakeetEngine.swift (NEW)
MacTalk/MacTalk/MacTalk/Whisper/ParakeetModelDownloader.swift (NEW)
MacTalk/MacTalk/MacTalk/Utilities/AppSettings.swift (NEW)
MacTalk/MacTalk/MacTalk/Utilities/NotificationNames.swift (NEW)
MacTalk/MacTalk/MacTalk/SettingsWindowController.swift (MODIFIED - provider UI)
MacTalk/MacTalk/MacTalk/StatusBarController.swift (MODIFIED - hot-swapping)
MacTalk/MacTalk/MacTalk/TranscriptionController.swift (MODIFIED - ASREngine)
project.yml (MODIFIED - FluidAudio SPM)
```

---

## 2. Objective

Recover the stashed Parakeet implementation and migrate it to Swift 6 strict concurrency, ensuring:

1. All existing functionality is preserved
2. Code compiles with `SWIFT_STRICT_CONCURRENCY: complete`
3. Thread safety is maintained with proper Swift 6 patterns
4. Engine state is siloed (never mix Whisper and Parakeet configuration or UI state)
5. Tests pass (including new concurrency stress tests)

---

## 3. Architecture Context & Constraints

- App source is under `MacTalk/MacTalk/MacTalk`.
- Xcode project is generated via XcodeGen. Modify `project.yml`, then run `xcodegen generate`.
- Audio is already mixed and resampled to 16kHz mono float in `AudioMixer`. Do not re-resample in ParakeetEngine.
- Whisper models and Parakeet models must remain in separate caches. Do not reuse Whisper model settings for Parakeet.
- Swift 6 strict concurrency is enabled; use `@Sendable`, `@MainActor`, and locks where needed.
- Notifications are currently defined in `SettingsWindowController.swift`; move shared ones to a Utilities file.

---

## 4. Recovery Plan (Safe)

### Step 1: Confirm and Inspect Stash
Per repo safety rules, `git stash` commands require explicit user permission.

Preferred safe approach:
```bash
# Create feature branch from current HEAD
git checkout -b feat/parakeet-recovery

# Inspect stash contents
git stash show -p stash@{0}
```

If approved to apply:
```bash
# Apply stash without dropping it
git stash apply stash@{0}
```

Do NOT use `git stash pop`.

### Step 2: Reconcile with Current Code
The stash predates Swift 6 changes and current Whisper-only pipeline. Expect conflicts in:
- `TranscriptionController.swift`
- `StatusBarController.swift`
- `SettingsWindowController.swift`
- `WhisperEngine.swift`

Resolve by integrating the ASREngine abstraction while preserving current behavior.

### Step 3: Commit Early
Commit recovered work to the feature branch once the stash applies cleanly.

---

## 5. Implementation Plan

### 5.1 ASREngine Protocol
Create `MacTalk/MacTalk/MacTalk/Audio/ASREngine.swift`:
- `ASRPartial`, `ASRFinalSegment`, `ASRWord` as `Sendable`
- `ASREngine` protocol using async lifecycle methods
- `process(_ buffer: AVAudioPCMBuffer)` for audio ingestion
- `setPartialHandler(_:)` with `@Sendable`

### 5.2 Whisper Engine Rename and Conformance
- Rename `WhisperEngine` to `NativeWhisperEngine` (file and class name).
- Conform to `ASREngine` while preserving current serial queue behavior.
- Update all call sites to the new name.

### 5.3 Parakeet Engine + Bootstrap
- Add `ParakeetBootstrap` and `ParakeetEngine` using FluidAudio (`AsrManager`).
- Initialize with ANE: `MLModelConfiguration.computeUnits = .cpuAndNeuralEngine`.
- Use batch `transcribe(samples)` for now (streaming API reserved for S.03.1a).

### 5.4 Parakeet Model Download
- Implement `ParakeetModelDownloader` similar to `ModelDownloader`, but targeting the Parakeet model files.
- Use notifications to drive Settings UI and menu bar status.
- Keep Parakeet model cache separate from Whisper model cache.

### 5.5 AppSettings + Provider Selection
- Add `AppSettings` with a thread-safe `provider` property and a persisted `ASRProvider` enum.
- Post provider-change notifications outside locks.

### 5.6 UI: Settings and Menu Bar
- Settings: add Provider dropdown and engine status row in Advanced tab.
- When Parakeet is selected, hide Whisper model dropdown and show a fixed label (per `docs/design/MODEL-SELECTION-UX-BEST-PRACTICES.md`).
- Menu bar: add Parakeet as a peer item to Whisper model submenu with mutually exclusive checkmarks.
- Provider switching flow:
  - If recording, stop.
  - Swap engine, initialize.
  - Resume if it was recording.

### 5.7 TranscriptionController Refactor
- Replace direct `WhisperEngine` usage with `any ASREngine`.
- Map existing chunking logic to `engine.process(_:)` and `engine.stop()` results.
- Ensure final transcript logic remains identical.

### 5.8 Project Configuration
- Update `project.yml` to include FluidAudio SPM package (pin `from: "0.7.11"`).
- Run `xcodegen generate`.

---

## 6. Files to Modify

**New Files**
- `MacTalk/MacTalk/MacTalk/Audio/ASREngine.swift`
- `MacTalk/MacTalk/MacTalk/Whisper/ParakeetBootstrap.swift`
- `MacTalk/MacTalk/MacTalk/Whisper/ParakeetEngine.swift`
- `MacTalk/MacTalk/MacTalk/Whisper/ParakeetModelDownloader.swift`
- `MacTalk/MacTalk/MacTalk/Utilities/AppSettings.swift`
- `MacTalk/MacTalk/MacTalk/Utilities/NotificationNames.swift`

**Modified Files**
- `MacTalk/MacTalk/MacTalk/Whisper/WhisperEngine.swift` (rename to `NativeWhisperEngine.swift`)
- `MacTalk/MacTalk/MacTalk/TranscriptionController.swift`
- `MacTalk/MacTalk/MacTalk/SettingsWindowController.swift`
- `MacTalk/MacTalk/MacTalk/StatusBarController.swift`
- `project.yml`

**Tests**
- `MacTalk/MacTalk/MacTalkTests/ParakeetEngineTests.swift`
- `MacTalk/MacTalk/MacTalkTests/AppSettingsTests.swift`
- `MacTalk/MacTalk/MacTalkTests/ConcurrencyStressTests.swift` (add Parakeet stress coverage)
- Update `MacTalk/MacTalk/MacTalkTests/TranscriptionControllerTests.swift` for ASREngine usage

---

## 7. Swift 6 Concurrency Rules

- Use `@MainActor` for UI updates.
- Use `@Sendable` for cross-thread closures.
- `@unchecked Sendable` is acceptable only with explicit locking and reasoning.
- Do not remove explicit `self` usage.

---

## 8. Acceptance Criteria

- [ ] Stash recovered and committed on `feat/parakeet-recovery`
- [ ] ASREngine protocol exists; Whisper and Parakeet conform
- [ ] Whisper engine renamed to `NativeWhisperEngine`
- [ ] Provider switching works (Whisper <-> Parakeet)
- [ ] Settings show provider picker, status row, and correct model display
- [ ] Menu bar shows Parakeet alongside Whisper models with correct checkmarks
- [ ] Parakeet download progress shown and errors surfaced
- [ ] Builds with `SWIFT_STRICT_CONCURRENCY: complete`
- [ ] Tests pass (including new Parakeet tests)
- [ ] MacTalk-TSan tests pass

---

## 9. Test Plan

**Unit Tests**
- `ASREngineProtocolTests` (protocol conformance)
- `ParakeetEngineTests` (init, start/stop, batch transcription)
- `AppSettingsTests` (thread-safe provider persistence)

**Integration Tests**
- Provider switching during recording
- Settings persistence across restarts
- Parakeet download interruption and resume

**Concurrency Tests**
- Concurrent provider switching
- Concurrent audio buffer processing

---

## 10. Code Review Findings (post-implementation)

- [CRITICAL] Provider/engine mismatch: provider switches do not clear/validate the cached `engine`, so a Whisper engine can be used while provider is Parakeet (and vice versa). This violates the engine siloing requirement and user intent. (`MacTalk/MacTalk/StatusBarController.swift`)
  - Proposed fix: on provider change, set `engine = nil`, `parakeetEngine = nil` (if switching away), and only start recording after `prepareEngineForCurrentProvider()` completes; additionally gate `startRecording` on `engine.provider == provider`.
  - Reasoning: avoids cross-engine state leakage, guarantees provider and engine alignment at call time, and preserves the “never mix configuration or state” rule.
- Status: Fixed (engine cleared on provider switch, provider/engine gating on resume/start, Parakeet prepare guarded).
- [HIGH] In-flight chunk tasks are never cancelled; `stop()` triggers `flushFinalChunk()` but detached tasks can still append to `fullTranscript` during/after finalization, mixing sessions and duplicating outputs. (`MacTalk/MacTalk/TranscriptionController.swift`)
  - Proposed fix: introduce a per-session `Task` group or a `Task` array + `CancellationToken` stored in `AudioState`; cancel and await outstanding tasks in `stop()` before `flushFinalChunk()`, and guard appends with a session UUID.
  - Reasoning: ensures no background inference mutates state after stop and prevents cross-session contamination.
- Status: Fixed (per-session task tracking with cancellation/await, session UUID guards for transcript mutations).
- [HIGH] Adaptive chunking is broken: `appendSamples` uses `chunkDurationMs` instead of `currentChunkDuration`, and battery mode shortens chunks (1s vs 3s) while claiming to reduce inference frequency. (`MacTalk/MacTalk/TranscriptionController.swift`)
  - Proposed fix: compute thresholds using `state.currentChunkDuration` consistently, and invert battery mode to increase chunk length (e.g., 5000ms) or rename behavior to match intent.
  - Reasoning: makes adaptive behavior effective and keeps performance messaging accurate.
- Status: Fixed (threshold uses `currentChunkDuration`, battery mode set to 5s).
- [MEDIUM] Data race risk: `language` is mutable and read in detached tasks without synchronization. (`MacTalk/MacTalk/TranscriptionController.swift`)
  - Proposed fix: capture `language` into a local constant inside `processChunk`/`flushFinalChunk`, or move `language` into `AudioState` protected by the lock.
  - Reasoning: eliminates race with settings updates and is TSan-friendly.
- Status: Fixed (language stored in `AudioState` and captured per session).
- [MEDIUM] RMS/peak computation and verbose logging run on the audio callback thread, risking real-time glitches. (`MacTalk/MacTalk/TranscriptionController.swift`)
  - Proposed fix: move RMS/peak diagnostics to a lower-frequency timer on a background queue, or sample 1/N buffers with a fast vectorized pass; guard `print` behind a debug flag.
  - Reasoning: keeps audio callbacks light and prevents XRuns under load.
- Status: Fixed (throttled diagnostics on a background queue; disabled by default).
- [MEDIUM] Final pass clears `fullTranscript` before final inference; if final inference fails, the user loses partial results. (`MacTalk/MacTalk/TranscriptionController.swift`)
  - Proposed fix: keep a copy of the current `fullTranscript`, only replace it on successful final inference, and fall back to partials on failure/empty result.
  - Reasoning: preserves user-visible output even when final inference fails.
- Status: Fixed (final pass only replaces transcript on success).
- [MEDIUM] `allAudio` retains the entire session in memory, leading to unbounded growth during long recordings. (`MacTalk/MacTalk/TranscriptionController.swift`)
  - Proposed fix: cap stored audio duration (e.g., last N minutes), or spool to a temp file and stream the final pass from disk.
  - Reasoning: prevents memory blowups and keeps long sessions stable.
- Status: Fixed (caps final audio buffer to last ~10 minutes).

## 11. Risks & Open Questions

- Stash may be missing or outdated; confirm content before applying.
- Decide Parakeet model storage location (FluidAudio cache vs app-managed path).
- Confirm whether ASREngine should be actor-based now or keep current lock/queue model.
- Ensure engine UI state is isolated per provider (no Whisper state displayed during Parakeet usage).

---

## 12. References

- Stash: `stash@{0}` ("WIP: model-selection-ux changes before Swift 6 migration")
- FluidAudio SDK: https://github.com/FluidInference/FluidAudio
- Parakeet model: https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml
- Apple HIG: `docs/design/MODEL-SELECTION-UX-BEST-PRACTICES.md`
- Swift 6 Migration: `docs/stories/02-SWIFT-6/S.02.0-MIGRATION-STRATEGY.md`

---

## 13. Update Log

- 2025-12-21: Applied code review fixes in `StatusBarController` and `TranscriptionController` per Section 10.
