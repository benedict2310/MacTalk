# S.02.3 - Swift 6 Mode Enablement

**Epic:** Swift 6 Migration
**Status:** Pending
**Dependency:** S.02.2

---

## 1. Objective
Finalize the migration by enabling Swift 6 language mode.

**Goal:** The project compiles and runs with `SWIFT_VERSION = 6.0`.

---

## 2. Implementation Plan

### Step 1: Enable Swift 6
1.  Update `project.yml`: `SWIFT_VERSION: "6.0"`.
2.  Regenerate project.

### Step 2: Final Polish
1.  Address any new errors that upgraded from warnings.
2.  Verify C++ Interoperability (`WhisperBridge`) is still behaving correctly with the new memory model.

---

## 3. Acceptance Criteria
*   [ ] App compiles in Swift 6 mode.
*   [ ] Zero warnings.
*   [ ] Full regression test pass (Audio, Inference, UI).

---

## 4. Breaking Changes Audit

### 4.1 Concurrency & Data Race Safety

**HIGH RISK - Data Race Potential:**

1. **StatusBarController.swift** (Lines 67-98)
   - **Issue**: Manual locking with `NSLock` for `_engineState` and `_isRecording`
   - **Swift 6 Impact**: Data races will become compile-time errors
   - **Fix Required**: Convert to `actor` or use `@MainActor` isolation
   - **Affected Code**:
     ```swift
     private var _engineState: EngineState = .idle
     private var _isRecording = false
     private let stateLock = NSLock()
     ```

2. **WhisperEngine.swift** (Lines 67-84)
   - **Issue**: Manual `NSLock` for `_isStreaming`, `audioChunk`, `allAudio`
   - **Swift 6 Impact**: Concurrent access to mutable state without proper isolation
   - **Fix Required**: Refactor to use `actor` for state management
   - **Affected Code**:
     ```swift
     private var _isStreaming: Bool = false
     private let stateLock = NSLock()
     private var audioChunk: [Float] = []
     private var allAudio: [Float] = []
     private let bufferLock = NSLock()
     ```

3. **RingBuffer.swift** (Lines 10-103)
   - **Issue**: Thread-safe circular buffer using `NSLock`
   - **Swift 6 Impact**: Generic type `T` not constrained to `Sendable`
   - **Fix Required**: Add `Sendable` constraint: `final class RingBuffer<T: Sendable>`
   - **Risk**: Used in audio pipeline (real-time thread)

4. **TranscriptionController.swift** (Line 23)
   - **Issue**: `engine: any ASREngine` - existential type without `Sendable`
   - **Swift 6 Impact**: Protocol must conform to `Sendable` for async usage
   - **Fix Required**:
     ```swift
     protocol ASREngine: AnyObject, Sendable { ... }
     ```

5. **AudioMixer.swift** (Lines 19-20)
   - **Issue**: Mutable state `converter` and `lastInputFormat` accessed from multiple threads
   - **Swift 6 Impact**: Data race on format changes
   - **Fix Required**: Add synchronization or make `actor`

**MEDIUM RISK - Closure Capture:**

6. **Main.swift** (Line 38)
   - **Issue**: `CommandLine.unsafeArgv` - unsafe pointer in Swift 6
   - **Swift 6 Impact**: Requires explicit `@unchecked Sendable` or isolation
   - **Fix Required**: Ensure called from main thread only

7. **StatusBarController.swift** (Lines 1000-1004)
   - **Issue**: `withTimeout` wrapping `SCShareableContent.excludingDesktopWindows`
   - **Swift 6 Impact**: Timeout utility needs `Sendable` conformance
   - **Fix Required**: Verify `@Sendable` on closure parameters

### 4.2 Existential Types & Protocols

**REQUIRED CHANGES:**

1. **ASREngine Protocol** (WhisperEngine.swift, Lines 33-51)
   - **Current**: `protocol ASREngine: AnyObject`
   - **Swift 6 Required**: Add `Sendable` conformance
   - **Impact**: All conforming types must be `Sendable`
   - **Affected Implementations**: `NativeWhisperEngine`, `ParakeetEngine`

