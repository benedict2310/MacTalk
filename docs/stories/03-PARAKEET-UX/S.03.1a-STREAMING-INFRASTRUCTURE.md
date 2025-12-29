# S.03.1a - Streaming Transcription Infrastructure

**Epic:** Real-Time Streaming Transcription
**Status:** Ready for Implementation
**Date:** 2025-12-21 (Updated)
**Dependency:** S.03.0-FOUNDATION-RECOVERY, S.02.3 (Swift 6)
**Priority:** Critical (Foundation for all streaming features)

---

## 1. Objective

Implement the core streaming infrastructure that enables real-time "type-as-you-speak" dictation with Parakeet.

**Goal:** Emit partial transcriptions every 200-400ms with finalization ≤300ms after speech pause.

UI presentation is handled in S.03.1; this story focuses on infrastructure and callbacks only.

---

## 2. Acceptance Criteria

- [ ] Partial transcriptions emitted every 200-400ms during active speech
- [ ] Final segment emitted ≤300ms after user stops speaking
- [ ] Partials are stable (minimal flickering/rewrites)
- [ ] Partial updates are surfaced via callback for UI integration (HUD/caption handled in S.03.1)
- [ ] Memory usage remains stable during long sessions (>10 min)
- [ ] CPU usage acceptable on M1 (target: <30% during active transcription)
- [ ] All code Swift 6 compliant with strict concurrency

---

## 3. Architecture

```
┌─────────────┐     ┌──────────────────┐     ┌─────────────────┐
│ AudioMixer  │────►│ StreamingManager │────►│ ParakeetEngine  │
│ (16kHz mono)│     │                  │     │ (batch transc.) │
└─────────────┘     │ - Ring buffer    │     └────────┬────────┘
                    │ - Hop timer      │              │
                    │ - Diff engine    │◄─────────────┘
                    └────────┬─────────┘       Result
                             │
                    ┌────────▼─────────┐
                    │ PartialEmitter   │
                    │ - Dedup/diff     │
                    │ - Stability      │
                    └────────┬─────────┘
                             │
                    ┌────────▼─────────┐
                    │ HUD / Callbacks  │
                    └──────────────────┘
```

---

## 4. Implementation Plan

### Step 1: StreamingRingBuffer (Thread-Safe)

A specialized ring buffer for streaming audio with timestamp tracking, compliant with Swift 6.

```swift
import Foundation
import os.log

/// Thread-safe ring buffer optimized for streaming transcription.
/// Uses OSAllocatedUnfairLock for Swift 6 Sendable compliance.
final class StreamingRingBuffer: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.mactalk", category: "StreamingRingBuffer")

    private var buffer: [Float]
    private let capacity: Int
    private var writeIndex: Int = 0
    private var sampleCount: Int = 0
    private let lock = NSLock()

    /// Initialize with capacity in samples (e.g., 192000 for 12s at 16kHz)
    init(capacity: Int) {
        self.capacity = capacity
        self.buffer = [Float](repeating: 0, count: capacity)
    }

    /// Convenience initializer for duration at sample rate
    convenience init(durationSeconds: TimeInterval, sampleRate: Double = 16000) {
        self.init(capacity: Int(durationSeconds * sampleRate))
    }

    /// Append new audio samples (thread-safe)
    func append(_ samples: [Float]) {
        lock.withLock {
            for sample in samples {
                buffer[writeIndex] = sample
                writeIndex = (writeIndex + 1) % capacity
                sampleCount = min(sampleCount + 1, capacity)
            }
        }
    }

    /// Extract the last N seconds of audio (thread-safe)
    func extractWindow(seconds: TimeInterval, sampleRate: Double = 16000) -> [Float] {
        let requestedSamples = min(Int(seconds * sampleRate), capacity)

        return lock.withLock {
            let availableSamples = min(requestedSamples, sampleCount)
            guard availableSamples > 0 else { return [] }

            var result = [Float](repeating: 0, count: availableSamples)
            let startIndex = (writeIndex - availableSamples + capacity) % capacity

            for i in 0..<availableSamples {
                result[i] = buffer[(startIndex + i) % capacity]
            }

            return result
        }
    }

    /// Current duration of buffered audio
    var duration: TimeInterval {
        lock.withLock {
            Double(sampleCount) / 16000.0
        }
    }

    /// Clear the buffer (thread-safe)
    func reset() {
        lock.withLock {
            sampleCount = 0
            writeIndex = 0
        }
    }
}
```

**File:** `MacTalk/MacTalk/Audio/StreamingRingBuffer.swift`

### Step 2: PartialDiffer (Text Stability)

Intelligent diffing to emit only new text and prevent flickering.

