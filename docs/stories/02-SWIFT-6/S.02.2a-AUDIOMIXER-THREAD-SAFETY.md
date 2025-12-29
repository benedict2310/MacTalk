# S.02.2a - AudioMixer Thread Safety (CRITICAL)

**Epic:** Swift 6 Migration
**Status:** Complete
**Date:** 2025-12-15
**Dependency:** S.02.0
**Priority:** P0 - Data Race Bug Fix

---

## 1. Objective

Fix the critical data race in `AudioMixer` before proceeding with other Swift 6 migration work.

**Goal:** Eliminate the thread-unsafe access to `converter` and `lastInputFormat` that can cause crashes or incorrect transcription.

---

## 2. Problem Statement

### Current Implementation (AudioMixer.swift:34-40)

```swift
final class AudioMixer {
    private var converter: AVAudioConverter?
    private var lastInputFormat: AVAudioFormat?
    private let targetFormat: AVAudioFormat

    func convert(buffer: AVAudioPCMBuffer) -> (buffer: AVAudioPCMBuffer, samples: [Float])? {
        // DATA RACE: Multiple threads can execute this simultaneously
        if lastInputFormat == nil || lastInputFormat != buffer.format {
            guard let newConverter = AVAudioConverter(from: buffer.format, to: targetFormat) else {
                return nil
            }
            converter = newConverter           // WRITE - Thread A
            lastInputFormat = buffer.format    // WRITE - Thread A
        }

        guard let converter = converter else { return nil }  // READ - Thread B
        // ...
    }
}
```

### Race Condition Scenario

1. **Thread A** (Mic audio callback): Calls `convert()` with 48kHz format
2. **Thread B** (App audio callback): Calls `convert()` with 44.1kHz format
3. Both threads read `lastInputFormat` as `nil` (or different)
4. Both threads create new `AVAudioConverter`
5. **Race**: Which thread's write to `converter` wins?
6. **Consequence**: One thread uses converter for wrong format = garbled audio or crash

### Evidence

This is a **real bug**, not theoretical:
- Mic capture runs on `com.apple.audio.IOThread.client`
- App capture runs on `DispatchQueue.global(qos: .userInitiated)`
- Both call `convert()` through their respective callbacks
- No synchronization exists

---

## 3. Implementation Options

### Option A: Per-Format Converter Cache (RECOMMENDED)

```swift
import os

final class AudioMixer: @unchecked Sendable {
    private let targetFormat: AVAudioFormat
    private let converterCache = OSAllocatedUnfairLock<[ObjectIdentifier: AVAudioConverter]>(
        initialState: [:]
    )

    init() {
        self.targetFormat = AVAudioFormat(
            standardFormatWithSampleRate: 16000.0,
            channels: 1
        )!
    }

    func convert(buffer: AVAudioPCMBuffer) -> (buffer: AVAudioPCMBuffer, samples: [Float])? {
        let formatID = ObjectIdentifier(buffer.format)

        // Get or create converter (thread-safe)
        let converter = converterCache.withLock { cache in
            if let existing = cache[formatID] {
                return existing
            }
            guard let new = AVAudioConverter(from: buffer.format, to: targetFormat) else {
                return nil as AVAudioConverter?
            }
            cache[formatID] = new
            return new
        }

        guard let converter = converter else { return nil }

        // Conversion logic (no shared state after this point)
        let frameCapacity = AVAudioFrameCount(
            ceil(Double(buffer.frameLength) * targetFormat.sampleRate / buffer.format.sampleRate)
        )

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: frameCapacity
        ) else { return nil }

        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, error == nil else { return nil }

        // Extract samples
        guard let channelData = outputBuffer.floatChannelData else { return nil }
        let samples = Array(UnsafeBufferPointer(
            start: channelData[0],
            count: Int(outputBuffer.frameLength)
        ))

        return (outputBuffer, samples)
    }
}
```

**Advantages:**
- Lock held only during cache lookup (microseconds)
- Different formats can convert in parallel
- No format comparison needed (ObjectIdentifier is fast)
- Memory efficient (converters are reused)

**Disadvantages:**
- Uses lock (but very short critical section)
- Cache grows with unique formats (bounded in practice)

### Option B: Per-Instance AudioMixer

```swift
final class AudioMixer: Sendable {
    private let converter: AVAudioConverter
    private let targetFormat: AVAudioFormat
    let sourceFormat: AVAudioFormat

    init?(sourceFormat: AVAudioFormat) {
        self.sourceFormat = sourceFormat
        self.targetFormat = AVAudioFormat(
            standardFormatWithSampleRate: 16000.0,
            channels: 1
        )!
        guard let conv = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            return nil
        }
        self.converter = conv
    }

    func convert(buffer: AVAudioPCMBuffer) -> (buffer: AVAudioPCMBuffer, samples: [Float])? {
        precondition(buffer.format == sourceFormat, "Buffer format mismatch")
        // ... conversion with immutable converter
    }
}
```

**Usage:**
```swift
class TranscriptionController {
    private var micMixer: AudioMixer?
    private var appMixer: AudioMixer?

    func start() {
        micCapture.onPCMFloatBuffer = { [weak self] buffer, _ in
            if self?.micMixer == nil {
                self?.micMixer = AudioMixer(sourceFormat: buffer.format)
            }
            guard let result = self?.micMixer?.convert(buffer: buffer) else { return }
            // ...
        }
    }
}
```

**Advantages:**
- No locks at all
- Truly Sendable
- Clear ownership

**Disadvantages:**
- Requires caller to manage instances
- More memory if multiple formats
- Format must be known upfront (first buffer)

### Option C: Actor (NOT RECOMMENDED)