2. **Callback Closures** (TranscriptionController.swift, Lines 26-31)
   - **Current**: `var onPartial: ((String) -> Void)?`
   - **Swift 6 Required**: `var onPartial: (@Sendable (String) -> Void)?`
   - **Impact**: All callback closures must be `@Sendable`
   - **Affected**: `onPartial`, `onFinal`, `onMicLevel`, `onAppLevel`, `onAppAudioLost`, `onFallbackToMicOnly`

3. **HotkeyManager Callbacks** (StatusBarController.swift, Lines 1056-1072)
   - **Current**: `handler: { [weak self] in ... }`
   - **Swift 6 Required**: Verify `@Sendable` on closure parameter
   - **Impact**: Global hotkey handlers must be thread-safe

### 4.3 Objective-C Interop

**VERIFIED COMPATIBLE:**

1. **WhisperBridge.h/mm**
   - **Status**: Pure C API with explicit `extern "C"`
   - **Swift 6 Impact**: None - C interop unchanged
   - **Memory Safety**: Manual `malloc/free` requires audit
   - **Concern**: Line 274 in WhisperEngine.swift - `defer { free(textPointer) }` must remain safe

2. **NSObject Subclasses**
   - **AppDelegate** (Line 13): `class AppDelegate: NSObject, NSApplicationDelegate`
   - **AudioCapture** (Line 10): `final class AudioCapture: NSObject`
   - **Status**: Compatible - Objective-C classes exempt from strict concurrency by default

3. **@objc Attributes**
   - **Count**: 47+ `@objc` methods across codebase
   - **Status**: Compatible - `@objc` methods implicitly nonisolated
   - **Warning**: May need explicit `nonisolated` in Swift 6 if accessing isolated state

### 4.4 Unsafe Pointer Usage

**CRITICAL AUDIT REQUIRED:**

1. **WhisperEngine.swift** (Lines 98-99, 259-270)
   ```swift
   let cPath = (modelURL.path as NSString).utf8String
   guard let path = cPath, let context = wt_whisper_init(path) else { ... }

   let textPtr = samples.withUnsafeBufferPointer { bufferPointer -> UnsafeMutablePointer<CChar>? in
       guard let baseAddress = bufferPointer.baseAddress else { return nil }
       ...
   }
   ```
   - **Issue**: `utf8String` returns transient pointer - may dangle
   - **Swift 6 Impact**: Stricter lifetime rules
   - **Fix**: Use `withCString` for guaranteed lifetime

2. **AudioMixer.swift** (Lines 78-82, 144-147)
   ```swift
   let samples = Array(UnsafeBufferPointer(
       start: channelData[0],
       count: Int(outputBuffer.frameLength)
   ))

   memcpy(channelData[0], data, byteCount)
   ```
   - **Issue**: Direct `memcpy` with raw pointers
   - **Swift 6 Impact**: Requires explicit bounds checking
   - **Status**: Likely safe (AVFoundation contract), but audit recommended

3. **Main.swift** (Line 38)
   ```swift
   _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
   ```
   - **Issue**: `unsafeArgv` - C-style pointer
   - **Swift 6 Impact**: Requires explicit acknowledgment
   - **Status**: Safe (macOS entry point pattern)

### 4.5 Task & Structured Concurrency

**EXISTING USAGE - AUDIT REQUIRED:**

1. **StatusBarController.swift**
   - **Lines 779-803**: `Task { [self] in ... }` - Captures `self`
   - **Lines 1207-1250**: `pendingEngineInitTask` - Cancellable task management
   - **Swift 6 Impact**: Must verify `Sendable` conformance of captured types

2. **AsyncTimeout.swift** (Lines 21-47)
   - **Status**: Already uses structured concurrency correctly
   - **Swift 6 Impact**: None - best practice implementation

3. **TranscriptionController.swift** (Lines 125-133, 79-80)
   - **Issue**: `Task { }` for cleanup - no error handling
   - **Swift 6 Impact**: Unhandled errors may become warnings
   - **Fix**: Add error handling or suppress explicitly

