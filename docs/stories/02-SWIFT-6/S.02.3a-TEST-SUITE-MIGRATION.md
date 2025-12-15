# S.02.3a - Test Suite Migration for Swift 6

**Epic:** Swift 6 Migration
**Status:** Pending
**Date:** 2025-12-15
**Dependency:** S.02.3

---

## 1. Objective

Update the test suite to work with Swift 6 concurrency and validate the migration.

**Goal:** All tests pass under Swift 6 mode with Thread Sanitizer enabled, providing confidence in the migration's correctness.

---

## 2. Scope

### Test Files to Migrate

| Test File | Tests | MainActor Required | Async Required |
|-----------|-------|-------------------|----------------|
| `AudioMixerTests.swift` | 8 | No | Yes (concurrent tests) |
| `AudioCaptureIntegrationTests.swift` | 3 | No | Yes (device access) |
| `AudioLevelMonitorTests.swift` | 6 | No | Maybe |
| `HUDWindowControllerTests.swift` | 5 | Yes | No |
| `SettingsWindowControllerTests.swift` | 4 | Yes | No |
| `StatusBarControllerTests.swift` | 6 | Yes | Yes |
| `TranscriptionControllerTests.swift` | 10 | Partial | Yes |
| `WhisperEngineTests.swift` | 5 | No | Yes |
| `ParakeetEngineTests.swift` | 15 | No | Yes |
| `ModelManagerTests.swift` | 4 | Yes | Yes |
| `PermissionsTests.swift` | 3 | Yes | No |
| `Phase4IntegrationTests.swift` | 5 | Yes | Yes |
| `PermissionFlowIntegrationTests.swift` | 3 | Yes | No |
| `AppPickerIntegrationTests.swift` | 4 | Yes | Yes |

---

## 3. Implementation Plan

### Step 1: Add @MainActor to UI Tests

**Pattern for Window Controller Tests:**

```swift
// BEFORE
class HUDWindowControllerTests: XCTestCase {
    func test_hudShowsAndHides() {
        let hud = HUDWindowController()
        hud.showWindow(nil)
        XCTAssertTrue(hud.window?.isVisible == true)
    }
}

// AFTER
@MainActor
class HUDWindowControllerTests: XCTestCase {
    func test_hudShowsAndHides() {
        let hud = HUDWindowController()
        hud.showWindow(nil)
        XCTAssertTrue(hud.window?.isVisible == true)
    }
}
```

**Files Requiring @MainActor Class Annotation:**
- `HUDWindowControllerTests.swift`
- `SettingsWindowControllerTests.swift`
- `StatusBarControllerTests.swift`
- `PermissionsTests.swift`
- `PermissionFlowIntegrationTests.swift`
- `AppPickerIntegrationTests.swift`

### Step 2: Update Async Test Patterns

**Pattern for Engine Tests:**

```swift
// BEFORE
func test_transcriptionProducesOutput() {
    let expectation = expectation(description: "Transcription complete")
    var result: String?

    engine.setPartialHandler { text in
        result = text
        expectation.fulfill()
    }

    engine.process(testBuffer)

    wait(for: [expectation], timeout: 5.0)
    XCTAssertNotNil(result)
}

// AFTER
func test_transcriptionProducesOutput() async throws {
    try await engine.start()

    // Feed audio
    engine.process(testBuffer)

    // Wait for processing
    try await Task.sleep(for: .milliseconds(100))

    let segments = try await engine.stop()
    XCTAssertFalse(segments.isEmpty)
}
```

### Step 3: Update Callback Testing

**Pattern for @Sendable Callbacks:**

