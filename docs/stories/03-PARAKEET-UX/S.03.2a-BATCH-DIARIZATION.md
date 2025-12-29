# S.03.2a - Batch Speaker Diarization

**Epic:** Speaker Identification
**Status:** Draft
**Date:** 2025-12-14
**Dependency:** S.03.2 (Diarization Core), S.01.2 (Parakeet/Whisper batch transcription)
**Priority:** High

---

## 1. Objective

Implement offline/batch speaker diarization for transcribing audio files with speaker labels.

**Goal:** Process a 30-60 minute audio file and produce a transcript with [A], [B], [C] speaker tags.

---

## 2. Architecture Context & Reuse

- Reuse `DiarizationEngine`, `SpeakerSegment`, `TranscriptAligner`, and `SubtitleWriter` from S.03.2.
- Alignment should use `ASRWord` timestamps; if missing, fall back to segment-level labeling or mark as unknown.

## 3. Acceptance Criteria

- [ ] Process audio files (WAV, M4A, MP3) up to 2 hours
- [ ] Identify 2-10 distinct speakers
- [ ] Align speaker segments with ASR word timestamps
- [ ] Export to SRT/VTT with speaker prefixes
- [ ] Export to JSON with full metadata
- [ ] Processing time <2x real-time on M1
- [ ] Works fully offline (no API calls)

---

## 4. Implementation Plan

### Step 1: Reuse Core Types

Use `DiarizationEngine`, `SpeakerSegment`, and `TranscriptAligner` from S.03.2. Do not re-define these types in this story.

### Step 2: FluidAudio Diarization (if available)

```swift
/// Diarization using FluidAudio SDK (if available)
final class FluidAudioDiarizer: DiarizationEngine {
    var expectedSpeakers: Int?

    func diarize(audio: [Float], sampleRate: Double) async throws -> [SpeakerSegment] {
        // Check if FluidAudio exposes diarization
        // let diarizer = DiarizationManager(config: .default)
        // let result = try await diarizer.performCompleteDiarization(audio: audio)
        // return result.segments.map { ... }

        throw DiarizationError.notAvailable("FluidAudio diarization not yet available")
    }
}
```

### Step 3: Fallback Diarization (Energy-Based Clustering)

Simple fallback if FluidAudio doesn't expose diarization:

```swift
/// Simple energy and spectral clustering-based diarization
/// Note: This is a basic implementation; production would use proper speaker embeddings
final class SimpleDiarizer: DiarizationEngine {
    var expectedSpeakers: Int? = 2

    func diarize(audio: [Float], sampleRate: Double) async throws -> [SpeakerSegment] {
        // 1. Segment audio by energy (VAD-like)
        let speechSegments = detectSpeechSegments(audio: audio, sampleRate: sampleRate)

        // 2. Extract features per segment (MFCCs or simple spectral features)
        let features = extractFeatures(segments: speechSegments, audio: audio, sampleRate: sampleRate)

        // 3. Cluster features (k-means or spectral clustering)
        let clusters = clusterFeatures(features, k: expectedSpeakers ?? 2)

        // 4. Map clusters to speaker labels
        return mapToSpeakerSegments(segments: speechSegments, clusters: clusters)
    }

    // ... implementation details
}
```

### Step 4: Transcript Alignment (Reuse S.03.2)

```swift
let aligner = TranscriptAligner()
let labeledWords = aligner.align(words: asrWords, speakerSegments: speakerSegments)
let labeledSegments = aligner.group(words: labeledWords)
```

### Step 5: SRT/VTT Writer (Reuse S.03.2)

```swift
let writer = SubtitleWriter()
let srt = writer.write(segments: labeledSegments, format: .srt)
let vtt = writer.write(segments: labeledSegments, format: .vtt)
```

### Step 6: Batch Processing UI

```swift
// In StatusBarController or dedicated window
func processBatchFile(url: URL) async {
    do {
        // 1. Load audio file
        let audio = try await loadAudioFile(url)

        // 2. Transcribe with ASR
        updateProgress("Transcribing...")
        let asrWords = try await transcribeAudio(audio)

        // 3. Diarize
        updateProgress("Identifying speakers...")
        let speakerSegments = try await diarizer.diarize(audio: audio.samples, sampleRate: audio.sampleRate)

        // 4. Align
        updateProgress("Aligning...")
        let labeledWords = aligner.align(words: asrWords, speakerSegments: speakerSegments)
        let labeled = aligner.group(words: labeledWords)

        // 5. Export
        let srt = subtitleWriter.write(segments: labeled, format: .srt)
        let outputURL = url.deletingPathExtension().appendingPathExtension("srt")
        try srt.write(to: outputURL, atomically: true, encoding: .utf8)

        showSuccess("Saved to \(outputURL.lastPathComponent)")
    } catch {
        showError(error.localizedDescription)
    }
}
```

---

## 5. Settings

```swift
extension AppSettings {
    var diarizationEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "diarizationEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "diarizationEnabled") }
    }

    var expectedSpeakerCount: Int? {
        get {
            let value = UserDefaults.standard.integer(forKey: "expectedSpeakerCount")
            return value > 0 ? value : nil
        }
        set { UserDefaults.standard.set(newValue ?? 0, forKey: "expectedSpeakerCount") }
    }

    var speakerNames: [String: String] {
        // Map "A" -> "Alice", "B" -> "Bob", etc.
        get { UserDefaults.standard.dictionary(forKey: "speakerNames") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "speakerNames") }
    }
}
```

---

## 6. Test Plan

### Unit Tests
- `BatchDiarizerTests` - Diarizer output shape, speaker counts
- `BatchDiarizationPipelineTests` - End-to-end alignment and export with mocks

### Integration Tests
- End-to-end batch processing
- Multi-speaker audio file

### Manual Testing
- Process 30-minute meeting recording
- Verify speaker labels are reasonable
- Test with 2, 3, 4 speakers

---

## 7. Files Summary

### New Files
- `MacTalk/MacTalk/Audio/FluidAudioDiarizer.swift`
- `MacTalk/MacTalk/Audio/SimpleDiarizer.swift`
- `MacTalk/MacTalkTests/BatchDiarizerTests.swift`
- `MacTalk/MacTalkTests/BatchDiarizationPipelineTests.swift`

### Modified Files
- `MacTalk/MacTalk/StatusBarController.swift` - Batch processing menu
- `MacTalk/MacTalk/SettingsWindowController.swift` - Diarization settings