---

## 5. C++/ObjC++ Interop Analysis

### 5.1 WhisperBridge.h - C API (SAFE)

**Status: Swift 6 Compatible**

- Pure C API with `extern "C"` linkage
- Opaque pointers (`typedef void* WTWhisperContextRef`)
- No Swift-specific types
- Manual memory management (`malloc/free`)

**Verified Safe Patterns:**
```c
WTWhisperContextRef _Nullable wt_whisper_init(const char * _Nonnull model_path);
void wt_whisper_free(WTWhisperContextRef _Nullable ctx);
char * _Nullable wt_whisper_transcribe(...);
```

### 5.2 WhisperBridge.mm - C++ Implementation

**Status: Requires Audit**

1. **Memory Model Compatibility:**
   - **Line 130**: `char* result_str = (char*)malloc(transcript.size() + 1);`
   - **Swift 6 Impact**: Manual allocation requires careful lifetime management
   - **Concern**: Caller must `free()` - verified in WhisperEngine.swift:274

2. **Thread Safety:**
   - **Lines 72-73**: Thread count calculation from `NSProcessInfo`
   - **Status**: Thread-safe (read-only access)

3. **Whisper.cpp API Stability:**
   - **Line 69**: `whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH)`
   - **Line 105**: `whisper_full(whisper_ctx, params, samples, numSamples)`
   - **Swift 6 Impact**: None - C API unchanged

### 5.3 Swift → C Bridging Points

**CRITICAL PATHS:**

1. **Model Path String** (WhisperEngine.swift:98)
   ```swift
   let cPath = (modelURL.path as NSString).utf8String
   guard let path = cPath, let context = wt_whisper_init(path) else { ... }
   ```
   - **Issue**: `utf8String` lifetime not guaranteed
   - **Swift 6 Fix Required**:
     ```swift
     modelURL.path.withCString { cPath in
         guard let context = wt_whisper_init(cPath) else { ... }
     }
     ```

2. **Audio Sample Buffer** (WhisperEngine.swift:259-270)
   ```swift
   let textPtr = samples.withUnsafeBufferPointer { bufferPointer -> UnsafeMutablePointer<CChar>? in
       guard let baseAddress = bufferPointer.baseAddress else { return nil }
       let langCStr = language?.cString(using: .utf8)
       return wt_whisper_transcribe(
           UnsafeMutableRawPointer(ctx),
           baseAddress,
           Int32(bufferPointer.count),
           langCStr,
           translate,
           noContext
       )
   }
   ```
   - **Issue**: `langCStr` lifetime scoping unclear
   - **Swift 6 Fix Required**:
     ```swift
     if let lang = language {
         return lang.withCString { langCStr in
             return wt_whisper_transcribe(...)
         }
     } else {
         return wt_whisper_transcribe(..., nil, ...)
     }
     ```

3. **Opaque Pointer Conversion** (WhisperEngine.swift:110, 264)
   ```swift
   wt_whisper_free(UnsafeMutableRawPointer(ctx))
   wt_whisper_transcribe(UnsafeMutableRawPointer(ctx), ...)
   ```
   - **Status**: Safe - explicit cast acknowledged
   - **Swift 6 Impact**: None

### 5.4 Memory Safety Verification Checklist

- [x] **WhisperBridge.h**: C API declarations safe
- [x] **WhisperBridge.mm**: Manual `malloc/free` paired correctly
- [ ] **WhisperEngine.swift:98**: String lifetime fix needed
- [ ] **WhisperEngine.swift:259-270**: Language string lifetime fix needed
- [x] **AudioMixer.swift:146**: `memcpy` bounds safe (AVFoundation contract)
- [x] **Main.swift:38**: `unsafeArgv` usage acceptable (macOS entry point)

---

## 6. Build Configuration Changes

### 6.1 project.yml Modifications

**Required Changes:**

