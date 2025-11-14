# MacTalk Testing Guide

## Overview

This document explains how to run the unit tests for MacTalk. All tests are written using XCTest and can be run directly in Xcode.

## Test Coverage

We have created comprehensive unit tests for the following components:

### 1. RingBufferTests.swift (~200 lines, 15+ tests)
- Basic operations (push, pop, peek, clear)
- Overflow handling
- Multiple operations (popMultiple, pushSamples)
- Thread safety (concurrent push/pop, multiple writers)
- Edge cases (empty buffer, single element, wrap-around)
- Performance benchmarks

### 2. AudioLevelMonitorTests.swift (~300+ lines, 20+ tests)
- RMS calculation (silence, constant signal, sine wave)
- Peak detection (positive and negative values)
- Peak hold with decay
- Smoothing and convergence
- Decibel conversion utilities
- Multi-channel monitoring
- Edge cases (empty buffer, clipping)
- Performance benchmarks

### 3. AudioMixerTests.swift (~250 lines, 15+ tests)
- Format conversion (16kHz, 48kHz, 44.1kHz)
- Sample rate conversion accuracy
- Stereo to mono downmixing
- Multiple conversions with same/different formats
- Sample value preservation
- Edge cases (empty, small, large buffers)
- Performance benchmarks

### 4. ModelManagerTests.swift (~250 lines, 15+ tests)
- Path management
- Model existence checks
- Model naming conventions
- Model size calculations
- Model deletion
- List available models
- Directory creation
- Edge cases (empty names, special characters, path traversal)

**Total: 60+ test methods covering all core components**

## Prerequisites

Before running tests, you need:

1. **Xcode 15.0+** installed on macOS 14.0+
2. **MacTalk.xcodeproj** created (✅ Done)
3. **Test files** in MacTalkTests/ directory (✅ Done)

## How to Run Tests in Xcode

### Step 1: Open the Project

```bash
cd MacTalk/MacTalk
open MacTalk.xcodeproj
```

This will open the project in Xcode.

### Step 2: Select the MacTalk Scheme

In the Xcode toolbar at the top:
1. Click on the scheme selector (left of the play/stop buttons)
2. Ensure "MacTalk" is selected
3. Select "My Mac" as the destination

### Step 3: Run All Tests

Use any of these methods:

**Method 1: Keyboard Shortcut**
```
Press: Cmd + U
```

**Method 2: Menu**
```
Product → Test
```

**Method 3: Test Navigator**
```
1. Open Test Navigator (Cmd + 6)
2. Click the ▶ button next to "MacTalkTests"
```

### Step 4: Run Individual Test Files

To run a specific test file:

1. Open Test Navigator (Cmd + 6)
2. Expand "MacTalkTests"
3. Click the ▶ button next to the specific test file:
   - RingBufferTests
   - AudioLevelMonitorTests
   - AudioMixerTests
   - ModelManagerTests

### Step 5: Run Individual Tests

To run a single test method:

1. Open the test file in Xcode
2. Look for the diamond icon (◇) in the gutter next to each test method
3. Click the diamond to run just that test
4. It will turn into a checkmark (✓) if passed or X (✗) if failed

## Understanding Test Results

### Test Success
```
✓ All tests passed
Test Suite 'MacTalkTests' passed at 2025-01-15 10:30:00.123
     Executed 60 tests, with 0 failures (0 unexpected) in 2.5 seconds
```

### Test Failure
If a test fails, you'll see:
```
✗ testRMSCalculationSilence failed
XCTAssertEqual failed: ("0.5") is not equal to ("0.0")
```

## Expected Test Behavior

### Tests That Should Pass Immediately

These tests don't require any external dependencies:

- ✅ **RingBufferTests**: All tests should pass (pure Swift, no dependencies)
- ✅ **AudioLevelMonitorTests**: All tests should pass (uses Accelerate framework)
- ✅ **AudioMixerTests**: All tests should pass (uses AVFoundation)

### Tests That May Need Adjustment

These tests reference components that depend on whisper.cpp:

- ⚠️ **ModelManagerTests**: Some tests may fail if the actual `ModelManager` implementation isn't complete yet

## Common Issues and Solutions

### Issue 1: "Cannot find 'ModelManager' in scope"

**Cause**: The test file can't see the implementation.

