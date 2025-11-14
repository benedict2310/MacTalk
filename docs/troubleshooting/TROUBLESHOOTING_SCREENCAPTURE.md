# Troubleshooting ScreenCaptureKit Issues

## The Problem: Intermittent Failures

The "Mic + App Audio" mode may **work sometimes but fail unpredictably**. This is due to a **known macOS bug** where the `replayd` daemon (handles screen recording) becomes unresponsive.

### Symptoms

When it breaks, you'll see:
- ✅ App picker shows but hangs when loading sources
- ✅ Permission dialog appears but doesn't actually grant permission
- ✅ Timeout errors after 5 seconds
- ✅ Nothing happens when clicking "Start (Mic + App Audio)"

### When It Happens

The `replayd` daemon becomes unresponsive:
- After running SwiftUI Previews that use ScreenCaptureKit
- When multiple app instances call SCShareableContent simultaneously
- After system sleep/wake cycles
- Randomly after previous screen capture sessions
- During development when rebuilding frequently

## Fixes Applied (In This PR)

Our implementation now includes protections:

1. **Synchronous Permission Check**: Uses `CGPreflightScreenCaptureAccess()` instead of async `SCShareableContent` for permission checking
2. **Timeout Protection**: Wraps `SCShareableContent` calls with 5-second timeout
3. **Better Error Messages**: Shows troubleshooting steps when timeout occurs
4. **Permission Request**: Explicitly calls `CGRequestScreenCaptureAccess()` to register app with TCC

## Quick Recovery Steps

When Mic + App mode stops working:

### Option 1: Restart replayd (Fastest)
```bash
sudo killall -9 replayd
```
Wait 2-3 seconds for macOS to restart it automatically, then try again.

### Option 2: Log Out and Back In
More reliable than Option 1 if killall doesn't work.

### Option 3: Restart macOS
Nuclear option, but guaranteed to work.

## Prevention During Development

### 1. Kill replayd After Each Debug Session
```bash
# Add to your workflow after testing Mic + App mode
sudo killall -9 replayd
```

### 2. Avoid Multiple Instances
Don't run multiple copies of MacTalk simultaneously during development.

### 3. Clean Restart Between Builds
```bash
# Kill everything before rebuilding
killall MacTalk
sudo killall -9 replayd
sleep 2
./build.sh run
```

### 4. Monitor Console Logs
Watch for SCShareableContent timeout errors:
```bash
log stream --predicate 'subsystem == "studio.futurelab.MacTalk"' --level debug
```

## Understanding the Error Messages

### "Screen capture system is not responding"
**Cause**: SCShareableContent timed out after 5 seconds
**Fix**: `sudo killall -9 replayd`

### "Screen Recording permission not granted"
**Cause**: Permission check failed OR replayd is stuck
**Fix**:
1. Check System Settings > Privacy & Security > Screen Recording
2. If MacTalk is listed and enabled, run `sudo killall -9 replayd`

### App picker shows but is empty
**Cause**: SCShareableContent returned no apps (replayd issue)
**Fix**: `sudo killall -9 replayd`

## Debugging Checklist

When Mic + App mode fails:

- [ ] Check System Settings > Privacy & Security > Screen Recording - is MacTalk enabled?
- [ ] Run `sudo killall -9 replayd` and wait 3 seconds
- [ ] Try Mic Only mode - does it work? (narrows down to SCK issue)
- [ ] Check Console.app for "MacTalk" errors
- [ ] Look for timeout errors in logs
- [ ] Restart MacTalk completely
- [ ] If still broken: log out and back in

## Technical Details

### Why This Happens

macOS's `replayd` daemon handles all screen recording operations. When it hangs:
1. `SCShareableContent.excludingDesktopWindows()` never returns
2. Permission checks fail even though permission is granted
3. The app appears frozen (but it's waiting for replayd)

### Why Our Fix Helps

1. **Permission Check**: `CGPreflightScreenCaptureAccess()` doesn't talk to replayd, so it never hangs
2. **Timeout**: If `SCShareableContent` hangs, we throw an error after 5 seconds instead of waiting forever
3. **Error Guidance**: Users see clear recovery steps instead of a frozen app

### Known Limitations

Even with our fixes:
- Can't force replayd to restart automatically (requires sudo)
- Can't detect if replayd is stuck *before* calling SCShareableContent
- macOS might show stale permission state if replayd is stuck

## Future Improvements

Potential enhancements to explore:

1. **Automatic replayd Health Check**
   - Ping replayd before attempting SCShareableContent
   - Show warning if replayd is unresponsive

2. **Retry Logic**
   - Auto-retry with exponential backoff on timeout
   - Suggest killall after N failed attempts

3. **Background Permission Refresh**
   - Periodically check CGPreflightScreenCaptureAccess
   - Disable "Mic + App" menu item if permission lost

4. **Developer Mode**
   - Auto-kill replayd between runs during development
   - Verbose logging for SCK operations

## References

- Stack Overflow: ["SCShareableContent hangs indefinitely"](https://stackoverflow.com/questions/74203108/)
- Apple Forums: Multiple reports of replayd issues
- Our research: `docs/SCREENCAPTUREKIT_PERMISSIONS.md`
- Implementation: `MacTalk/MacTalk/Utilities/AsyncTimeout.swift`

## Summary

**The inconsistent behavior is a known macOS bug, not a bug in our code.** Our implementation now:
- ✅ Detects the hang with timeout protection
- ✅ Shows helpful error messages
- ✅ Avoids hanging on permission checks

But we **cannot** prevent replayd from becoming unresponsive - that's an operating system issue. The best we can do is:
1. Detect it quickly (timeout)
2. Give clear recovery instructions
3. Document the workaround

When it breaks during development: **`sudo killall -9 replayd`** is your friend.
