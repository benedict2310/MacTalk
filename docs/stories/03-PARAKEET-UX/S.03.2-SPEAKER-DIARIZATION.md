# S.03.2 - Speaker Diarization Core (Shared Types + Alignment)

**Epic:** Speaker Identification
**Status:** Draft
**Date:** 2025-12-22
**Dependency:** S.01.2 (Parakeet/Whisper batch), S.03.0 (ASR abstraction)
**Priority:** Medium (blocks S.03.2a and S.03.2b)

---

## 1. Objective

Provide shared data models and alignment utilities for speaker diarization so both batch and live modes can reuse the same core logic.

**Goal:** Given ASR words with timestamps and diarizer segments, produce labeled segments and SRT/VTT output consistently.

---

## 2. Scope / Non-Goals

**In scope:**
- Shared diarization data models.
- Alignment logic that assigns speakers to ASR segments/words.
- Subtitle formatting (SRT/VTT) with speaker labels.

**Out of scope:**
- Running a diarization model (S.03.2a/S.03.2b).
- Live streaming update loops (S.03.2b).
- UI for speaker rename or labeling (handled in sub-stories).

---

## 3. Architecture Context & Reuse

- `MacTalk/MacTalk/Audio/ASREngine.swift` already defines `ASRWord` with optional timestamps. Use these as the primary alignment input.
- If ASR words do not include timestamps, fall back to segment-level timing derived from ASR results or leave speaker unknown.
- Keep provider state siloed; diarization consumes ASR output and does not affect engine configuration.

---

## 4. Implementation Plan

### Step 1: Shared Models
Create a common model file to avoid duplication across S.03.2a and S.03.2b.

```swift
/// Shared diarization models
struct SpeakerSegment: Sendable, Equatable {
    let speaker: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let confidence: Float?
}

struct LabeledWord: Sendable, Equatable {
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let speaker: String
}

struct LabeledSegment: Sendable, Equatable {
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let speaker: String
    let words: [LabeledWord]
}

protocol DiarizationEngine: Sendable {
    func diarize(audio: [Float], sampleRate: Double) async throws -> [SpeakerSegment]
    var expectedSpeakers: Int? { get set }
}
```

**Files:** `MacTalk/MacTalk/Audio/DiarizationModels.swift`, `MacTalk/MacTalk/Audio/DiarizationEngine.swift`

### Step 2: TranscriptAligner
Align ASR word timings to diarization segments and return labeled segments.

```swift
final class TranscriptAligner {
    func align(words: [ASRWord], speakerSegments: [SpeakerSegment]) -> [LabeledWord] {
        // Assign each word to the dominant speaker for its time range.
    }

    func group(words: [LabeledWord]) -> [LabeledSegment] {
        // Coalesce consecutive words with the same speaker into segments.
    }
}
```

**File:** `MacTalk/MacTalk/Audio/TranscriptAligner.swift`

### Step 3: SubtitleWriter
Provide shared SRT/VTT formatting utilities used by both batch and live flows.

```swift
final class SubtitleWriter {
    enum Format { case srt, vtt }

    func write(segments: [LabeledSegment], format: Format) -> String {
        // Include speaker prefix like "[A]" at the start of each segment.
    }
}
```

**File:** `MacTalk/MacTalk/Audio/SubtitleWriter.swift`

### Step 4: Tests
Add unit tests to validate alignment and formatting.

---

## 5. Files to Modify

**New Files**
- `MacTalk/MacTalk/Audio/DiarizationModels.swift`
- `MacTalk/MacTalk/Audio/DiarizationEngine.swift`
- `MacTalk/MacTalk/Audio/TranscriptAligner.swift`
- `MacTalk/MacTalk/Audio/SubtitleWriter.swift`

**Tests**
- `MacTalk/MacTalkTests/TranscriptAlignerTests.swift`
- `MacTalk/MacTalkTests/SubtitleWriterTests.swift`

---

## 6. Acceptance Criteria

- [ ] Shared diarization models exist and are reused by S.03.2a/S.03.2b.
- [ ] Alignment produces stable speaker labels for word timings.
- [ ] SRT/VTT output includes speaker prefixes and correct timestamps.
- [ ] Unit tests cover alignment and formatting edge cases.

---

## 7. Risks & Open Questions

- ASR word timings may be missing or coarse; decide fallback behavior (unknown speaker vs. segment-level label).
- Speaker naming (A/B/...) should remain consistent across batch and live modes.
