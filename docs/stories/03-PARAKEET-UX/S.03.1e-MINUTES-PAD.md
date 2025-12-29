# S.03.1e - Minutes Pad (Background Buffer & Retro-Save)

**Epic:** Real-Time Streaming Transcription
**Status:** Draft
**Date:** 2025-12-14
**Dependency:** S.01.2 (batch transcription only, no streaming required)
**Priority:** Medium

---

## 1. Objective

Maintain a rolling audio buffer that allows users to retroactively transcribe the last few minutes of audio.

**Goal:** "I wish I had been recording that" - users can save and transcribe audio they didn't explicitly start recording.

---

## 2. Acceptance Criteria

- [ ] Background buffer captures last 2-5 minutes of audio (configurable)
- [ ] "Save Last X Minutes" action available in menu and via hotkey
- [ ] Transcription uses batch mode (Parakeet or Whisper)
- [ ] Output saved to clipboard and optionally to file
- [ ] Memory usage bounded (~50MB for 5 min at 16kHz mono)
- [ ] Buffer continues during active transcription sessions
- [ ] Clear indication of buffer status in UI

---

## 3. Architecture

```
┌─────────────────┐
│  Microphone     │
└────────┬────────┘
         │
         ▼
┌─────────────────┐     ┌─────────────────┐
│  AudioCapture   │────►│  MinutesPad     │
│                 │     │  (Ring Buffer)  │
└────────┬────────┘     │  5 min @ 16kHz  │
         │              └────────┬────────┘
         ▼                       │
┌─────────────────┐              │ "Save Last 2 Min"
│ TranscriptionCtl│              ▼
│ (Active Session)│     ┌─────────────────┐
└─────────────────┘     │ Batch Transcribe│
                        │ (Parakeet/Whisper)
                        └────────┬────────┘
                                 │
                                 ▼
                        ┌─────────────────┐
                        │ Clipboard/File  │
                        └─────────────────┘
```

---

## 4. Implementation Plan

### Step 1: MinutesPad Class

```swift
/// Always-on audio buffer for retroactive transcription
final class MinutesPad {
    // MARK: - Configuration
    struct Config {
        var maxDuration: TimeInterval = 300  // 5 minutes
        var sampleRate: Double = 16000
    }

    // MARK: - State
    private var ringBuffer: [Float]
    private var writeIndex: Int = 0
    private var totalSamplesWritten: Int = 0
    private let lock = NSLock()
    private let config: Config
    private var isEnabled: Bool

    // Computed capacity
    private var capacity: Int {
        Int(config.maxDuration * config.sampleRate)
    }

    init(config: Config = Config()) {
        self.config = config
        self.isEnabled = true
        self.ringBuffer = [Float](repeating: 0, count: Int(config.maxDuration * config.sampleRate))
    }

    // MARK: - Recording

    /// Append audio samples to the buffer
    func append(_ samples: [Float]) {
        guard isEnabled else { return }

        lock.lock()
        defer { lock.unlock() }

        for sample in samples {
            ringBuffer[writeIndex] = sample
            writeIndex = (writeIndex + 1) % capacity
            totalSamplesWritten += 1
        }
    }

    // MARK: - Retrieval

    /// Extract the last N seconds of audio
    func extractLast(seconds: TimeInterval) -> [Float] {
        lock.lock()
        defer { lock.unlock() }

        let samplesToExtract = min(
            Int(seconds * config.sampleRate),
            min(totalSamplesWritten, capacity)
        )

        guard samplesToExtract > 0 else { return [] }

        var result = [Float](repeating: 0, count: samplesToExtract)

        // Calculate read start position
        let readStart = (writeIndex - samplesToExtract + capacity) % capacity

        for i in 0..<samplesToExtract {
            result[i] = ringBuffer[(readStart + i) % capacity]
        }

        return result
    }

    /// Current duration of buffered audio
    var bufferedDuration: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return TimeInterval(min(totalSamplesWritten, capacity)) / config.sampleRate
    }

    var enabled: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return isEnabled
        }
        set {
            lock.lock()
            isEnabled = newValue
            lock.unlock()
        }
    }

    /// Clear the buffer
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        ringBuffer = [Float](repeating: 0, count: capacity)
        writeIndex = 0
        totalSamplesWritten = 0
    }
}
```

