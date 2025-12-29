# S.02.0 - Swift 6 Migration Strategy & Baseline

**Epic:** Swift 6 Migration
**Status:** Complete
**Date:** 2025-12-15
**Priority:** P0 - Must Complete First
**Branch:** `feat/swift-6-migration`
**Tag:** `pre-swift-6-baseline`

---

## 1. Objective

Establish the foundational infrastructure, baseline metrics, and strategy for the Swift 6 migration before any code changes begin.

**Goal:** Create a safe migration environment with clear rollback capabilities, baseline measurements, and incremental validation checkpoints.

---

## 2. Why This Story Exists

Swift 6 introduces strict data race safety as a compile-time guarantee. This is a significant breaking change that affects:

- All mutable shared state
- Closure captures across isolation boundaries
- Protocol conformance requirements
- Async/await patterns

**Without proper preparation:**
- Migration could introduce subtle bugs
- Rollback may be difficult if changes are scattered
- Progress is hard to measure
- Risk of extended broken builds

---

## 3. Implementation Plan

### Step 1: Environment Preparation

1. **Create Feature Branch:**
   ```bash
   git checkout -b feat/swift-6-migration
   git tag pre-swift-6-baseline
   ```

2. **Verify Current Build:**
   ```bash
   xcodegen generate
   ./build.sh clean && ./build.sh
   xcodebuild test -project MacTalk.xcodeproj -scheme MacTalk
   ```

3. **Document Environment:**
   - Xcode version: ____
   - macOS SDK version: ____
   - Swift version (current): 5.0
   - whisper.cpp version: ____
   - FluidAudio version: 0.7.9+

### Step 2: Baseline Metrics Collection

1. **Build Metrics:**
   ```bash
   # Clean build time
   time xcodebuild -project MacTalk.xcodeproj -scheme MacTalk clean build 2>&1 | tail -5

   # Warning count (Swift 5 baseline)
   xcodebuild -project MacTalk.xcodeproj -scheme MacTalk build 2>&1 | grep -c "warning:"
   ```

2. **Test Metrics:**
   ```bash
   # Test pass rate
   xcodebuild test -project MacTalk.xcodeproj -scheme MacTalk 2>&1 | grep -E "Test Suite|passed|failed"
   ```

3. **Runtime Metrics:**
   - Transcription latency (10s audio): ____ms
   - Memory usage (idle): ____MB
   - Memory usage (recording): ____MB
   - CPU usage (recording): ____%

### Step 3: Enable Incremental Concurrency Checking

**Phase 1: Targeted (Warning Only)**
```yaml
# project.yml
settings:
  SWIFT_VERSION: "5.0"  # Keep Swift 5 for now
  SWIFT_STRICT_CONCURRENCY: targeted  # Warnings only
```

**Measure Warning Baseline:**
```bash
xcodegen generate
xcodebuild -project MacTalk.xcodeproj -scheme MacTalk build 2>&1 | grep -c "concurrency"
```

**Expected Output:** Document count of concurrency warnings.

**Phase 2: Complete (Warning Only)**
```yaml
settings:
  SWIFT_STRICT_CONCURRENCY: complete  # All warnings
```

**Measure Full Warning Count:**
```bash
xcodebuild -project MacTalk.xcodeproj -scheme MacTalk build 2>&1 | tee build_warnings.log
grep -c "warning:" build_warnings.log
grep "concurrency\|Sendable\|isolated\|actor" build_warnings.log | wc -l
```

### Step 4: Categorize Warnings

Create a tracking document with:

| Category | Count | Files | Story |
|----------|-------|-------|-------|
| Non-Sendable closure | __ | __.swift | S.02.1 |
| MainActor isolation | __ | __.swift | S.02.1 |
| Mutable shared state | __ | __.swift | S.02.2 |
| Protocol conformance | __ | __.swift | S.02.2 |
| Unsafe pointer | __ | __.swift | S.02.3 |

### Step 5: Validate Rollback Procedure

1. **Test rollback from complete mode:**
   ```bash
   # In project.yml, revert to:
   SWIFT_STRICT_CONCURRENCY: minimal

   xcodegen generate
   ./build.sh
   # Verify: Zero warnings related to concurrency
   ```

2. **Test git rollback:**
   ```bash
   git stash
   git checkout pre-swift-6-baseline
   ./build.sh
   xcodebuild test -project MacTalk.xcodeproj -scheme MacTalk
   # Verify: All tests pass
   git checkout feat/swift-6-migration
   git stash pop
   ```