```swift
// BEFORE
func test_callbackReceivesPartials() {
    var receivedPartials: [String] = []

    controller.onPartial = { text in
        receivedPartials.append(text)
    }

    // Trigger transcription...
}

// AFTER
func test_callbackReceivesPartials() async {
    let receivedPartials = LockIsolated<[String]>([])

    controller.onPartial = { @Sendable text in
        receivedPartials.withValue { $0.append(text) }
    }

    // Trigger transcription...

    await Task.yield()  // Allow callbacks to execute

    XCTAssertFalse(receivedPartials.value.isEmpty)
}

// Helper for thread-safe test state
final class LockIsolated<Value>: @unchecked Sendable {
    private var _value: Value
    private let lock = NSLock()

    init(_ value: Value) {
        self._value = value
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    func withValue<T>(_ operation: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation(&_value)
    }
}
```

### Step 4: Update Integration Tests

**Pattern for StatusBarController Tests:**

```swift
// BEFORE
func test_startRecordingShowsHUD() {
    let controller = StatusBarController()

    controller.startRecording(mode: .micOnly)

    XCTAssertNotNil(controller.hudController)
    XCTAssertTrue(controller.hudController?.window?.isVisible == true)
}

// AFTER
@MainActor
func test_startRecordingShowsHUD() async throws {
    let controller = StatusBarController()

    // Start recording is now async
    try await controller.startRecording(mode: .micOnly)

    // Give UI time to appear
    try await Task.sleep(for: .milliseconds(100))

    XCTAssertNotNil(controller.hudController)
    XCTAssertTrue(controller.hudController?.window?.isVisible == true)
}
```

### Step 5: Add Concurrency Stress Tests

**New Tests to Add:**

```swift
class ConcurrencyStressTests: XCTestCase {
    /// Test rapid start/stop doesn't crash
    @MainActor
    func test_rapidStartStop() async throws {
        let controller = StatusBarController()

        for _ in 0..<20 {
            try await controller.startRecording(mode: .micOnly)
            try await Task.sleep(for: .milliseconds(50))
            controller.stopRecording()
            try await Task.sleep(for: .milliseconds(50))
        }

        // If we get here, no crash
    }

    /// Test concurrent audio processing
    func test_concurrentAudioBuffers() async {
        let mixer = AudioMixer()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    let buffer = self.createTestBuffer()
                    _ = mixer.convert(buffer: buffer)
                }
            }
        }
    }

    /// Test engine state transitions
    func test_engineStateTransitions() async throws {
        let engine = await NativeWhisperEngine(modelURL: testModelURL)

        for _ in 0..<10 {
            try await engine.start()
            engine.process(testBuffer)
            _ = try await engine.stop()
        }
    }
}
```

### Step 6: Thread Sanitizer CI Configuration

**Add to CI workflow:**

```yaml
# .github/workflows/test.yml
jobs:
  test-with-tsan:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4
      - name: Run Tests with Thread Sanitizer
        run: |
          xcodebuild test \
            -project MacTalk.xcodeproj \
            -scheme MacTalk \
            -enableThreadSanitizer YES \
            -resultBundlePath TestResults.xcresult

      - name: Check for TSan Warnings
        run: |
          # Fail if any TSan warnings found
          if xcrun xcresulttool get --path TestResults.xcresult --format json | grep -q "ThreadSanitizer"; then
            echo "Thread Sanitizer warnings found!"
            exit 1
          fi
```

---

## 4. Test Infrastructure Updates

### 4.1 Test Helper Extensions

```swift
// TestHelpers.swift

/// Wait for MainActor to process pending work
@MainActor
func flushMainActor() async {
    await Task.yield()
}

/// Create test audio buffer
func createTestBuffer(
    sampleRate: Double = 48000,
    channels: UInt32 = 1,
    frameCount: AVAudioFrameCount = 2048
) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(
        standardFormatWithSampleRate: sampleRate,
        channels: channels
    )!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
    buffer.frameLength = frameCount

    // Fill with silence or test tone
    if let channelData = buffer.floatChannelData {
        memset(channelData[0], 0, Int(frameCount) * MemoryLayout<Float>.size)
    }

    return buffer
}

/// Thread-safe expectation for async tests
actor AsyncExpectation {
    private var fulfilled = false

    func fulfill() {
        fulfilled = true
    }

    func wait(timeout: Duration = .seconds(5)) async throws {
        let deadline = ContinuousClock.now + timeout
        while !fulfilled {
            if ContinuousClock.now > deadline {
                throw TestError.timeout
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
```

