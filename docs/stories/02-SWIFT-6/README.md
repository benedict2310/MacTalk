# Epic 02: Swift 6 Migration

> **Status:** Pending
> **Priority:** High
> **Estimated Effort:** 2-3 weeks
> **Risk Level:** Medium-High

---

## Overview

This epic migrates MacTalk from Swift 5 to Swift 6, adopting the new strict data race safety model. Swift 6 enforces concurrency safety at compile time, transforming runtime crashes into compile-time errors.

### Why Swift 6?

| Benefit | Description |
|---------|-------------|
| **Data Race Safety** | Compile-time guarantees eliminate entire classes of bugs |
| **Future Compatibility** | Required for new Swift features and Apple APIs |
| **Code Quality** | Explicit concurrency contracts improve maintainability |
| **Performance** | Better optimization opportunities with clear isolation |

### Key Challenges

1. **Audio Pipeline** - Real-time threads cannot use async/await
2. **C++ Interop** - whisper.cpp bridge requires careful handling
3. **UI Threading** - AppKit requires main thread, must integrate with actors
4. **Existing Patterns** - NSLock usage must be replaced or justified

---

## Story Map

```
S.02.0 Migration Strategy & Baseline
   │
   ├──► S.02.1 Strict Concurrency (UI)
   │       │
   │       └──► S.02.1a Utilities Concurrency
   │
   ├──► S.02.2 Audio Actors & RingBuffer
   │       │
   │       └──► S.02.2a AudioMixer Thread Safety [CRITICAL]
   │
   └──► S.02.3 Swift 6 Mode Enablement
           │
           └──► S.02.3a Test Suite Migration
```

---

## Stories

### Foundation

| Story | Title | Status | Risk | Effort |
|-------|-------|--------|------|--------|
| [S.02.0](./S.02.0-MIGRATION-STRATEGY.md) | Migration Strategy & Baseline | Pending | Low | 2h |

### UI Layer

| Story | Title | Status | Risk | Effort | Dependency |
|-------|-------|--------|------|--------|------------|
| [S.02.1](./S.02.1-STRICT-CONCURRENCY-UI.md) | Strict Concurrency (UI & Settings) | Pending | High | 16-24h | S.02.0 |
| [S.02.1a](./S.02.1a-UTILITIES-CONCURRENCY.md) | Utilities & Singleton Concurrency | Pending | Medium | 4-6h | S.02.0, S.02.1 |

### Audio Layer

| Story | Title | Status | Risk | Effort | Dependency |
|-------|-------|--------|------|--------|------------|
| [S.02.2](./S.02.2-AUDIO-ACTORS.md) | Audio Actors & RingBuffer Safety | Pending | High | 12-16h | S.02.1 |
| [S.02.2a](./S.02.2a-AUDIOMIXER-THREAD-SAFETY.md) | AudioMixer Thread Safety | Pending | **CRITICAL** | 2-3h | S.02.0 |

### Final Migration

| Story | Title | Status | Risk | Effort | Dependency |
|-------|-------|--------|------|--------|------------|
| [S.02.3](./S.02.3-SWIFT-6-MODE.md) | Swift 6 Mode Enablement | Pending | Medium | 8-12h | S.02.2 |
| [S.02.3a](./S.02.3a-TEST-SUITE-MIGRATION.md) | Test Suite Migration | Pending | Low | 4-6h | S.02.3 |

---

## Recommended Execution Order

### Phase 1: Preparation (Day 1)
1. **S.02.0** - Establish baseline, create branch, document metrics
2. **S.02.2a** - Fix AudioMixer data race (CRITICAL bug, blocks everything)

### Phase 2: UI Isolation (Days 2-4)
3. **S.02.1** - MainActor isolation for all UI components
4. **S.02.1a** - Utilities and singletons

### Phase 3: Audio Safety (Days 5-7)
5. **S.02.2** - Convert engines to actors, RingBuffer safety

### Phase 4: Final Migration (Days 8-10)
6. **S.02.3** - Enable Swift 6 mode, fix remaining issues
7. **S.02.3a** - Update test suite, add TSan validation