```swift
import Foundation

/// Handles text diffing and stability for streaming output.
/// Value type - no Sendable concerns.
struct PartialDiffer {
    private var confirmedText: String = ""
    private var pendingText: String = ""
    private var stabilityCount: Int = 0

    /// Stability threshold - how many consistent results before confirming
    var stabilityThreshold: Int = 2

    /// Process new transcription result, return delta to emit
    mutating func process(newText: String) -> (delta: String, isStable: Bool) {
        // Find common prefix with confirmed text
        let commonPrefix = confirmedText.commonPrefix(with: newText)

        // New text after confirmed portion
        let newPortion = String(newText.dropFirst(commonPrefix.count))

        // Stability: if same result N times, consider it stable
        if newPortion == pendingText {
            stabilityCount += 1
        } else {
            pendingText = newPortion
            stabilityCount = 1
        }

        let isStable = stabilityCount >= stabilityThreshold
        if isStable {
            confirmedText = newText
        }

        return (delta: newPortion, isStable: isStable)
    }

    /// Finalize current state - mark pending as confirmed
    mutating func finalize() {
        confirmedText += pendingText
        pendingText = ""
        stabilityCount = 0
    }

    /// Reset for new session
    mutating func reset() {
        confirmedText = ""
        pendingText = ""
        stabilityCount = 0
    }

    /// Get full accumulated text
    var fullText: String {
        confirmedText + pendingText
    }
}
```

**File:** `MacTalk/MacTalk/Whisper/PartialDiffer.swift`

### Step 3: StreamingManager (Core Controller)

Main class managing the rolling-window transcription loop.

```swift
import AVFoundation
import os.log

/// Manages real-time streaming transcription using rolling windows.
/// Conforms to Sendable via manual thread-safety.
final class StreamingManager: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.mactalk", category: "StreamingManager")

    // MARK: - Configuration

    struct Config: Sendable {
        var windowDuration: TimeInterval = 10.0  // Context window size
        var hopInterval: TimeInterval = 0.32     // Time between transcriptions
        var silenceThreshold: TimeInterval = 0.4 // Pause before finalization
        var minAudioDuration: TimeInterval = 0.5 // Min audio before transcribing
    }

    // MARK: - State (protected by lock)

    private let stateLock = NSLock()
    private var _isActive: Bool = false
    private var _differ = PartialDiffer()

    private var isActive: Bool {
        get { stateLock.withLock { _isActive } }
        set { stateLock.withLock { _isActive = newValue } }
    }

    // MARK: - Components

    private let audioRingBuffer: StreamingRingBuffer
    private let engine: any ASREngine
    private let config: Config

    private var hopTask: Task<Void, Never>?

    // MARK: - Callbacks (MainActor isolated)

    @MainActor var onPartial: ((String) -> Void)?
    @MainActor var onFinal: ((ASRFinalSegment) -> Void)?
    @MainActor var onError: ((Error) -> Void)?

    // MARK: - Initialization

    init(engine: any ASREngine, config: Config = Config()) {
        self.engine = engine
        self.config = config
        self.audioRingBuffer = StreamingRingBuffer(
            durationSeconds: config.windowDuration + 2.0
        )
    }

    // MARK: - Public API

    func start() {
        logger.info("Starting streaming manager")
        isActive = true
        stateLock.withLock { _differ.reset() }
        audioRingBuffer.reset()
        startTranscriptionLoop()
    }

    func stop() async -> ASRFinalSegment? {
        logger.info("Stopping streaming manager")
        isActive = false
        hopTask?.cancel()
        hopTask = nil

        // Final transcription of remaining audio
        let window = audioRingBuffer.extractWindow(seconds: config.windowDuration)
        guard window.count > 1600 else { return nil } // At least 0.1s

        do {
            let segments = try await transcribeWindow(window)
            if let segment = segments.first {
                await MainActor.run { [weak self] in
                    self?.onFinal?(segment)
                }
                return segment
            }
        } catch {
            logger.error("Final transcription failed: \(error.localizedDescription)")
        }

        return nil
    }

    func feedAudio(_ samples: [Float]) {
        guard isActive else { return }
        audioRingBuffer.append(samples)
    }

    func feedAudio(_ buffer: AVAudioPCMBuffer) {
        guard isActive,
              let channelData = buffer.floatChannelData?[0] else { return }

        let samples = Array(UnsafeBufferPointer(
            start: channelData,
            count: Int(buffer.frameLength)
        ))
        feedAudio(samples)
    }

    // MARK: - Transcription Loop

    private func startTranscriptionLoop() {
        hopTask = Task { [weak self] in
            guard let self = self else { return }

            while !Task.isCancelled && self.isActive {
                await self.transcriptionHop()

                // Wait for next hop interval
                try? await Task.sleep(for: .milliseconds(Int(self.config.hopInterval * 1000)))
            }
        }
    }

    private func transcriptionHop() async {
        // Check minimum audio duration
        guard audioRingBuffer.duration >= config.minAudioDuration else {
            return
        }

        // Extract current window
        let window = audioRingBuffer.extractWindow(seconds: config.windowDuration)
        guard window.count > Int(config.minAudioDuration * 16000) else {
            return
        }

        do {
            let segments = try await transcribeWindow(window)

            if let segment = segments.first {
                let result = stateLock.withLock {
                    _differ.process(newText: segment.text)
                }

                if !result.delta.isEmpty {
                    await MainActor.run { [weak self] in
                        self?.onPartial?(result.delta)
                    }
                }
            }
        } catch {
            logger.error("Transcription hop failed: \(error.localizedDescription)")
        }
    }

    private func transcribeWindow(_ samples: [Float]) async throws -> [ASRFinalSegment] {
        // Create PCM buffer for engine
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else {
            throw StreamingError.bufferCreationFailed
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { ptr in
            buffer.floatChannelData?[0].update(from: ptr.baseAddress!, count: samples.count)
        }

        // Feed to engine and get result
        try await engine.start()
        engine.process(buffer)
        return try await engine.stop()
    }
}

enum StreamingError: Error, LocalizedError {
    case bufferCreationFailed

    var errorDescription: String? {
        switch self {
        case .bufferCreationFailed: return "Failed to create audio buffer"
        }
    }
}
```