**Solution**: Make sure `ModelManager.swift` is added to the MacTalk target:
1. Select `ModelManager.swift` in Project Navigator
2. Open File Inspector (Cmd + Option + 1)
3. Under "Target Membership", ensure "MacTalk" is checked

### Issue 2: "Use of undeclared type 'RingBuffer'"

**Cause**: Test target can't access the main app's code.

**Solution**: The implementation files need to be visible to tests:
1. Ensure all source files are in the MacTalk target
2. If using `@testable import MacTalk`, ensure the scheme builds the app before tests

### Issue 3: Build Fails Due to Missing whisper.cpp

**Cause**: WhisperBridge.mm references whisper.cpp headers that aren't built yet.

**Solution**: This is expected. For now, you can:

**Option A**: Comment out whisper.cpp integration temporarily
```swift
// In WhisperBridge.mm, comment out whisper.cpp includes
// #include "whisper.h"
```

**Option B**: Build whisper.cpp first (see `docs/XCODE_BUILD.md`)

**Option C**: Remove WhisperBridge.mm from the MacTalk target temporarily:
1. Select WhisperBridge.mm in Project Navigator
2. File Inspector → Target Membership
3. Uncheck "MacTalk"

### Issue 4: Performance Tests Take Too Long

**Cause**: Performance tests use `measure { }` blocks which run multiple iterations.

**Solution**: This is normal. Performance tests may take 10-30 seconds each.

### Issue 5: Thread Safety Tests Fail Intermittently

**Cause**: Race conditions in concurrent tests are timing-dependent.

**Solution**: Re-run the test. If it fails consistently, there may be a real concurrency bug.

## Running Tests from Command Line

You can also run tests from the terminal:

```bash
# Run all tests
xcodebuild test \
  -project MacTalk.xcodeproj \
  -scheme MacTalk \
  -destination 'platform=macOS'

# Run specific test class
xcodebuild test \
  -project MacTalk.xcodeproj \
  -scheme MacTalk \
  -destination 'platform=macOS' \
  -only-testing:MacTalkTests/RingBufferTests
```

## Test-Driven Development Workflow

When adding new features:

1. **Write the test first** (TDD approach)
   ```swift
   func testNewFeature() {
       let result = myComponent.newFeature()
       XCTAssertEqual(result, expectedValue)
   }
   ```

2. **Run the test** - it should fail (red)

3. **Implement the feature** - write minimal code to pass

4. **Run the test again** - it should pass (green)

5. **Refactor** - improve the code while keeping tests passing

## Continuous Integration

For CI/CD pipelines (GitHub Actions, etc.):

```yaml
- name: Run tests
  run: |
    xcodebuild test \
      -project MacTalk/MacTalk.xcodeproj \
      -scheme MacTalk \
      -destination 'platform=macOS' \
      -enableCodeCoverage YES
```

## Code Coverage

To see code coverage:

1. Run tests (Cmd + U)
2. Open Report Navigator (Cmd + 9)
3. Select the latest test run
4. Click "Coverage" tab
5. See coverage percentages for each file

**Coverage Goals**:
- Core audio components: >90%
- UI components: >70%
- Utility classes: >95%

## Next Steps

After tests pass:

1. ✅ Commit the test files
2. ✅ Update PROGRESS.md with test coverage metrics
3. ⬜ Set up CI/CD to run tests on every commit
4. ⬜ Add integration tests for complete workflows
5. ⬜ Add UI tests for menu bar interactions

## Troubleshooting

If you encounter any issues not covered here:

1. Check the Xcode console for detailed error messages
2. Review the test code for typos or incorrect assertions
3. Verify all source files are properly added to targets
4. Clean build folder: Product → Clean Build Folder (Cmd + Shift + K)
5. Restart Xcode if the issue persists

## Notes for This Session

**IMPORTANT**: I created the Xcode project and test files, but I cannot run the tests directly because:

- This development environment is running on Linux
- Swift compiler and Xcode are not available here
- Tests must be run on an actual macOS system with Xcode

**What I've Completed**:
- ✅ Created 4 comprehensive test files (60+ tests)
- ✅ Generated Xcode project with proper targets
- ✅ Configured test target with correct settings
- ✅ Created shared scheme for easy testing

**What You Need to Do**:
1. Open `MacTalk.xcodeproj` in Xcode on your Mac
2. Press **Cmd + U** to run all tests
3. Review test results
4. Report back any failures so I can fix them

Once you confirm the tests pass, we can commit and push all changes to the repository.