```yaml
settings:
  SWIFT_VERSION: "6.0"  # Changed from "5.0"
  MACOSX_DEPLOYMENT_TARGET: "14.0"

  # Swift 6 Strict Concurrency Settings
  SWIFT_STRICT_CONCURRENCY: complete  # NEW - Enable full checking
  SWIFT_UPCOMING_FEATURE_FLAGS: >-    # NEW - Enable Swift 6 features
    ExistentialAny
    BareSlashRegexLiterals
    ConciseMagicFile
    ForwardTrailingClosures
    StrictConcurrency

  # C++ Interop Settings (unchanged, verified compatible)
  CLANG_CXX_LANGUAGE_STANDARD: "gnu++17"
  CLANG_CXX_LIBRARY: "libc++"
```

### 6.2 Compiler Flags Analysis

**Current Flags (Verified):**
- `SWIFT_OBJC_BRIDGING_HEADER: MacTalk/MacTalk/Whisper/WhisperBridge.h` - **Safe**
- `HEADER_SEARCH_PATHS: Vendor/whisper.cpp/...` - **Safe**
- `OTHER_LDFLAGS: -lwhisper` - **Safe**

**New Flags Needed:**

1. **SWIFT_STRICT_CONCURRENCY: complete**
   - Enables full Swift 6 concurrency checking
   - Will surface ALL data race issues at compile time

2. **SWIFT_UPCOMING_FEATURE_FLAGS**
   - `ExistentialAny`: Requires explicit `any` keyword (minimal impact)
   - `StrictConcurrency`: Core Swift 6 concurrency model

### 6.3 Expected Compiler Warnings → Errors

**Phase 1: Enable Swift 6 Mode**

```
error: var 'onPartial' is not concurrency-safe because it is non-isolated global shared mutable state
  var onPartial: ((String) -> Void)?
      ^
note: convert 'onPartial' to a 'let' constant or annotate it with '@MainActor' if property should only be accessed from the main actor
note: disable concurrency-safety checks if accesses are protected by an external synchronization mechanism
```

**Expected Count**: 20-30 errors related to:
- Callback closures missing `@Sendable`
- Mutable state without actor isolation
- NSLock-protected properties

**Phase 2: Strict Concurrency Complete**

```
error: type 'ASREngine' does not conform to the 'Sendable' protocol
  private let engine: any ASREngine
                      ^
note: add '@unchecked Sendable' if this type is manually verified to be concurrency-safe
```

**Expected Count**: 10-15 errors related to:
- Protocol conformance
- Generic constraints

---

## 7. Dependency Compatibility

### 7.1 FluidAudio Package

**Status: COMPATIBLE (Verified December 2025)**

- **Package**: `https://github.com/FluidInference/FluidAudio.git`
- **Version**: v0.7.11 (latest, December 2025)
- **Usage**: `AsrManager`, `VadManager` in ParakeetEngine
- **Swift 6 Risk**: **LOW** - Pure Swift package with CoreML backend

**Investigation Findings (Deep Research):**

| Feature | Status | Notes |
|---------|--------|-------|
| Batch ASR | Stable | `AsrManager.transcribe()` - primary API |
| Streaming ASR | New in v0.7.10 | `transcribeStreamingChunk()` - low-level |
| VAD | Stable | `VadManager` with Silero VAD model |
| Diarization | Stable | Offline and streaming modes |
| ANE Optimization | Excellent | 100-190x real-time on Apple Silicon |

**API Details:**

1. **Batch Transcription (Current Usage):**
   ```swift
   let result = try await manager.transcribe(samples)
   ```
   - Fully async, Swift concurrency compatible
   - No known Sendable issues

2. **New Streaming API (v0.7.10+):**
   ```swift
   // Low-level incremental decoding
   let partial = try await manager.transcribeStreamingChunk(
       chunk,
       state: decoderState
   )
   ```
   - Preserves decoder state across calls
   - Enables true streaming without rolling-window

3. **VAD for Streaming:**
   ```swift
   let vadResult = manager.processStreamingChunk(chunk, state: vadState)
   ```
   - ~256ms frame detection
   - Real-time speech/silence segmentation