### 4.2 Mock Actor for Engine Testing

```swift
/// Mock ASR engine for testing
actor MockASREngine: ASREngine {
    var isStreaming: Bool = false
    private var processedBuffers: [[Float]] = []
    private var partialHandler: (@Sendable (ASRPartial) -> Void)?

    func initialize() async throws {
        // No-op for mock
    }

    func start() async throws {
        isStreaming = true
        processedBuffers = []
    }

    func stop() async throws -> [ASRFinalSegment] {
        isStreaming = false
        return [ASRFinalSegment(
            text: "Mock transcription",
            startTime: 0,
            endTime: 1,
            words: nil
        )]
    }

    nonisolated func process(_ buffer: AVAudioPCMBuffer) {
        Task {
            await self.processBuffer(buffer)
        }
    }

    private func processBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let samples = Array(UnsafeBufferPointer(
            start: channelData[0],
            count: Int(buffer.frameLength)
        ))
        processedBuffers.append(samples)

        // Simulate partial callback
        partialHandler?(ASRPartial(text: "Partial \(processedBuffers.count)"))
    }

    nonisolated func setPartialHandler(_ handler: @escaping @Sendable (ASRPartial) -> Void) {
        Task {
            await self.setHandler(handler)
        }
    }

    private func setHandler(_ handler: @escaping @Sendable (ASRPartial) -> Void) {
        partialHandler = handler
    }

    // Test inspection methods
    func getProcessedBufferCount() -> Int {
        processedBuffers.count
    }
}
```

---

## 5. Acceptance Criteria

- [ ] All test files compile with Swift 6
- [ ] All tests pass (100% pass rate)
- [ ] Thread Sanitizer enabled in test scheme
- [ ] Zero TSan warnings from MacTalk code
- [ ] Concurrency stress tests added
- [ ] CI updated to run TSan tests
- [ ] Test helpers updated for async patterns

---

## 6. Testing Strategy

### Validation Sequence

1. **Compile Tests:**
   ```bash
   xcodebuild build-for-testing \
     -project MacTalk.xcodeproj \
     -scheme MacTalk
   ```

2. **Run Without TSan (Quick Validation):**
   ```bash
   xcodebuild test \
     -project MacTalk.xcodeproj \
     -scheme MacTalk
   ```

3. **Run With TSan (Full Validation):**
   ```bash
   xcodebuild test \
     -project MacTalk.xcodeproj \
     -scheme MacTalk \
     -enableThreadSanitizer YES
   ```

4. **Performance Baseline:**
   ```bash
   xcodebuild test \
     -project MacTalk.xcodeproj \
     -scheme MacTalk \
     -only-testing:MacTalkTests/PerformanceTests
   ```

### Expected TSan Suppressions

```
# tsan_suppressions.txt (for Apple framework internals only)
race:AVAudioEngine
race:SCStream
race:AudioConverterFillComplexBuffer
race:ggml_metal_*
```

**Rule:** Never suppress TSan warnings in MacTalk code.

---

## 7. Risk Assessment

**Risk Level: LOW**

| Risk | Impact | Likelihood | Mitigation |
|------|--------|------------|------------|
| Test compilation failures | Blocks CI | High (expected) | Fix systematically |
| Test logic changes | False passes | Low | Review each change |
| TSan false positives | Noise | Medium | Document suppressions |
| Performance impact | Slow CI | Low | Separate TSan job |

**Estimated Effort:** 4-6 hours

---

## 8. Documentation Updates

After this story, update:

- [ ] `CLAUDE.md` - Add TSan testing instructions
- [ ] Test file headers - Document MainActor requirements
- [ ] CI documentation - TSan workflow