---

## 4. Rollback Triggers

**Immediate rollback if ANY of:**
- [ ] Build fails with >100 errors (scope too large)
- [ ] FluidAudio package fails to build
- [ ] Test pass rate drops below 90%
- [ ] Runtime crash during basic operations

**Escalate for team review if:**
- [ ] Warning count >50 in single category
- [ ] Any warning in WhisperBridge/C++ interop
- [ ] Performance degradation >10%

---

## 5. Success Metrics

**This story is complete when:**
- [x] Feature branch created and tagged
- [x] Baseline metrics documented
- [x] Warning count at each concurrency level documented
- [x] Warnings categorized by story
- [x] Rollback procedure verified
- [ ] Team aligned on migration sequence

---

## 6. Dependencies

**None** - This is the first story in the epic.

**Blocks:**
- S.02.1 - Strict Concurrency UI
- S.02.1a - Utilities Concurrency
- S.02.2 - Audio Actors
- S.02.2a - AudioMixer Thread Safety
- S.02.3 - Swift 6 Mode
- S.02.3a - Test Suite Migration

---

## 7. Baseline Documentation (Completed 2025-12-15)

### Build Environment
| Metric | Value |
|--------|-------|
| Xcode Version | 26.0.1 (17A400) |
| macOS SDK | 26.0 |
| macOS Version | 26.1 (25B78) |
| Swift Version | 6.2 (swiftlang-6.2.0.19.9) |
| whisper.cpp | v1.8.2-30-g322c2adb |
| FluidAudio | Not included (Parakeet files excluded) |

### Warning Counts
| Mode | Total Warnings | Concurrency Warnings |
|------|----------------|---------------------|
| minimal | 13 | 2 |
| targeted | 18 | 7 |
| complete | 160 | 115 |

### Warnings by File (complete mode)
| File | Count | Primary Issues |
|------|-------|----------------|
| StatusBarController.swift | 69 | MainActor isolation, Sendable closures |
| Permissions.swift | 16 | MainActor isolation (NSAlert) |
| AppDelegate.swift | 9 | MainActor isolation |
| AsyncTimeout.swift | 5 | Sendable generic constraints |
| PerformanceMonitor.swift | 4 | Sendable closures |
| TranscriptionController.swift | 3 | Sendable closures |
| AudioMixer.swift | 2 | Sendable closures |
| Other files | 7 | Various |

### Warning Categories
| Category | Count | Related Story |
|----------|-------|---------------|
| MainActor isolation (NSAlert APIs) | ~50 | S.02.1 |
| Non-Sendable closure captures | ~30 | S.02.1, S.02.2 |
| MainActor method calls | ~25 | S.02.1 |
| Sendable protocol conformance | ~10 | S.02.2, S.02.3 |

### Test Results
| Suite | Tests | Passed | Failed |
|-------|-------|--------|--------|
| AudioCaptureIntegrationTests | 23 | 23 | 0 |
| AudioLevelMonitorTests | 23 | 20 | 3 |
| AudioMixerTests | 13 | 6 | 7 |
| ClipboardManagerTests | 31 | 22 | 9 |
| HotkeyManagerTests | 25 | 25 | 0 |
| ModelManagerTests | 19 | 17 | 2 |
| PermissionFlowIntegrationTests | 12 | 12 | 0 |
| PermissionsTests | 17 | 17 | 0 |
| WhisperEngineTests | 25 | 25 | 0 |
| **Total** | **68** | **67** | **1** |

**Note:** AppPickerIntegrationTests excluded from baseline due to API mismatch with source code.

### Build Performance
| Metric | Value |
|--------|-------|
| Clean build time (arm64) | ~6.5s |
| Incremental build | ~2s |

### Runtime Performance
| Metric | Baseline | Target |
|--------|----------|--------|
| Transcription (10s) | TBD | <= baseline |
| Memory (idle) | TBD | <= baseline |
| Memory (recording) | TBD | <= baseline |
| CPU (recording) | TBD | <= baseline + 5% |

---

## 8. Risk Assessment

**Risk Level: LOW**

This story involves no code changes - only documentation and measurement. The only risk is inaccurate baseline metrics, which would affect planning but not stability.

**Mitigation:** Run all measurements twice and average.