### Phase 5: Validation (Days 11-14)
- Full regression testing
- Performance benchmarking
- Documentation updates

---

## Critical Paths

### Must Complete Before Swift 6

```
┌─────────────────────────────────────────────────────────────┐
│  CRITICAL: S.02.2a AudioMixer Thread Safety                 │
│                                                             │
│  This is a REAL BUG that exists TODAY in Swift 5.          │
│  The AudioMixer has a data race on converter/lastInputFormat│
│  that can cause crashes during mic+app audio recording.     │
│                                                             │
│  Fix this FIRST, regardless of Swift 6 migration.           │
└─────────────────────────────────────────────────────────────┘
```

### Dependency Chain

```
S.02.0 (baseline) ──┬──► S.02.2a (critical bug)
                    │
                    ├──► S.02.1 (UI) ──► S.02.1a (utilities)
                    │
                    └──► S.02.2 (audio) ──► S.02.3 (enable) ──► S.02.3a (tests)
```

---

## Risk Matrix

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| FluidAudio incompatible | **Low** | Low | Verified compatible (v0.7.11, async/await native) |
| AudioMixer crash | **High** | **High** | **Fix S.02.2a immediately** |
| StatusBarController complexity | High | Medium | Incremental migration, frequent builds |
| Performance regression | Low | Medium | Benchmark before/after |
| C++ interop breaks | Low | High | Audit pointer lifetimes early |

**FluidAudio Update (December 2025):** Deep research confirmed FluidAudio v0.7.11 is fully Swift 6 compatible with async/await APIs, ANE optimization (100-190x real-time), and new streaming support (`transcribeStreamingChunk`).

---

## Success Criteria

The epic is complete when:

- [ ] Project compiles with `SWIFT_VERSION: "6.0"`
- [ ] Zero build warnings
- [ ] All tests pass (100%)
- [ ] Thread Sanitizer shows zero MacTalk warnings
- [ ] Performance within 10% of baseline
- [ ] All manual regression tests pass
- [ ] Documentation updated

---

## Rollback Strategy

If migration is blocked:

1. **Immediate:** Revert `project.yml` to Swift 5.0
2. **Git:** `git reset --hard pre-swift-6-baseline`
3. **Document:** Create issues for blockers
4. **Re-plan:** Split into smaller increments

See [S.02.3 Section 10](./S.02.3-SWIFT-6-MODE.md#10-rollback-strategy) for detailed rollback procedures.

---

## Technical Reference

### Key Patterns

**MainActor Isolation:**
```swift
@MainActor
final class HUDWindowController: NSWindowController { ... }
```

**Actor for State:**
```swift
actor NativeWhisperEngine: ASREngine {
    private var isStreaming: Bool = false

    nonisolated func process(_ buffer: AVAudioPCMBuffer) {
        // Called from audio thread - no await
    }
}
```

**@unchecked Sendable:**
```swift
/// Thread-safe via OSAllocatedUnfairLock
final class AudioMixer: @unchecked Sendable { ... }
```

**@Sendable Closures:**
```swift
var onPartial: (@Sendable (String) -> Void)?
```

### Resources

- [Swift 6 Migration Guide](https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/)
- [SE-0302: Sendable and @Sendable closures](https://github.com/apple/swift-evolution/blob/main/proposals/0302-concurrent-value-and-concurrent-closures.md)
- [SE-0306: Actors](https://github.com/apple/swift-evolution/blob/main/proposals/0306-actors.md)
- [WWDC 2022: Eliminate data races using Swift Concurrency](https://developer.apple.com/videos/play/wwdc2022/110351/)

---

## Changelog

| Date | Change |
|------|--------|
| 2025-12-15 | Created epic with 7 stories |
| 2025-12-15 | Added comprehensive architectural reviews to S.02.1, S.02.2, S.02.3 |
| 2025-12-15 | Added S.02.0 (baseline), S.02.1a (utilities), S.02.2a (AudioMixer), S.02.3a (tests) |
| 2025-12-15 | Updated FluidAudio compatibility: v0.7.11 confirmed Swift 6 compatible with new streaming API |
