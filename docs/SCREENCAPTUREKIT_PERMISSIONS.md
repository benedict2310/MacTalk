# ScreenCaptureKit Permissions Investigation

## Issue
Mic + App audio mode works inconsistently. Sometimes it works, sometimes it fails with permission errors, even when Screen Recording permission appears to be granted in System Settings.

## Current Implementation

### Permission Check (Permissions.swift)
```swift
static func checkScreenRecordingPermission() async -> Bool {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        return !content.displays.isEmpty
    } catch {
        return false
    }
}
```

### Audio Source Loading (StatusBarController.swift - Pattern 1)
```swift
private func loadAudioSources() async throws -> [AppPickerWindowController.AudioSource] {
    // Check screen recording permission first
    let hasPermission = await Permissions.checkScreenRecordingPermission()

    guard hasPermission else {
        showError("Screen Recording permission is required...")
        return []
    }

    // Fetch shareable content
    let content = try await SCShareableContent.excludingDesktopWindows(
        false,
        onScreenWindowsOnly: true
    )

    // Build audio sources list...
}
```

## Observations

1. **Race Condition Fixed**: Pattern 1 implementation eliminated the UI race condition where window showed before data loaded
2. **Permission Issue Persists**: Even with Pattern 1, permission checks are failing intermittently
3. **System Settings Shows Permission Granted**: User has confirmed Screen Recording permission is enabled in System Settings
4. **Inconsistent Behavior**: Sometimes works, sometimes fails - not deterministic

## Potential Root Causes

### 1. TCC (Transparency, Consent, and Control) Database Issues
- macOS caches TCC permissions
- Changes in System Settings may not propagate immediately
- App signature/bundle ID changes can invalidate cached permissions

### 2. ScreenCaptureKit API Behavior
- First call to `SCShareableContent` may trigger permission prompt
- Subsequent calls may fail if permission denied
- Permission state may not be immediately available after granting

### 3. App Bundle Signature Changes
- Development builds vs. Release builds have different signatures
- Code signing during build may invalidate TCC entries
- Each rebuild may require re-granting permission

### 4. macOS Version-Specific Behavior
- macOS 14+ has stricter ScreenCaptureKit requirements
- Permission model changed in recent macOS versions
- Behavior may differ between macOS 14.0, 14.1, etc.

## Research Findings

### 1. Root Cause: SCShareableContent Can Hang ⚠️

**Critical Discovery**: `SCShareableContent` has a known macOS bug where it can hang indefinitely and never return or throw an error.

**When this happens:**
- After using SwiftUI Previews that call SCShareableContent
- When multiple app instances run simultaneously
- Randomly after system sleep/wake cycles
- After previous screen capture sessions

**Symptoms:**
- `await SCShareableContent.excludingDesktopWindows()` never completes
- No error thrown, just infinite wait
- App appears frozen during permission check
- Only affects ScreenCaptureKit calls

**Workarounds:**
1. **Restart replayd daemon**: `killall -9 replayd` (most immediate)
2. **Log out and back in** (resets user session)
3. **Restart macOS** (most reliable)
4. **Add timeout** to SCShareableContent calls
5. **Properly close SCStream** instances to prevent resource conflicts

### 2. Proper Permission Checking API

**CGPreflightScreenCaptureAccess()** (macOS 11+)
- ✅ Synchronous call, no hanging issues
- ✅ Direct TCC permission check
- ⚠️ May return false for development builds initially
- ⚠️ Doesn't update immediately after permission granted (requires app restart)
- ❌ Crashes on macOS 10.15 (Catalina)

**CGRequestScreenCaptureAccess()** (macOS 11+)
- Triggers permission dialog if not granted
- Should be called before using ScreenCaptureKit APIs
- Also requires macOS 11+

### 3. Why Our Current Implementation Fails

```swift
// CURRENT IMPLEMENTATION - PROBLEMATIC
static func checkScreenRecordingPermission() async -> Bool {
    do {
        // THIS CAN HANG INDEFINITELY! ⚠️
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        return !content.displays.isEmpty
    } catch {
        return false
    }
}
```

**Problems:**
1. Uses SCShareableContent for permission checking (can hang)
2. No timeout protection
3. Async call that may never complete
4. Heavy operation just to check a boolean permission state

### 4. Best Practice Solution

**For macOS 11+ (our target is macOS 14.0+):**

```swift
// Use CGPreflightScreenCaptureAccess - synchronous, reliable
func checkScreenRecordingPermission() -> Bool {
    if #available(macOS 11.0, *) {
        return CGPreflightScreenCaptureAccess()
    } else {
        // Fallback for older macOS (not needed for our target)
        return false
    }
}

// Request permission if needed
func requestScreenRecordingPermission() {
    if #available(macOS 11.0, *) {
        CGRequestScreenCaptureAccess()
    }
}
```