**File:** `MacTalk/MacTalk/Whisper/StreamingManager.swift`

### Step 4: HUD Integration

Update `HUDWindowController` to handle streaming partials with visual distinction.

```swift
// In HUDWindowController - Add partial display support

/// Update with partial (in-progress) transcription
func updatePartial(_ text: String) {
    // Show partial with visual distinction (lighter color)
    textField.stringValue = text
    textField.textColor = NSColor.white.withAlphaComponent(0.7)
}

/// Update with final (confirmed) transcription
func updateFinal(_ segment: ASRFinalSegment) {
    textField.stringValue = segment.text
    textField.textColor = .white

    // Brief pulse animation to indicate finalization
    NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.1
        textField.animator().alphaValue = 0.5
    } completionHandler: { [weak self] in
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            self?.textField.animator().alphaValue = 1.0
        }
    }
}
```

### Step 5: StatusBarController Integration

Wire `StreamingManager` into recording flow.

```swift
// In StatusBarController

private var streamingManager: StreamingManager?

func startRecording() {
    // Check if streaming mode is enabled and Parakeet is active
    if AppSettings.shared.provider == .parakeet {
        startStreamingMode()
    } else {
        startBatchMode()
    }
}

private func startStreamingMode() {
    guard let engine = engine else { return }

    streamingManager = StreamingManager(engine: engine)

    streamingManager?.onPartial = { [weak self] partial in
        self?.hudController?.updatePartial(partial)
    }

    streamingManager?.onFinal = { [weak self] segment in
        self?.hudController?.updateFinal(segment)
        self?.clipboardManager?.copy(segment.text)
        if AppSettings.shared.autoPaste {
            self?.clipboardManager?.paste()
        }
    }

    // Start audio capture and feed to streaming manager
    audioCapture.onPCMFloatBuffer = { [weak self] buffer, _ in
        if let samples = self?.audioMixer.convert(buffer: buffer) {
            self?.streamingManager?.feedAudio(samples.samples)
        }
    }

    streamingManager?.start()
    audioCapture.start()
}

func stopRecording() {
    Task {
        let finalSegment = await streamingManager?.stop()
        streamingManager = nil
        audioCapture.stop()

        await MainActor.run { [weak self] in
            if let segment = finalSegment {
                self?.hudController?.updateFinal(segment)
            }
        }
    }
}
```

### Step 6: Configuration & Settings

Add streaming settings to `AppSettings`:

```swift
extension AppSettings {
    var streamingEnabled: Bool {
        get { lock.withLock { defaults.bool(forKey: "streamingEnabled") } }
        set { lock.withLock { defaults.set(newValue, forKey: "streamingEnabled") } }
    }

    var streamingHopInterval: TimeInterval {
        get {
            lock.withLock {
                let value = defaults.double(forKey: "streamingHopInterval")
                return value > 0 ? max(0.2, min(value, 1.0)) : 0.32
            }
        }
        set {
            lock.withLock {
                defaults.set(max(0.2, min(newValue, 1.0)), forKey: "streamingHopInterval")
            }
        }
    }
}
```