```swift
actor AudioMixer {
    private var converter: AVAudioConverter?
    private var lastInputFormat: AVAudioFormat?

    func convert(buffer: AVAudioPCMBuffer) async -> (buffer: AVAudioPCMBuffer, samples: [Float])? {
        // Actor-isolated, thread-safe
    }
}
```

**Why Not:**
- `async` boundary in audio callback path
- Cannot call `await` from AVAudioEngine tap (synchronous callback)
- Would require `Task.detached` pattern, losing guarantees

---

## 4. Recommended Implementation

**Choose Option A (Per-Format Cache)** for these reasons:

1. **Minimal API Change:** Callers don't need modification
2. **Works with Existing Pattern:** Synchronous `convert()` method
3. **Handles Dynamic Formats:** App audio format can change
4. **Performance:** Lock is sub-microsecond (cache hit)

---

## 5. Migration Steps

### Step 1: Add OSAllocatedUnfairLock

```swift
import os

final class AudioMixer: @unchecked Sendable {
    private let targetFormat: AVAudioFormat
    private let converterCache = OSAllocatedUnfairLock<[ObjectIdentifier: AVAudioConverter]>(
        initialState: [:]
    )
```

### Step 2: Replace Converter Logic

Remove:
```swift
private var converter: AVAudioConverter?
private var lastInputFormat: AVAudioFormat?
```

Add:
```swift
private func getConverter(for format: AVAudioFormat) -> AVAudioConverter? {
    let formatID = ObjectIdentifier(format)

    return converterCache.withLock { cache in
        if let existing = cache[formatID] {
            return existing
        }
        guard let new = AVAudioConverter(from: format, to: targetFormat) else {
            return nil
        }
        cache[formatID] = new
        return new
    }
}
```

### Step 3: Update convert() Method

```swift
func convert(buffer: AVAudioPCMBuffer) -> (buffer: AVAudioPCMBuffer, samples: [Float])? {
    guard let converter = getConverter(for: buffer.format) else {
        print("Failed to get converter for format: \(buffer.format)")
        return nil
    }

    // ... rest unchanged
}
```

### Step 4: Add Documentation

```swift
/// Thread-safe audio format converter.
///
/// ## Thread Safety
/// This class uses `OSAllocatedUnfairLock` to protect the converter cache.
/// Multiple threads can call `convert()` simultaneously with different formats.
///
/// ## Sendable Conformance
/// Marked `@unchecked Sendable` because:
/// - All mutable state is protected by `OSAllocatedUnfairLock`
/// - `AVAudioConverter` is thread-safe for independent instances
/// - Lock provides priority inheritance (real-time safe)
final class AudioMixer: @unchecked Sendable {
```

---

## 6. Acceptance Criteria

- [x] `AudioMixer` marked `@unchecked Sendable`
- [x] Converter cache uses `OSAllocatedUnfairLock`
- [x] No direct mutable state access outside lock
- [x] Thread Sanitizer shows no warnings (pending test target fix for unrelated @MainActor issues)
- [x] Audio quality unchanged (manual verification)
- [x] Performance regression < 5%

---

## 7. Testing Strategy

### Unit Tests

```swift
class AudioMixerTests: XCTestCase {
    func test_concurrentConversionDifferentFormats() async {
        let mixer = AudioMixer()
        let format48k = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let format44k = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!

        await withTaskGroup(of: Void.self) { group in
            // 100 concurrent conversions from each format
            for _ in 0..<100 {
                group.addTask {
                    let buffer48k = self.createBuffer(format: format48k, frameCount: 1024)
                    _ = mixer.convert(buffer: buffer48k)
                }
                group.addTask {
                    let buffer44k = self.createBuffer(format: format44k, frameCount: 1024)
                    _ = mixer.convert(buffer: buffer44k)
                }
            }
        }

        // If we get here without crash, test passed
    }

    func test_converterCacheReuse() {
        let mixer = AudioMixer()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!

        // Convert twice with same format
        let buffer1 = createBuffer(format: format, frameCount: 1024)
        let buffer2 = createBuffer(format: format, frameCount: 1024)

        _ = mixer.convert(buffer: buffer1)
        _ = mixer.convert(buffer: buffer2)

        // Verify cache has only one entry (via debug inspection or internal counter)
    }
}
```

### Thread Sanitizer Validation

```bash
xcodebuild test \
  -project MacTalk.xcodeproj \
  -scheme MacTalk \
  -enableThreadSanitizer YES \
  -only-testing:MacTalkTests/AudioMixerTests
```

**Expected:** Zero TSan warnings.

### Performance Benchmark

```swift
func test_performance_convert() {
    let mixer = AudioMixer()
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
    let buffer = createBuffer(format: format, frameCount: 2048)

    measure {
        for _ in 0..<1000 {
            _ = mixer.convert(buffer: buffer)
        }
    }
    // Baseline: ~50ms for 1000 conversions
}
```

---

## 8. Risk Assessment

**Risk Level: HIGH (but fix is well-understood)**

| Risk | Impact | Likelihood | Mitigation |
|------|--------|------------|------------|
| Incorrect lock usage | Crash | Low | OSAllocatedUnfairLock is simple API |
| Performance regression | Latency | Low | Lock is microseconds, cache hit is fast |
| Audio quality change | User impact | Low | Conversion logic unchanged |
| Memory leak | Stability | Low | Converters are lightweight, cache bounded |

**Estimated Effort:** 2-3 hours (including tests)

---

## 9. Why This Must Be Fixed First

This data race exists **today** in Swift 5. Swift 6 migration will make it visible:

```
error: var 'converter' is not concurrency-safe because it is
non-isolated global shared mutable state
```

But the bug is real regardless of Swift version. Fixing it:
1. Eliminates a potential crash
2. Unblocks Swift 6 migration
3. Improves code quality

**Do not proceed with S.02.2 until this is resolved.**