**File:** `MacTalk/MacTalk/Audio/MinutesPad.swift`

### Step 2: MinutesPadManager

```swift
/// Manages MinutesPad lifecycle and transcription
final class MinutesPadManager {
    static let shared = MinutesPadManager()

    private let minutesPad = MinutesPad()
    private var engine: ASREngine?

    var isEnabled: Bool {
        get { minutesPad.enabled }
        set { minutesPad.enabled = newValue }
    }

    var bufferedDuration: TimeInterval {
        minutesPad.bufferedDuration
    }

    /// Called by AudioCapture to feed audio
    func feedAudio(_ samples: [Float]) {
        minutesPad.append(samples)
    }

    /// Transcribe the last N minutes
    func transcribeLast(minutes: Double, language: String?) async throws -> TranscriptionResult {
        let seconds = minutes * 60
        let samples = minutesPad.extractLast(seconds: seconds)

        guard !samples.isEmpty else {
            throw MinutesPadError.noAudioAvailable
        }

        // Get or create engine
        let engine = try await getEngine()
        try await engine.prepare()
        let finalSegment = try await engine.finalize(samples: samples, language: language)
        guard let finalSegment else {
            throw MinutesPadError.transcriptionFailed("No transcription output")
        }

        let fullText = finalSegment.text
        let duration = Double(samples.count) / 16000.0

        return TranscriptionResult(
            text: fullText,
            segments: [finalSegment],
            duration: duration,
            sampleCount: samples.count
        )
    }

    /// Save transcription to clipboard and optionally file
    func saveTranscription(_ result: TranscriptionResult, toFile: Bool = false) throws {
        // Copy to clipboard
        ClipboardManager.setClipboard(result.text)

        // Optionally save to file
        if toFile {
            let filename = "MacTalk-\(ISO8601DateFormatter().string(from: Date())).txt"
            let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let fileURL = documentsURL.appendingPathComponent(filename)
            try result.text.write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    private func getEngine() async throws -> ASREngine {
        if let engine = self.engine {
            return engine
        }

        // Create engine based on user preference
        let engine: ASREngine = AppSettings.shared.provider == .parakeet
            ? ParakeetEngine()
            : NativeWhisperEngine()

        self.engine = engine
        return engine
    }
}

struct TranscriptionResult {
    let text: String
    let segments: [ASRFinalSegment]
    let duration: TimeInterval
    let sampleCount: Int
}

enum MinutesPadError: LocalizedError {
    case noAudioAvailable
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAudioAvailable:
            return "No audio available in buffer"
        case .transcriptionFailed(let reason):
            return "Transcription failed: \(reason)"
        }
    }
}
```

**File:** `MacTalk/MacTalk/Audio/MinutesPadManager.swift`

### Step 3: Menu Integration

