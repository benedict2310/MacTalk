# TCC Permissions Development Guide

## The Problem: Permissions Lost After Each Rebuild

If you're experiencing permission dialogs on **every rebuild** even though you've already granted permissions, you're hitting a fundamental macOS TCC (Transparency, Consent, and Control) issue.

### Root Cause

macOS tracks app permissions using **BOTH**:
1. **Bundle Identifier** (`com.mactalk.app`)
2. **Code Signature** (cryptographic hash of the app's identity)

When you rebuild an app with **ad-hoc signing** ("Sign to Run Locally"), the code signature **changes on every build**. macOS treats this as a completely different app, so permissions don't carry over.

### Symptoms

- ✅ You grant Screen Recording permission in System Settings
- ✅ MacTalk shows up in the list with checkbox enabled
- ❌ `CGPreflightScreenCaptureAccess()` returns `false`
- ❌ Permission dialogs appear every time you try to use the feature
- ❌ Same issue with Accessibility permissions and `AXIsProcessTrusted()`

**The permission detection code is working correctly** - it's correctly reporting that THIS build doesn't have permission, even though the PREVIOUS build did!

---

## Solution 1: Use Stable Code Signing (Recommended)

### What This Does
Uses your **Apple Development** certificate to sign every build with the **same identity**. macOS will recognize subsequent builds as the same app and preserve permissions.

### Prerequisites
- Apple ID registered with Apple Developer Program (free or paid)
- "Apple Development" certificate installed (Xcode installs this automatically)

### Implementation

**Already configured in this project!** The `project.yml` now includes:
```yaml
CODE_SIGN_STYLE: Automatic
DEVELOPMENT_TEAM: "9SXL4GJ4TZ"  # Your actual Team ID from certificate OU
```

### How to Use

1. **Regenerate Xcode project** (picks up new signing config):
   ```bash
   xcodegen generate
   ```

2. **Clean TCC database** (fresh start):
   ```bash
   ./scripts/reset-tcc-permissions.sh
   ```

3. **Build and run**:
   ```bash
   ./build.sh run
   ```

4. **Grant permissions when prompted** (first time only!)

5. **Rebuild and run again**:
   ```bash
   ./build.sh run
   ```

6. **✅ Permissions should persist!** No dialogs on subsequent builds.

### Verify It's Working

Check the code signature:
```bash
codesign -dvvv /Users/bene/Library/Developer/Xcode/DerivedData/MacTalk-*/Build/Products/Release/MacTalk.app 2>&1 | grep "Authority"
```

Should show:
```
Authority=Apple Development: your.email@example.com (TEAM_ID)
```

NOT:
```
Authority=Apple Development: - (Ad Hoc Signed)
```

---

## Solution 2: TCC Reset Helper (Quick Workaround)

If you can't use stable signing (e.g., no Apple Developer account), use this script to reset permissions between builds.

### How to Use

1. **Make the script executable** (first time only):
   ```bash
   chmod +x ./scripts/reset-tcc-permissions.sh
   ```

2. **Before each rebuild, reset TCC**:
   ```bash
   ./scripts/reset-tcc-permissions.sh
   ```

3. **Build and run**:
   ```bash
   ./build.sh run
   ```

4. **Grant permissions when prompted**

### What the Script Does

- Stops MacTalk if running
- Resets Screen Recording permission: `tccutil reset ScreenCapture com.mactalk.app`
- Resets Accessibility permission: `tccutil reset Accessibility com.mactalk.app`
- Resets Microphone permission: `tccutil reset Microphone com.mactalk.app`

This forces macOS to "forget" the old build and treat the new build as a first-time launch.

---

## Manual TCC Reset

If the script doesn't work, manually reset permissions:

### Via System Settings (GUI)

1. Open **System Settings**
2. Go to **Privacy & Security**
3. Click **Screen Recording** / **Accessibility** / **Microphone**
4. Find **MacTalk** in the list
5. **Uncheck** the checkbox
6. **Delete** the entry (click the "−" button)
7. Rebuild and relaunch MacTalk
8. Grant permission when prompted

### Via Terminal (Advanced)

**Reset all TCC permissions for MacTalk:**
```bash
tccutil reset All com.mactalk.app
```

**Reset specific services:**
```bash
# Screen Recording
tccutil reset ScreenCapture com.mactalk.app

# Accessibility
tccutil reset Accessibility com.mactalk.app

# Microphone
tccutil reset Microphone com.mactalk.app
```

**Nuclear option (reset ALL apps for a service):**
```bash
tccutil reset ScreenCapture
tccutil reset Accessibility
```

---

## Development vs Production Builds

### The Debug/Release Confusion

If you have **both** a Debug build (from Xcode) AND a Release build (from `./build.sh`) in your Applications folder:

- System Settings may show **two separate entries** for MacTalk
- Each has its own code signature
- Permissions granted to one don't apply to the other!

### Solution

**Choose ONE build location for development:**

**Option A: Use Xcode DerivedData (Debug)**
```bash
# Launch from DerivedData
open /Users/bene/Library/Developer/Xcode/DerivedData/MacTalk-*/Build/Products/Debug/MacTalk.app
```

**Option B: Use build script (Release)**
```bash
# Launch from build script
./build.sh run
```

**Option C: Install to Applications (Release)**
```bash
# Copy to Applications
cp -R /Users/bene/Library/Developer/Xcode/DerivedData/MacTalk-*/Build/Products/Release/MacTalk.app /Applications/

# Grant permissions to THIS build
open /Applications/MacTalk.app
```

**⚠️ Don't mix builds!** If you switch, reset TCC and re-grant permissions.

---

## Debugging Permission Issues

### Check Permission Status in Code

The logs show exactly what's happening:

**Screen Recording:**
```bash
log stream --predicate 'process == "MacTalk"' --style compact | grep "Screen recording permission"
```

Expected output:
```
✅ [Permissions] Screen recording permission GRANTED
```

**Accessibility:**
```bash
log stream --predicate 'process == "MacTalk"' --style compact | grep "Accessibility permission"
```

Expected output:
```
🔐 [Permissions] Accessibility permission check: TRUSTED ✅
```

### Check TCC Database Directly

**List all TCC entries for MacTalk:**
```bash
# macOS Sonoma+
sqlite3 ~/Library/Application\ Support/com.apple.TCC/TCC.db \
  "SELECT service, client, auth_value FROM access WHERE client LIKE '%mactalk%';"
```

**Columns:**
- `service`: e.g., `kTCCServiceScreenCapture`, `kTCCServiceAccessibility`
- `client`: Bundle identifier
- `auth_value`: `0` = denied, `1` = allowed, `2` = limited

### Check Code Signature

**Current running app:**
```bash
ps aux | grep MacTalk | grep -v grep
codesign -dvvv /proc/$(pgrep MacTalk)/exe 2>&1 | grep -E "Authority|Identifier|TeamIdentifier"
```

**Built app:**
```bash
codesign -dvvv /Users/bene/Library/Developer/Xcode/DerivedData/MacTalk-*/Build/Products/Release/MacTalk.app 2>&1 | grep -E "Authority|Identifier|TeamIdentifier"
```

**Compare two builds:**
```bash
# Build 1
codesign -dvvv /path/to/build1/MacTalk.app 2>&1 | shasum -a 256

# Build 2
codesign -dvvv /path/to/build2/MacTalk.app 2>&1 | shasum -a 256
```

If the hashes are **different**, TCC treats them as different apps!

---

## Common Mistakes

### ❌ Granting Permission to the Wrong Build

**Problem:**
- You grant permission to `/Applications/MacTalk.app`
- But you run from `DerivedData/MacTalk-*/Build/Products/Debug/MacTalk.app`
- Two different apps! Permission doesn't apply.

**Solution:**
- Remove `/Applications/MacTalk.app` entirely during development
- OR: Always launch from `/Applications/` and copy new builds there

### ❌ Forgetting to Regenerate Xcode Project

**Problem:**
- You edit `project.yml` to add `DEVELOPMENT_TEAM`
- But don't run `xcodegen generate`
- Xcode still uses old configuration (ad-hoc signing)

**Solution:**
```bash
xcodegen generate
```

### ❌ Using Hardened Runtime Without Entitlements

**Problem:**
- `ENABLE_HARDENED_RUNTIME: YES` without proper entitlements
- TCC permissions may be blocked even when granted

**Solution:**
- Keep `ENABLE_HARDENED_RUNTIME: NO` for development
- OR: Add proper entitlements file with required permissions

### ❌ Multiple Xcode Versions

**Problem:**
- Different Xcode versions may use different signing certificates
- Switching Xcode versions changes code signature

**Solution:**
- Use consistent Xcode version for development
- Check: `xcode-select -p` to see active Xcode path

---

## Best Practices for Development

### ✅ Recommended Workflow

1. **Use stable signing** (Apple Development certificate)
2. **Pick one build location** (DerivedData or Applications)
3. **Reset TCC before major changes** (switching signing, moving builds)
4. **Check logs** (`log stream`) to verify permission status
5. **Don't manually edit TCC database** (use `tccutil` or System Settings)

### ✅ Modified Build Script

The build script could be enhanced to automatically handle TCC:

```bash
#!/bin/bash
# build.sh

# Option: Reset TCC before build (uncomment if needed)
# ./scripts/reset-tcc-permissions.sh

# Build
xcodebuild -project MacTalk.xcodeproj -scheme MacTalk -configuration Release build

# Run
open /Users/bene/Library/Developer/Xcode/DerivedData/MacTalk-*/Build/Products/Release/MacTalk.app
```

### ✅ CI/CD Considerations

For automated testing with TCC permissions:
- Use UI testing with granted permissions
- Run on real macOS hardware (not VM)
- Use `tccutil` in CI scripts to pre-grant permissions
- Disable SIP (System Integrity Protection) on CI machines if needed

---

## References

- [Apple Developer Forums: TCC Permissions](https://developer.apple.com/forums/thread/730043)
- [Stack Overflow: CGPreflightScreenCaptureAccess](https://stackoverflow.com/questions/70537845)
- [Stack Overflow: AXIsProcessTrusted](https://stackoverflow.com/questions/10752906)
- [Apple TCC Documentation](https://developer.apple.com/documentation/bundleresources/entitlements)

---

## FAQ

**Q: Why does System Settings show MacTalk with permission enabled, but the app says it doesn't have permission?**

A: The System Settings entry is for a PREVIOUS build. The current build has a different code signature. Remove the old entry and grant permission to the new build.

**Q: Do I need a paid Apple Developer account for stable signing?**

A: No! A free Apple ID is enough to get an "Apple Development" certificate for local development. You only need a paid account for App Store distribution.

**Q: Will this affect my production/release builds?**

A: No. Production builds should use a different signing identity (Developer ID) and will have their own TCC entries separate from development builds.

**Q: Can I use the same signing for Debug and Release builds?**

A: Yes! That's the recommended approach. Set `DEVELOPMENT_TEAM` in `project.yml` and both configurations will use the same certificate.

**Q: What if I accidentally have multiple entries in System Settings?**

A: Remove ALL entries for MacTalk, reset TCC with `tccutil reset`, rebuild, and grant permission to the fresh build.

---

**Last Updated:** 2025-01-11
**Status:** Tested and validated on macOS Sequoia 15.x (Tahoe)
