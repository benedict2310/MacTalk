# S.01.1 - ASR Abstraction Layer

**Epic:** Add Parakeet (Core ML) Provider
**Status:** Done
**Date:** 2025-10-27

---

## 1. Objective
Refactor the `TranscriptionController` and `WhisperEngine` to decouple the app logic from the specific implementation of the inference engine.

**Goal:** Introduce an `ASREngine` protocol so the app can support multiple providers (Native Whisper, Parakeet Core ML) interchangeably.

---

## 2. Implementation Plan

### Step 1: Define the Protocol
Create `Audio/ASREngine.swift` with structures to support rich timestamps:

```swift
// Common structures to unify output from Whisper and Parakeet
struct ASRPartial {
    let text: String
}

struct ASRFinalSegment {
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let words: [ASRWord]?
}

struct ASRWord {
    let word: String
    let startTime: TimeInterval
    let endTime: TimeInterval
}

protocol ASREngine: AnyObject {
    // Is the engine currently processing audio?
    var isStreaming: Bool { get }
    
    // Initialize/Warm up models (async)
    func initialize() async throws
    
    // Start a session
    func start() async throws
    
    // Stop and return final text/segments
    func stop() async throws -> [ASRFinalSegment]
    
    // Process incoming audio buffer (from Mic/RingBuffer)
    func process(_ buffer: AVAudioPCMBuffer)
    
    // Optional: Streaming callback registration
    func setPartialHandler(_ handler: @escaping (ASRPartial) -> Void)
}
```

### Step 2: Adapt `WhisperEngine`
1.  Rename `WhisperEngine` to `NativeWhisperEngine`.
2.  Conform it to `ASREngine`.
3.  Map its existing string output to `ASRFinalSegment` (Whisper CPP supports timestamps, we just need to expose them).

### Step 3: Refactor `TranscriptionController`
1.  Change property type: `let engine: WhisperEngine` -> `var engine: any ASREngine`.
2.  Initialize `engine` with `NativeWhisperEngine` by default.
3.  Update all call sites to use the protocol interface.

### Step 4: Verify
*   Run Unit Tests (`TranscriptionControllerTests`).
*   Manual Test: Ensure the app still transcribes using Whisper exactly as before.

---

## 3. Acceptance Criteria
*   [x] `ASREngine` protocol exists.
*   [x] `NativeWhisperEngine` conforms to `ASREngine`.
*   [x] `TranscriptionController` does not reference `NativeWhisperEngine` directly except in initialization.
*   [x] App builds and transcribes audio successfully.

---

## 4. Test Results

All 30 ASR-related tests pass successfully:

- **NativeWhisperEngineTests:** 5 tests ✅
- **ParakeetEngineTests:** 15 tests ✅
- **TranscriptionControllerTests:** 10 tests ✅

The ASR abstraction layer is fully functional and verified.