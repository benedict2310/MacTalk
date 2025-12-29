# S.03.1b - VAD Integration & Barge-In Detection

**Epic:** Real-Time Streaming Transcription
**Status:** Ready for Implementation
**Date:** 2025-12-21 (Updated)
**Dependency:** S.03.1a-STREAMING-INFRASTRUCTURE
**Priority:** High (Critical for latency optimization)

---

## 1. Objective

Integrate Voice Activity Detection (VAD) to optimize streaming transcription latency and resource usage.

**Goals:**
1. Skip transcription during silence (save CPU/battery)
2. Detect speech end quickly for faster finalization
3. Enable barge-in detection (user interrupts)
4. Auto-hide HUD during extended silence

---

## 2. Acceptance Criteria

- [ ] Transcription hops only run when speech is detected
- [ ] Speech-to-silence transition detected within 200ms
- [ ] Finalization triggers ≤400ms after speech ends
- [ ] Silence events emitted after 3s of silence for UI to react (HUD auto-hide handled in S.03.1)
- [ ] Barge-in: new speech after finalization starts fresh segment
- [ ] CPU usage drops significantly during silence periods
- [ ] Swift 6 strict concurrency compliant

---

## 3. VAD Options Analysis

### Option A: Energy-Based VAD (Recommended for Phase 1)

Simple, low-latency, no dependencies. Works well for most environments.

**Pros:**
- Zero additional dependencies
- Sub-millisecond processing time
- Easy to tune threshold

**Cons:**
- Sensitive to ambient noise
- No speaker discrimination

### Option B: FluidAudio VAD (Available via S.03.0 Investigation)

FluidAudio includes Silero VAD. From S.03.0 investigation:

```swift
// Streaming VAD available in FluidAudio
let vadResult = manager.processStreamingChunk(chunk, state: vadState)
```

**Pros:**
- More robust to noise
- ~256ms frame detection
- Already included in FluidAudio

**Cons:**
- Requires FluidAudio initialization
- Slightly higher latency

### Recommendation

Start with **Option A (Energy VAD)** for immediate low-latency results. Add FluidAudio VAD as optional enhancement later.

---

## 4. Implementation Plan

Integrate VAD into the streaming loop (S.03.1a) so hop timers and finalization are gated by speech activity.

### Step 1: VoiceActivityDetector Protocol

Define a protocol to allow swapping VAD implementations.

```swift
import Foundation

/// Protocol for voice activity detection implementations.
protocol VoiceActivityDetector: Sendable {
    /// Process audio samples, return true if speech detected
    func process(samples: [Float], sampleRate: Double) -> Bool

    /// Reset detector state
    func reset()

    /// Current state: is speech active?
    var isSpeechActive: Bool { get }

    /// Time since last speech (for hangover/finalization)
    var silenceDuration: TimeInterval { get }
}
```

**File:** `MacTalk/MacTalk/Audio/VoiceActivityDetector.swift`

### Step 2: EnergyVAD Implementation

Thread-safe energy-based VAD with hangover logic.

```swift
import Foundation
import os.log

/// Simple energy-based voice activity detector.
/// Thread-safe via @unchecked Sendable with manual locking.
final class EnergyVAD: VoiceActivityDetector, @unchecked Sendable {
    private let logger = Logger(subsystem: "com.mactalk", category: "EnergyVAD")

    // MARK: - Configuration

    struct Config: Sendable {
        /// RMS threshold for speech detection (0.0-1.0)
        var energyThreshold: Float = 0.01

        /// Minimum speech duration to trigger detection
        var speechMinDuration: TimeInterval = 0.1

        /// Minimum silence duration before declaring end of speech
        var silenceMinDuration: TimeInterval = 0.3

        /// Number of frames to wait before declaring silence (hangover)
        var hangoverFrames: Int = 10
    }

    // MARK: - State

    private enum State: Sendable {
        case silence
        case speech
        case hangover(framesRemaining: Int)
    }

    private let lock = NSLock()
    private var _state: State = .silence
    private var _lastSpeechTime: Date?
    private var _speechStartTime: Date?
    private let config: Config

    // MARK: - VoiceActivityDetector Protocol

    var isSpeechActive: Bool {
        lock.withLock {
            switch _state {
            case .silence: return false
            case .speech, .hangover: return true
            }
        }
    }

    var silenceDuration: TimeInterval {
        lock.withLock {
            guard let lastSpeech = _lastSpeechTime else {
                return .infinity
            }
            let state = _state
            switch state {
            case .silence:
                return Date().timeIntervalSince(lastSpeech)
            case .speech, .hangover:
                return 0
            }
        }
    }

    // MARK: - Initialization

    init(config: Config = Config()) {
        self.config = config
    }

    // MARK: - Processing

    func process(samples: [Float], sampleRate: Double) -> Bool {
        guard !samples.isEmpty else { return false }

        // Calculate RMS energy
        let rms = sqrt(samples.map { $0 * $0 }.reduce(0, +) / Float(samples.count))
        let isSpeech = rms > config.energyThreshold

        return lock.withLock {
            switch _state {
            case .silence:
                if isSpeech {
                    _state = .speech
                    _speechStartTime = Date()
                    _lastSpeechTime = Date()
                    return true
                }
                return false

            case .speech:
                if isSpeech {
                    _lastSpeechTime = Date()
                    return true
                } else {
                    _state = .hangover(framesRemaining: config.hangoverFrames)
                    return true  // Still in hangover
                }

            case .hangover(let remaining):
                if isSpeech {
                    _state = .speech
                    _lastSpeechTime = Date()
                    return true
                } else if remaining > 0 {
                    _state = .hangover(framesRemaining: remaining - 1)
                    return true  // Still in hangover
                } else {
                    _state = .silence
                    return false
                }
            }
        }
    }

    func reset() {
        lock.withLock {
            _state = .silence
            _lastSpeechTime = nil
            _speechStartTime = nil
        }
    }

    // MARK: - Additional Helpers

    /// Duration of current/last speech segment
    var speechDuration: TimeInterval {
        lock.withLock {
            guard let start = _speechStartTime else { return 0 }
            return Date().timeIntervalSince(start)
        }
    }
}
```