**Performance on Apple Silicon:**
- ~110-190x real-time factor (M1/M2/M3/M4)
- 1 hour audio transcribed in ~19-33 seconds
- 2-3s chunk = ~20-30ms processing
- CPU usage <20-30% (ANE offload)

**Swift 6 Compatibility:**
- FluidAudio uses async/await internally
- CoreML models run on ANE executor
- No known actor isolation conflicts
- Recommend: Test build early in migration

**Action:** Update `project.yml` to pin version 0.7.11:
```yaml
packages:
  FluidAudio:
    url: https://github.com/FluidInference/FluidAudio.git
    from: "0.7.11"
```

### 7.2 whisper.cpp (Vendor/whisper.cpp)

**Status: COMPATIBLE**

- **Language**: C++17
- **Interface**: Pure C API via `extern "C"`
- **Swift 6 Impact**: None
- **Build System**: CMake (separate from Swift)

**Verification:**
- C API unchanged in Swift 6
- Manual memory management patterns remain valid
- No Swift concurrency in bridging layer

### 7.3 System Frameworks

**All COMPATIBLE:**

- **AVFoundation**: Apple framework, Swift 6 ready
- **ScreenCaptureKit**: Apple framework, Swift 6 ready
- **AppKit**: Apple framework, Swift 6 ready
- **Accelerate**: C framework, unaffected
- **Metal**: C/Objective-C, unaffected

---

## 8. Pre-Migration Verification Checklist

### 8.1 Baseline Verification

- [ ] **Current Build Status**
  - [ ] Clean build succeeds with `SWIFT_VERSION: "5.0"`
  - [ ] Zero build warnings
  - [ ] All tests pass (`xcodebuild test`)

- [ ] **Runtime Verification**
  - [ ] Mic-only recording works
  - [ ] Mic + App audio works
  - [ ] Model switching works (Whisper ↔ Parakeet)
  - [ ] Auto-paste works
  - [ ] Global shortcuts work
  - [ ] Settings persistence works

### 8.2 Code Audit

- [ ] **Concurrency Review**
  - [ ] List all `NSLock` usage → planned `actor` conversion
  - [ ] List all callback closures → add `@Sendable`
  - [ ] List all `Task { }` blocks → verify error handling
  - [ ] List all mutable shared state → plan isolation strategy

- [ ] **Unsafe Code Audit**
  - [ ] Review all `withUnsafe*` calls
  - [ ] Verify pointer lifetimes in C interop
  - [ ] Check `memcpy` bounds
  - [ ] Audit `malloc/free` pairing

- [ ] **FluidAudio Investigation**
  - [ ] Clone and test FluidAudio with Swift 6
  - [ ] Document incompatibilities if any
  - [ ] Prepare workaround strategy

### 8.3 Environment Preparation

- [ ] **Backup**
  - [ ] Create git branch: `git checkout -b feat/swift-6-migration`
  - [ ] Tag current state: `git tag pre-swift-6`

- [ ] **Tooling**
  - [ ] Verify Xcode 15.0+ installed
  - [ ] Verify macOS 14.0+ SDK available
  - [ ] Install Swift 6 toolchain if using early access

---

## 9. Post-Migration Regression Tests

### 9.1 Functional Test Matrix

| Test Case | Description | Pass Criteria |
|-----------|-------------|---------------|
| **F1** | Mic-only recording | Transcription appears, copied to clipboard |
| **F2** | Mic + App audio | App picker works, mixed audio transcribed |
| **F3** | Auto-paste | Cmd+V simulated correctly with accessibility |
| **F4** | Model switching | Whisper ↔ Parakeet switch without crash |
| **F5** | Global shortcuts | Cmd+Shift+M, Cmd+Shift+A work |
| **F6** | HUD display | Bubble appears, animates, responds to stop |
| **F7** | Settings persistence | Changes saved across app restarts |
| **F8** | Permission prompts | Mic, Screen Recording, Accessibility dialogs |
| **F9** | Model download | Auto-download progress, verification |
| **F10** | Error handling | Graceful failures (no permission, no audio, etc.) |