---

## 5. Performance Targets

| Metric | Target | Measurement Method |
|--------|--------|-------------------|
| Partial latency | <400ms | Time from speech to HUD update |
| Final latency | <300ms after pause | Time from silence to final output |
| CPU (M1) | <30% | Activity Monitor during 1min session |
| Memory growth | <50MB/hour | Instruments leak check |
| Transcription RTF | >50x | Audio duration / processing time |

---

## 6. Test Plan

### Unit Tests

```swift
// StreamingRingBufferTests.swift
final class StreamingRingBufferTests: XCTestCase {

    func test_append_and_extract() {
        let buffer = StreamingRingBuffer(capacity: 100)
        let samples: [Float] = Array(0..<50).map { Float($0) }

        buffer.append(samples)
        let extracted = buffer.extractWindow(seconds: 0.003, sampleRate: 16000)

        XCTAssertEqual(extracted.count, 48)  // 0.003 * 16000
    }

    func test_wraparound() {
        let buffer = StreamingRingBuffer(capacity: 10)

        // Append more than capacity
        for i in 0..<15 {
            buffer.append([Float(i)])
        }

        let extracted = buffer.extractWindow(seconds: 1.0, sampleRate: 10)
        XCTAssertEqual(extracted, [5, 6, 7, 8, 9, 10, 11, 12, 13, 14].map { Float($0) })
    }

    func test_concurrent_access() async {
        let buffer = StreamingRingBuffer(capacity: 10000)

        await withTaskGroup(of: Void.self) { group in
            // Writers
            for i in 0..<10 {
                group.addTask {
                    for j in 0..<100 {
                        buffer.append([Float(i * 100 + j)])
                    }
                }
            }

            // Readers
            for _ in 0..<5 {
                group.addTask {
                    for _ in 0..<100 {
                        _ = buffer.extractWindow(seconds: 0.1)
                    }
                }
            }
        }

        // If we get here without crash, test passed
    }
}

// PartialDifferTests.swift
final class PartialDifferTests: XCTestCase {

    func test_basic_diffing() {
        var differ = PartialDiffer()

        let result1 = differ.process(newText: "Hello")
        XCTAssertEqual(result1.delta, "Hello")

        let result2 = differ.process(newText: "Hello world")
        XCTAssertEqual(result2.delta, " world")
    }

    func test_stability_detection() {
        var differ = PartialDiffer()
        differ.stabilityThreshold = 2

        _ = differ.process(newText: "Hello")
        XCTAssertFalse(differ.process(newText: "Hello").isStable)
        XCTAssertTrue(differ.process(newText: "Hello").isStable)
    }
}
```

### Integration Tests

- End-to-end streaming with mock audio
- Memory stability over simulated long session
- Thread safety under concurrent access

### Manual Testing

- Real microphone input, verify partials appear smoothly
- Test various speech patterns (fast, slow, pauses)
- Verify partial callbacks are emitted at the configured hop interval

---

## 7. Files Summary

### New Files
- `MacTalk/MacTalk/Whisper/StreamingManager.swift`
- `MacTalk/MacTalk/Audio/StreamingRingBuffer.swift`
- `MacTalk/MacTalk/Whisper/PartialDiffer.swift`
- `MacTalk/MacTalkTests/StreamingRingBufferTests.swift`
- `MacTalk/MacTalkTests/PartialDifferTests.swift`
- `MacTalk/MacTalkTests/StreamingManagerTests.swift`

### Modified Files
- `MacTalk/MacTalk/TranscriptionController.swift` - Streaming loop integration
- `MacTalk/MacTalk/StatusBarController.swift` - Streaming mode wiring
- `MacTalk/MacTalk/Utilities/AppSettings.swift` - Streaming settings

---

## 8. Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| FluidAudio latency too high | Fall back to longer hop intervals; document limitations |
| Text instability/flickering | Increase stability threshold; add word-boundary alignment |
| Memory growth from buffer | Fixed-size ring buffer with hard cap |
| CPU spikes on older Macs | Make hop interval configurable; add quality presets |
| Swift 6 callback isolation | Use @MainActor for UI callbacks; verify with TSan |

---

## 9. Apple HIG Compliance

UI-specific HIG guidance for partial/final presentation is handled in S.03.1.

---

## 10. Definition of Done

- [ ] All acceptance criteria met
- [ ] Unit tests pass (>80% coverage for new code)
- [ ] Integration test demonstrates 10-minute stable session
- [ ] Performance targets verified on M1 Mac
- [ ] Thread Sanitizer clean run
- [ ] Swift 6 strict concurrency compliant
- [ ] Code reviewed and merged
- [ ] Documentation updated