**File:** `MacTalk/MacTalk/Audio/EnergyVAD.swift`

### Step 3: Integrate VAD into StreamingManager

Update `StreamingManager` to use VAD for optimization.

```swift
// In StreamingManager - add VAD integration

final class StreamingManager: @unchecked Sendable {
    // ... existing properties ...

    private let vad: VoiceActivityDetector

    // MARK: - VAD Callbacks

    @MainActor var onSpeechStarted: (() -> Void)?
    @MainActor var onSpeechEnded: (() -> Void)?
    @MainActor var onSilenceThresholdReached: ((TimeInterval) -> Void)?

    init(
        engine: any ASREngine,
        vad: VoiceActivityDetector = EnergyVAD(),
        config: Config = Config()
    ) {
        self.engine = engine
        self.vad = vad
        self.config = config
        // ... rest of init ...
    }

    func feedAudio(_ samples: [Float]) {
        guard isActive else { return }

        // Add to ring buffer
        audioRingBuffer.append(samples)

        // Process VAD
        let wasSpeaking = vad.isSpeechActive
        let isSpeaking = vad.process(samples: samples, sampleRate: 16000)

        // Speech state transitions
        if isSpeaking && !wasSpeaking {
            // Speech started
            Task { @MainActor [weak self] in
                self?.onSpeechStarted?()
            }
            startTranscriptionLoop()
        } else if !isSpeaking && wasSpeaking {
            // Speech ended - check for finalization
            checkForFinalization()
        }
    }

    private func checkForFinalization() {
        let silenceDuration = vad.silenceDuration

        if silenceDuration >= config.silenceThreshold {
            // Trigger finalization
            Task { [weak self] in
                guard let self = self else { return }

                // Small delay for barge-in window
                try? await Task.sleep(for: .milliseconds(200))

                // Check if user started speaking again
                if self.vad.isSpeechActive {
                    // Barge-in detected - don't finalize
                    return
                }

                await self.finalizeCurrentSegment()
            }
        }

        // Notify for HUD auto-hide
        Task { @MainActor [weak self] in
            self?.onSilenceThresholdReached?(silenceDuration)
        }
    }

    private func finalizeCurrentSegment() async {
        // Stop transcription loop
        hopTask?.cancel()

        // Final transcription
        let window = audioRingBuffer.extractWindow(seconds: config.windowDuration)
        guard window.count > 1600 else { return }

        do {
            let segments = try await transcribeWindow(window)
            if let segment = segments.first {
                await MainActor.run { [weak self] in
                    self?.onFinal?(segment)
                    self?.onSpeechEnded?()
                }
            }
        } catch {
            logger.error("Finalization failed: \(error.localizedDescription)")
        }

        // Reset differ for next segment
        stateLock.withLock {
            _differ.reset()
        }
        audioRingBuffer.reset()
    }
}
```

### Step 4: HUD Auto-Hide

Add auto-hide logic to `HUDWindowController`.

```swift
// In HUDWindowController

private var hideTimer: Timer?
private var autoHideDelay: TimeInterval = 3.0

func onSilenceDetected(duration: TimeInterval) {
    if duration > autoHideDelay && hideTimer == nil {
        hideTimer = Timer.scheduledTimer(
            withTimeInterval: 0.5,
            repeats: false
        ) { [weak self] _ in
            self?.fadeOut()
        }
    }
}

func onSpeechDetected() {
    hideTimer?.invalidate()
    hideTimer = nil
    fadeIn()
}

private func fadeOut() {
    NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.3
        window?.animator().alphaValue = 0
    } completionHandler: { [weak self] in
        self?.window?.orderOut(nil)
    }
}

private func fadeIn() {
    window?.alphaValue = 0
    window?.orderFront(nil)

    NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.15
        window?.animator().alphaValue = 1
    }
}
```

### Step 5: Barge-In Detection

Barge-in is handled in `checkForFinalization()` - if speech resumes during the finalization delay, we cancel and continue accumulating.

### Step 6: Settings Integration

