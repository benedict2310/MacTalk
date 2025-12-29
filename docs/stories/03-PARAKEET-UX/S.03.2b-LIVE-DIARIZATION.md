# S.03.2b - Live Speaker Diarization

**Epic:** Speaker Identification
**Status:** Draft
**Date:** 2025-12-14
**Dependency:** S.03.2 (Diarization Core), S.03.1a (Streaming Infrastructure)
**Priority:** Medium

---

## 1. Objective

Enable real-time speaker identification during live transcription sessions.

**Goal:** Show [A], [B] speaker labels in the HUD within 1-2 seconds of speech start, with minimal flip-flopping.

---

## 2. Architecture Context & Reuse

- Reuse `DiarizationEngine`, `TranscriptAligner`, and shared models from S.03.2.
- Feed live audio from `StreamingManager` (S.03.1a) into the streaming diarizer.
- Use `ASRWord` timestamps where available for alignment.

## 3. Acceptance Criteria

- [ ] Speaker labels appear within 1-2s of speech start
- [ ] Labels stable (no rapid flip-flopping)
- [ ] Hysteresis: 300ms+ before switching labels
- [ ] Works with 2-4 concurrent speakers
- [ ] HUD shows speaker badge per line
- [ ] Can be disabled for faster performance

---

## 4. Architecture

```
┌─────────────────┐     ┌──────────────────┐
│ StreamingManager│────►│ StreamingDiarizer│
│ (audio chunks)  │     │ (sliding window) │
└────────┬────────┘     └────────┬─────────┘
         │                       │
         ▼                       ▼
┌─────────────────┐     ┌──────────────────┐
│ ASR Partials    │     │ Speaker Segments │
│ (text + times)  │     │ (who + when)     │
└────────┬────────┘     └────────┬─────────┘
         │                       │
         └───────────┬───────────┘
                     ▼
            ┌─────────────────┐
            │ Live Aligner    │
            │ (with hysteresis)│
            └────────┬────────┘
                     │
                     ▼
            ┌─────────────────┐
            │ HUD: [A] text...│
            └─────────────────┘
```

---

## 5. Implementation Plan

### Step 1: Streaming Diarizer

```swift
/// Real-time speaker diarization using sliding windows
final class StreamingDiarizer {
    struct Config {
        var windowDuration: TimeInterval = 10.0    // Context window
        var hopInterval: TimeInterval = 2.0        // Update interval
        var minSpeechDuration: TimeInterval = 0.5  // Minimum speech to identify
    }

    private let config: Config
    private let batchDiarizer: DiarizationEngine
    private var audioBuffer: [Float] = []
    private var currentSegments: [SpeakerSegment] = []
    private let lock = NSLock()

    var onSpeakersUpdated: (([SpeakerSegment]) -> Void)?

    func feedAudio(_ samples: [Float]) {
        lock.lock()
        audioBuffer.append(contentsOf: samples)

        // Keep only last windowDuration seconds
        let maxSamples = Int(config.windowDuration * 16000)
        if audioBuffer.count > maxSamples {
            audioBuffer.removeFirst(audioBuffer.count - maxSamples)
        }
        lock.unlock()
    }

    func update() async {
        lock.lock()
        let audio = audioBuffer
        lock.unlock()

        guard audio.count > Int(config.minSpeechDuration * 16000) else { return }

        do {
            let segments = try await batchDiarizer.diarize(audio: audio, sampleRate: 16000)
            currentSegments = segments
            onSpeakersUpdated?(segments)
        } catch {
            print("Diarization update failed: \(error)")
        }
    }
}
```

**File:** `MacTalk/MacTalk/Audio/StreamingDiarizer.swift`

### Step 2: Live Aligner with Hysteresis