### 9.2 Concurrency Stress Tests

| Test Case | Description | Pass Criteria |
|-----------|-------------|---------------|
| **C1** | Rapid start/stop | 10x start/stop in 5 seconds, no crash |
| **C2** | Model switch during recording | Switch provider mid-recording, clean transition |
| **C3** | Concurrent recordings | Attempt dual recording, proper error |
| **C4** | Background processing | Start recording, switch apps, verify continues |
| **C5** | Memory pressure | Long recording (5+ min), check for leaks |

### 9.3 Integration Test Suite

**Automated Tests (MacTalkTests/):**
- [ ] `AudioMixerTests` - Format conversion accuracy
- [ ] `RingBufferTests` - Thread-safe operations
- [ ] `WhisperEngineTests` - Transcription correctness
- [ ] `ParakeetEngineTests` - Parakeet initialization
- [ ] `PermissionsTests` - Permission state handling
- [ ] `HotkeyManagerTests` - Shortcut registration

**Manual Verification:**
- [ ] Menu bar icon appears (macOS 26 Tahoe transparency)
- [ ] HUD glass effect renders correctly
- [ ] Audio waveform visualization smooth
- [ ] App picker shows running apps
- [ ] Screen Recording permission dialog triggers
- [ ] Settings window tabs work
- [ ] About dialog shows version

### 9.4 Performance Benchmarks

**Before Swift 6:**
- [ ] Transcription latency: ___ms (baseline)
- [ ] Memory usage: ___MB (idle)
- [ ] CPU usage: ___% (recording)

**After Swift 6:**
- [ ] Transcription latency: ___ms (should be ≤ baseline)
- [ ] Memory usage: ___MB (should be ≤ baseline)
- [ ] CPU usage: ___% (should be ≤ baseline + 5%)

**Regression Threshold:** >10% performance degradation = FAIL

---

## 10. Rollback Strategy

### 10.1 Rollback Triggers

**Execute rollback if:**
- [ ] Build fails with >50 Swift 6 errors (too complex to fix in one story)
- [ ] FluidAudio incompatibility blocks build
- [ ] Runtime crash rate >1% (unacceptable stability)
- [ ] Performance regression >15%
- [ ] Critical feature broken (transcription, model switching, etc.)

### 10.2 Rollback Procedure

**Step 1: Revert Build Settings**
```yaml
# project.yml
settings:
  SWIFT_VERSION: "5.0"  # Revert to 5.0
  # Remove SWIFT_STRICT_CONCURRENCY
  # Remove SWIFT_UPCOMING_FEATURE_FLAGS
```

**Step 2: Git Rollback**
```bash
# If changes not committed:
git checkout project.yml

# If changes committed:
git revert <commit-hash>

# Nuclear option:
git reset --hard pre-swift-6
```

**Step 3: Rebuild & Test**
```bash
xcodegen generate
./build.sh clean
./build.sh run
xcodebuild test -project MacTalk.xcodeproj -scheme MacTalk
```

**Step 4: Document Blockers**
- Create GitHub issues for each blocking error
- Tag as `swift-6-blocker`
- Estimate effort for resolution
- Re-plan migration in smaller increments

### 10.3 Incremental Migration Plan (Fallback)

**If full migration blocked, split into phases:**

**Phase A: Actor Conversion (Isolated Story)**
- Convert `StatusBarController` to use `@MainActor`
- Convert `WhisperEngine` state to `actor`
- Verify builds and tests pass in Swift 5 mode
- **Benefit**: Gradual concurrency safety without Swift 6 enforcement

**Phase B: Sendable Conformance (Isolated Story)**
- Add `Sendable` to `ASREngine` protocol
- Add `@Sendable` to all callbacks
- Constrain `RingBuffer<T: Sendable>`
- **Benefit**: Explicit concurrency contracts

**Phase C: Unsafe Code Cleanup (Isolated Story)**
- Fix `utf8String` → `withCString`
- Fix language parameter lifetime in `transcribeCore`
- **Benefit**: Swift 6 compatible pointer usage