```swift
extension AppSettings {
    var vadEnabled: Bool {
        get { lock.withLock { defaults.bool(forKey: "vadEnabled") } }
        set { lock.withLock { defaults.set(newValue, forKey: "vadEnabled") } }
    }

    /// VAD sensitivity: 0.0 = very sensitive, 1.0 = less sensitive
    var vadSensitivity: Float {
        get {
            lock.withLock {
                let value = defaults.float(forKey: "vadSensitivity")
                return max(0, min(value, 1))
            }
        }
        set {
            lock.withLock {
                defaults.set(max(0, min(newValue, 1)), forKey: "vadSensitivity")
            }
        }
    }

    /// Delay before HUD auto-hides (seconds)
    var hudAutoHideDelay: TimeInterval {
        get {
            lock.withLock {
                let value = defaults.double(forKey: "hudAutoHideDelay")
                return value > 0 ? max(1, min(value, 30)) : 3.0
            }
        }
        set {
            lock.withLock {
                defaults.set(max(1, min(newValue, 30)), forKey: "hudAutoHideDelay")
            }
        }
    }
}
```

---

## 5. Latency Measurements

| Event | Target Latency |
|-------|---------------|
| Speech start → first partial | <500ms |
| Speech end → finalization | <400ms |
| Barge-in → new segment start | <300ms |

---

## 6. CPU Savings

| State | Expected CPU |
|-------|-------------|
| Active speech | ~25-30% (transcription running) |
| Silence (VAD only) | ~2-5% (VAD processing only) |
| Idle (no audio) | ~0% |

---

## 7. Test Plan

### Unit Tests

```swift
// EnergyVADTests.swift
final class EnergyVADTests: XCTestCase {

    func test_detectsSpeech() {
        let vad = EnergyVAD(config: .init(energyThreshold: 0.01))

        // Loud signal
        let loudSamples = [Float](repeating: 0.5, count: 1600)
        let result = vad.process(samples: loudSamples, sampleRate: 16000)

        XCTAssertTrue(result)
        XCTAssertTrue(vad.isSpeechActive)
    }

    func test_detectsSilence() {
        let vad = EnergyVAD(config: .init(energyThreshold: 0.01))

        // Quiet signal
        let quietSamples = [Float](repeating: 0.001, count: 1600)
        let result = vad.process(samples: quietSamples, sampleRate: 16000)

        XCTAssertFalse(result)
        XCTAssertFalse(vad.isSpeechActive)
    }

    func test_hangoverLogic() {
        var config = EnergyVAD.Config()
        config.hangoverFrames = 3
        let vad = EnergyVAD(config: config)

        // Speech
        _ = vad.process(samples: [Float](repeating: 0.5, count: 160), sampleRate: 16000)
        XCTAssertTrue(vad.isSpeechActive)

        // Silence - should stay active during hangover
        for i in 0..<3 {
            let result = vad.process(samples: [Float](repeating: 0.001, count: 160), sampleRate: 16000)
            XCTAssertTrue(result, "Hangover frame \(i) should still be active")
        }

        // After hangover expires
        let final = vad.process(samples: [Float](repeating: 0.001, count: 160), sampleRate: 16000)
        XCTAssertFalse(final)
        XCTAssertFalse(vad.isSpeechActive)
    }

    func test_concurrentAccess() async {
        let vad = EnergyVAD()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    let samples = (0..<160).map { _ in Float.random(in: -1...1) }
                    _ = vad.process(samples: samples, sampleRate: 16000)
                }
                group.addTask {
                    _ = vad.isSpeechActive
                    _ = vad.silenceDuration
                }
            }
        }

        // If no crash, test passed
    }
}
```

### Integration Tests

- VAD + StreamingManager interaction
- Barge-in scenario simulation
- HUD auto-hide timing

### Manual Testing

- Test with various microphone gains
- Test in noisy environment
- Verify barge-in feels responsive

---

## 8. Files Summary

### New Files
- `MacTalk/MacTalk/Audio/VoiceActivityDetector.swift` - Protocol
- `MacTalk/MacTalk/Audio/EnergyVAD.swift` - Implementation
- `MacTalk/MacTalkTests/EnergyVADTests.swift`

### Modified Files
- `MacTalk/MacTalk/Whisper/StreamingManager.swift` - VAD integration
- `MacTalk/MacTalk/HUDWindowController.swift` - Auto-hide logic
- `MacTalk/MacTalk/Utilities/AppSettings.swift` - VAD settings
- `MacTalk/MacTalk/SettingsWindowController.swift` - VAD sensitivity slider

---

## 9. Future Enhancements

- **Adaptive threshold:** Adjust based on ambient noise level
- **FluidAudio VAD:** Optional upgrade to Silero-based VAD
- **Per-speaker VAD:** For diarization (S.03.2)
- **Noise gate:** Combine with VAD for cleaner recordings

---

## 10. Definition of Done

- [ ] All acceptance criteria met
- [ ] Unit tests pass with >80% coverage
- [ ] CPU savings verified (silence < 5%)
- [ ] Barge-in feels responsive in manual testing
- [ ] Thread Sanitizer clean run
- [ ] Swift 6 strict concurrency compliant
- [ ] Code reviewed and merged