```swift
// In StatusBarController
func setupMinutesPadMenu() -> NSMenu {
    let menu = NSMenu()

    // Dynamic item showing buffer status
    let statusItem = NSMenuItem(title: "Buffer: 0:00 / 5:00", action: nil, keyEquivalent: "")
    statusItem.tag = 1001  // For updates
    menu.addItem(statusItem)

    menu.addItem(NSMenuItem.separator())

    // Quick save options
    let save1Min = NSMenuItem(title: "Save Last 1 Minute", action: #selector(saveLastMinute), keyEquivalent: "1")
    save1Min.keyEquivalentModifierMask = [.command, .shift]
    menu.addItem(save1Min)

    let save2Min = NSMenuItem(title: "Save Last 2 Minutes", action: #selector(saveLast2Minutes), keyEquivalent: "2")
    save2Min.keyEquivalentModifierMask = [.command, .shift]
    menu.addItem(save2Min)

    let save5Min = NSMenuItem(title: "Save Last 5 Minutes", action: #selector(saveLast5Minutes), keyEquivalent: "5")
    save5Min.keyEquivalentModifierMask = [.command, .shift]
    menu.addItem(save5Min)

    menu.addItem(NSMenuItem.separator())

    let clearBuffer = NSMenuItem(title: "Clear Buffer", action: #selector(clearMinutesPadBuffer), keyEquivalent: "")
    menu.addItem(clearBuffer)

    return menu
}

@objc func saveLastMinute() {
    saveLastMinutes(1)
}

@objc func saveLast2Minutes() {
    saveLastMinutes(2)
}

@objc func saveLast5Minutes() {
    saveLastMinutes(5)
}

private func saveLastMinutes(_ minutes: Double) {
    Task {
        do {
            // Show progress
            updateMenuStatus("Transcribing...")

            let result = try await MinutesPadManager.shared.transcribeLast(minutes: minutes, language: nil)
            try MinutesPadManager.shared.saveTranscription(result)

            // Show success notification
            showNotification(
                title: "Transcription Complete",
                body: "\(Int(result.duration))s transcribed and copied to clipboard"
            )
        } catch {
            showNotification(
                title: "Transcription Failed",
                body: error.localizedDescription
            )
        }
    }
}
```

### Step 4: Audio Pipeline Integration

```swift
// In TranscriptionController.appendSamples(_:)
// After AudioMixer converts to 16kHz mono samples.
MinutesPadManager.shared.feedAudio(samples)
```

### Step 5: Settings

```swift
extension AppSettings {
    var minutesPadEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "minutesPadEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "minutesPadEnabled") }
    }

    var minutesPadDuration: TimeInterval {
        // 1-10 minutes
        get { UserDefaults.standard.double(forKey: "minutesPadDuration").clamped(to: 60...600) }
        set { UserDefaults.standard.set(newValue, forKey: "minutesPadDuration") }
    }

    var minutesPadSaveToFile: Bool {
        get { UserDefaults.standard.bool(forKey: "minutesPadSaveToFile") }
        set { UserDefaults.standard.set(newValue, forKey: "minutesPadSaveToFile") }
    }
}
```

---

## 5. Memory Considerations

| Duration | Sample Rate | Channels | Memory |
|----------|-------------|----------|--------|
| 1 min | 16kHz | 1 | ~3.8 MB |
| 2 min | 16kHz | 1 | ~7.7 MB |
| 5 min | 16kHz | 1 | ~19.2 MB |
| 10 min | 16kHz | 1 | ~38.4 MB |

Memory is bounded by fixed-size ring buffer. Default 5 minutes uses ~20MB.

---

## 6. Test Plan

### Unit Tests
- `MinutesPadTests` - Buffer operations, wraparound, extraction
- Memory bounds verification
- Thread safety under concurrent write/read

### Integration Tests
- End-to-end save and transcribe flow
- Integration with TranscriptionController audio pipeline

### Manual Testing
- Let buffer fill for 5 minutes, save last 2 minutes
- Verify transcription quality matches active recording
- Test during active transcription session

---

## 7. Files Summary

### New Files
- `MacTalk/MacTalk/Audio/MinutesPad.swift`
- `MacTalk/MacTalk/Audio/MinutesPadManager.swift`
- `MacTalk/MacTalkTests/MinutesPadTests.swift`

### Modified Files
- `MacTalk/MacTalk/StatusBarController.swift` - Menu items
- `MacTalk/MacTalk/TranscriptionController.swift` - Feed MinutesPad
- `MacTalk/MacTalk/SettingsWindowController.swift` - Settings UI
- `MacTalk/MacTalk/Utilities/AppSettings.swift` - Settings