```swift
/// Aligns streaming partials with speaker segments, with stability
final class LiveAligner {
    struct Config {
        var hysteresisMs: TimeInterval = 300
        var dominanceThreshold: Double = 0.6  // 60% of time in segment
    }

    private let config: Config
    private var lastSpeaker: String = "A"
    private var lastSwitchTime: Date = .distantPast
    private var speakerHistory: [(speaker: String, time: Date)] = []

    /// Get current speaker for a time range
    func currentSpeaker(
        for timeRange: ClosedRange<TimeInterval>,
        segments: [SpeakerSegment]
    ) -> String {
        let dominant = dominantSpeaker(for: timeRange, in: segments)

        // Apply hysteresis
        let timeSinceSwitch = Date().timeIntervalSince(lastSwitchTime) * 1000
        if dominant != lastSpeaker && timeSinceSwitch < config.hysteresisMs {
            return lastSpeaker  // Keep previous speaker during hysteresis
        }

        // Check dominance threshold
        let dominance = speakerDominance(dominant, for: timeRange, in: segments)
        if dominance < config.dominanceThreshold {
            return lastSpeaker  // Not dominant enough to switch
        }

        // Switch speaker
        if dominant != lastSpeaker {
            lastSpeaker = dominant
            lastSwitchTime = Date()
            speakerHistory.append((dominant, Date()))
        }

        return dominant
    }

    private func dominantSpeaker(
        for range: ClosedRange<TimeInterval>,
        in segments: [SpeakerSegment]
    ) -> String {
        // Same as TranscriptAligner
        var durations: [String: TimeInterval] = [:]
        for seg in segments {
            let overlap = max(0, min(range.upperBound, seg.endTime) - max(range.lowerBound, seg.startTime))
            if overlap > 0 {
                durations[seg.speaker, default: 0] += overlap
            }
        }
        return durations.max(by: { $0.value < $1.value })?.key ?? lastSpeaker
    }

    private func speakerDominance(
        _ speaker: String,
        for range: ClosedRange<TimeInterval>,
        in segments: [SpeakerSegment]
    ) -> Double {
        let total = range.upperBound - range.lowerBound
        guard total > 0 else { return 0 }

        var speakerTime: TimeInterval = 0
        for seg in segments where seg.speaker == speaker {
            let overlap = max(0, min(range.upperBound, seg.endTime) - max(range.lowerBound, seg.startTime))
            speakerTime += overlap
        }

        return speakerTime / total
    }

    func reset() {
        lastSpeaker = "A"
        lastSwitchTime = .distantPast
        speakerHistory.removeAll()
    }
}
```

**File:** `MacTalk/MacTalk/Audio/LiveAligner.swift`

### Step 3: Integration with StreamingManager

```swift
// In StreamingManager
private var streamingDiarizer: StreamingDiarizer?
private var liveAligner = LiveAligner()
private var currentSpeakerSegments: [SpeakerSegment] = []

func setupLiveDiarization() {
    guard AppSettings.shared.liveDiarizationEnabled else { return }

    streamingDiarizer = StreamingDiarizer(batchDiarizer: getDiarizer())
    streamingDiarizer?.onSpeakersUpdated = { [weak self] segments in
        self?.currentSpeakerSegments = segments
    }

    // Schedule diarization updates
    Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
        Task {
            await self?.streamingDiarizer?.update()
        }
    }
}

func feedAudio(_ buffer: AVAudioPCMBuffer) {
    // ... existing audio handling ...

    // Feed diarizer
    if let samples = extractSamples(from: buffer) {
        streamingDiarizer?.feedAudio(samples)
    }
}

func processPartial(_ text: String, timeRange: ClosedRange<TimeInterval>) {
    let speaker = liveAligner.currentSpeaker(
        for: timeRange,
        segments: currentSpeakerSegments
    )

    onPartial?(LabeledPartial(text: text, speaker: speaker))
}
```

### Step 4: HUD Speaker Display

```swift
// In HUDWindowController
func updatePartial(_ partial: LabeledPartial) {
    // Show speaker badge
    speakerBadge.stringValue = "[\(partial.speaker)]"
    speakerBadge.textColor = colorForSpeaker(partial.speaker)

    // Show text
    partialLabel.stringValue = partial.text
}

private func colorForSpeaker(_ speaker: String) -> NSColor {
    // Consistent colors per speaker
    switch speaker {
    case "A": return .systemBlue
    case "B": return .systemGreen
    case "C": return .systemOrange
    case "D": return .systemPurple
    default: return .secondaryLabelColor
    }
}
```

---

## 6. Performance Considerations

| Metric | Target | Notes |
|--------|--------|-------|
| Diarization update interval | 2s | Trade-off: accuracy vs latency |
| Additional CPU | <10% | On top of streaming transcription |
| Memory | <50MB | Speaker embeddings cached |

---

## 7. Settings

```swift
extension AppSettings {
    var liveDiarizationEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "liveDiarizationEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "liveDiarizationEnabled") }
    }

    var diarizationHysteresisMs: TimeInterval {
        get { UserDefaults.standard.double(forKey: "diarizationHysteresisMs").clamped(to: 100...1000) }
        set { UserDefaults.standard.set(newValue, forKey: "diarizationHysteresisMs") }
    }
}
```

---

## 8. Test Plan

### Unit Tests
- `LiveAlignerTests` - Hysteresis logic, dominance threshold
- `StreamingDiarizerTests` - Buffer management, update timing

### Integration Tests
- End-to-end live diarization flow
- Speaker switch scenarios

### Manual Testing
- Two-person conversation, verify labels switch correctly
- Test with overlapping speech
- Verify no rapid flip-flopping

---

## 9. Files Summary

### New Files
- `MacTalk/MacTalk/Audio/StreamingDiarizer.swift`
- `MacTalk/MacTalk/Audio/LiveAligner.swift`
- `MacTalk/MacTalkTests/LiveAlignerTests.swift`

### Modified Files
- `MacTalk/MacTalk/Whisper/StreamingManager.swift` - Diarization integration
- `MacTalk/MacTalk/HUDWindowController.swift` - Speaker badges
- `MacTalk/MacTalk/SettingsWindowController.swift` - Live diarization toggle
