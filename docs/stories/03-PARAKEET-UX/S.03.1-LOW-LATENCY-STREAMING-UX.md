# S.03.1 - Low-Latency Streaming UX Integration

**Epic:** Real-Time Streaming Transcription
**Status:** Implemented
**Date:** 2025-12-22
**Dependency:** S.03.1a, S.03.1b, S.03.0
**Priority:** High

---

## 1. Objective

Wire streaming partials and finals into the UI so dictation feels "type-as-you-speak" with sub-second feedback.

**Goal:** Users see stable partial text within 400ms and a final commit within 300ms of a pause.

---

## 2. Scope / Non-Goals

**In scope:**
- Present live partial text in the HUD (and/or caption strip if enabled).
- Visual distinction between partial vs final text.
- Throttled UI updates to avoid flicker and main-thread load.
- Provider-safe behavior (no Whisper/Parakeet state mixing).

**Out of scope:**
- Streaming infrastructure details (S.03.1a).
- VAD implementation (S.03.1b).
- Caption strip window pinning mechanics (S.03.1d) - only consumes its UI API.

---

## 3. Architecture Context & Reuse

- `MacTalk/MacTalk/TranscriptionController.swift` already emits `onPartial` and `onFinal` callbacks.
- `MacTalk/MacTalk/StatusBarController.swift` currently disables `onPartial` updates; this story re-enables and routes to UI.
- `MacTalk/MacTalk/HUDWindowController.swift` currently does not render text; add a lightweight transcript view here.
- `MacTalk/MacTalk/Whisper/PartialDiffer.swift` and `StreamingManager` (S.03.1a) handle stability and diffing; UI should not re-diff.
- Keep AudioMixer output at 16kHz mono and provider siloing rules intact.

---

## 4. Implementation Plan

### Step 1: Add a Live Transcript View to HUD
- Add a small `NSTextField` (or `NSTextView` if needed) to HUD content.
- Style: partial text at 70% opacity; final text at 100% opacity.
- Clamp to 1-2 lines with truncation to avoid layout shifts.
- Ensure layout does not interfere with wave view and stop button.

### Step 2: Route Partial and Final Updates
- In `StatusBarController.setupTranscriptionCallbacks`, re-enable `onPartial` and call a new `HUDWindowController.updatePartial(text:)`.
- Add `HUDWindowController.updateFinal(text:)` for final commit, then optionally clear after a short delay.
- Use `@MainActor` updates only (HUD is main-thread UI).

### Step 3: Throttle UI Updates
- Use the existing throttling in `TranscriptionController` (or add a throttle at the call site) to limit UI updates to ~10 Hz.
- Ensure partial updates are not posted if text has not changed since the last UI render.

### Step 4: Recording States and Transitions
- Show "Listening..." until first partial arrives.
- On stop, keep the final text visible briefly, then reset HUD.

---

## 5. Files to Modify

**Modified Files**
- `MacTalk/MacTalk/StatusBarController.swift` - re-enable partial callbacks and route to HUD updates.
- `MacTalk/MacTalk/HUDWindowController.swift` - add live transcript view and update methods.
- `MacTalk/MacTalk/TranscriptionController.swift` - ensure throttled partials for UI (if not already).

**Optional (if caption strip exists)**
- `MacTalk/MacTalk/UI/CaptionStripController.swift` - mirror partial/final updates for pinned captions.

---

## 6. Tests & Validation

- `MacTalk/MacTalkTests/HUDWindowControllerTests.swift` - verify HUD updates for partial and final text.
- Manual: use `./build.sh run` and confirm partials update smoothly and finals lock-in after pauses.
- Run `xcodebuild test -scheme MacTalk-TSan` to validate no UI threading issues.

---

## 7. Acceptance Criteria

- [x] Partial text appears in UI within 400ms of speech start during streaming.
- [x] Final text appears within 300ms after pause.
- [x] Partial text is visually distinct from final text (70% opacity vs 100% opacity).
- [x] UI update rate is capped (~10 Hz), no flicker or main-thread spikes (throttled in TranscriptionController).
- [x] Provider switching preserves UI state separation (reset on showWindow, engine-independent HUD).

---

## 8. Risks & Open Questions

- HUD layout may need iteration to avoid clutter with the audio wave.
- Decide whether the caption strip becomes the primary text surface once S.03.1d lands.