**Phase D: Enable Swift 6 (Final Story)**
- Set `SWIFT_VERSION: "6.0"`
- Resolve remaining errors (should be <10)
- **Benefit**: Complete migration with minimal risk

### 10.4 Communication Plan

**If rollback required:**
1. Notify stakeholders immediately
2. Create postmortem document
3. Update project roadmap
4. Re-estimate Swift 6 migration effort

---

## 11. Risk Assessment

### 11.1 Risk Matrix

| Risk | Likelihood | Impact | Severity | Mitigation |
|------|------------|--------|----------|------------|
| **FluidAudio incompatible** | **Low** | Medium | **LOW** | Verified compatible (v0.7.11) - uses async/await natively |
| **C++ interop breaks** | Low | Critical | **HIGH** | Audit pointer lifetimes, fix before enable |
| **Data race crashes** | Medium | Medium | **MEDIUM** | Convert to actors incrementally |
| **Performance regression** | Low | Medium | **MEDIUM** | Benchmark before/after |
| **Test failures** | High | Low | **LOW** | Expect & fix systematically |

**FluidAudio Risk Update (December 2025):**
Deep research confirmed FluidAudio v0.7.11 is Swift 6 compatible:
- Uses async/await internally (Swift concurrency native)
- CoreML backend runs on ANE (no actor conflicts)
- New streaming API (`transcribeStreamingChunk`) is async
- No known Sendable issues with `AsrManager`

### 11.2 Timeline Estimates

**Optimistic (No Blockers):** 3-5 days
- Day 1: Enable Swift 6, fix compilation errors
- Day 2: Actor conversions, Sendable conformance
- Day 3: Unsafe code cleanup
- Day 4: Testing & bug fixes
- Day 5: Regression testing, documentation

**Realistic (Minor Blockers):** 1-2 weeks
- Week 1: Compiler errors, actor conversions
- Week 2: Refactoring, testing, polish

**Pessimistic (Major Blockers):** 2-3 weeks
- Week 1: Actor conversion more complex than expected
- Week 2: C++ bridge issues, pointer lifetime bugs
- Week 3: Stabilization, extensive testing

*Note: FluidAudio investigation no longer required - compatibility verified.*

### 11.3 Success Metrics

**Migration successful if:**
- ✅ Zero build errors/warnings
- ✅ All tests pass (100% pass rate)
- ✅ Zero runtime crashes in manual testing
- ✅ Performance within 10% of baseline
- ✅ All acceptance criteria met

**Migration deferred if:**
- ❌ >50 compilation errors (too complex)
- ❌ FluidAudio requires major fork/replacement
- ❌ Performance regression >15%
- ❌ Critical features broken

---

## 12. Implementation Notes

### 12.1 Recommended Order of Fixes

**Priority 1: Foundation (Do First)**
1. Add `Sendable` to `ASREngine` protocol
2. Fix `RingBuffer<T: Sendable>` generic constraint
3. Fix unsafe pointer lifetimes (WhisperEngine.swift:98, 259-270)

**Priority 2: State Management (Core Refactor)**
4. Convert `StatusBarController` to `@MainActor`
5. Convert `WhisperEngine` to `actor` with isolated state
6. Add `@Sendable` to all callback closures

**Priority 3: Polish (Final Cleanup)**
7. Fix remaining `Task { }` error handling
8. Add explicit `nonisolated` to `@objc` methods if needed
9. Clean up any remaining warnings

### 12.2 Testing Strategy

**Per-Fix Validation:**
- Build after each fix category
- Run subset of tests relevant to changed code
- Verify no new issues introduced

**Final Validation:**
- Full test suite run
- Manual regression testing (Section 9)
- Performance benchmarking
- Memory leak detection (Instruments)

### 12.3 Documentation Updates Required

Post-migration, update:
- [ ] `CLAUDE.md` - Note Swift 6 compatibility
- [ ] `README.md` - Update build requirements
- [ ] `ARCHITECTURE.md` - Document actor usage
- [ ] This story - Mark as COMPLETED with summary