**For loading audio sources:**
```swift
// Add timeout protection to SCShareableContent calls
func loadAudioSources() async throws -> [AudioSource] {
    let content = try await withTimeout(seconds: 5) {
        try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
    }
    // Process content...
}
```

### 5. macOS Version-Specific Behavior

- **macOS 10.15 (Catalina)**: CGPreflightScreenCaptureAccess crashes, use window inspection
- **macOS 11+ (Big Sur+)**: CGPreflightScreenCaptureAccess available and reliable
- **macOS 12+ (Monterey+)**: ScreenCaptureKit fully supported
- **macOS 15+ (Sequoia)**: Apple encouraging migration to SCContentSharingPicker

## Testing Scenarios

- [ ] Fresh app launch (never granted permission)
- [ ] After granting permission in System Settings
- [ ] After rebuilding app
- [ ] After changing bundle ID or signature
- [ ] After macOS restart
- [ ] Multiple consecutive attempts
- [ ] With/without logging enabled

## Info.plist Keys (Current)

```xml
<key>NSMicrophoneUsageDescription</key>
<string>MacTalk needs microphone access to transcribe your voice.</string>

<!-- Note: No explicit ScreenCaptureKit key exists -->
```

## Recommended Solution

### Phase 1: Switch to CGPreflightScreenCaptureAccess (Immediate)

Replace the current `checkScreenRecordingPermission()` implementation:

```swift
// In Permissions.swift
static func checkScreenRecordingPermission() -> Bool {
    // Use CGPreflightScreenCaptureAccess for reliable, synchronous check
    return CGPreflightScreenCaptureAccess()
}

static func requestScreenRecordingPermission() {
    // Trigger the system permission dialog
    CGRequestScreenCaptureAccess()
}
```

### Phase 2: Add Timeout Protection to SCShareableContent (Critical)

```swift
// Add timeout utility
func withTimeout<T>(
    seconds: TimeInterval,
    operation: @escaping () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

// Apply to loadAudioSources
private func loadAudioSources() async throws -> [AppPickerWindowController.AudioSource] {
    // Quick permission check first (synchronous, reliable)
    guard CGPreflightScreenCaptureAccess() else {
        throw PermissionError.screenRecordingNotGranted
    }

    // Then load sources with timeout protection
    let content = try await withTimeout(seconds: 5) {
        try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
    }

    // Build sources list...
}
```

### Phase 3: User-Facing Error Handling

```swift
// In StatusBarController.showAppPicker()
do {
    let sources = try await loadAudioSources()
    // Continue with window creation...
} catch is TimeoutError {
    showError("""
        Screen capture system is not responding.

        Try:
        1. Run: killall -9 replayd
        2. Log out and back in
        3. Restart your Mac

        This is a known macOS bug with ScreenCaptureKit.
        """)
} catch is PermissionError {
    showError("""
        Screen Recording permission required.

        Please enable in:
        System Settings > Privacy & Security > Screen Recording > MacTalk

        Then restart MacTalk.
        """)
}
```

## Implementation Priority

1. ✅ **CRITICAL**: Replace `checkScreenRecordingPermission()` with `CGPreflightScreenCaptureAccess()`
2. ✅ **HIGH**: Add timeout protection to `SCShareableContent` calls
3. ✅ **MEDIUM**: Improve error messages with troubleshooting steps
4. ⚠️ **OPTIONAL**: Add "Reset replayd" button in Settings for user convenience

## Expected Improvements

- ✅ No more infinite hangs when checking permission
- ✅ Synchronous permission checks (no async complexity)
- ✅ Clearer error messages for users
- ✅ Graceful degradation when ScreenCaptureKit is unresponsive
- ✅ Better user experience with actionable troubleshooting

## References
- [ScreenCaptureKit Documentation](https://developer.apple.com/documentation/screencapturekit)
- [CGPreflightScreenCaptureAccess](https://developer.apple.com/documentation/coregraphics/1455373-cgpreflightscreencaptureaccess)
- [Stack Overflow: SCShareableContent Hanging](https://stackoverflow.com/questions/75826795/)
- [Stack Overflow: Screen Recording Permissions](https://stackoverflow.com/questions/56597221/)
- [TCC Database Deep Dive](https://www.rainforestqa.com/blog/macos-tcc-db-deep-dive)

## Current Status
**ROOT CAUSE IDENTIFIED** - SCShareableContent can hang indefinitely (known macOS bug).
**SOLUTION DOCUMENTED** - Switch to CGPreflightScreenCaptureAccess() + add timeout protection.
