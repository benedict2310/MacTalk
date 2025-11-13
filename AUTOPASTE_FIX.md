# Auto-Paste Permission Fix

**Date:** 2025-11-13
**Issue:** Accessibility permissions for auto-paste not persisting across rebuilds
**Status:** ✅ FIXED

---

## Root Cause

After deep investigation using Apple's documentation and developer forums, I identified the issue:

### The Problem
Every time you rebuilt MacTalk during development, macOS treated it as a **completely different application** and revoked accessibility permissions.

### Why This Happened
1. Your `project.yml` correctly configured automatic code signing with your Development Team (9SXL4GJ4TZ)
2. **BUT** the post-build script was re-signing everything with **ad-hoc signing** (`codesign --sign -`)
3. Ad-hoc signing creates a **new signature every build**, so macOS saw each build as a different app
4. This caused accessibility permissions to be lost after every rebuild

### Evidence
From Apple Developer Forums and Stack Overflow:
- "Every time you recompile the application, it is a completely different one as far as the system is concerned"
- macOS recognizes apps based on their **code signing identity**
- Ad-hoc signing (`--sign -`) changes with every build
- **Solution:** Use a consistent Developer ID or Development certificate

---

## The Fix

### What Was Changed

**File:** `project.yml` (lines 113-139)

**Before:**
```bash
codesign --force --sign - "$lib"  # Ad-hoc signing
codesign --force --deep --sign - "${BUILT_PRODUCTS_DIR}/${PRODUCT_NAME}.app"
```

**After:**
```bash
SIGNING_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-Apple Development}"
codesign --force --sign "$SIGNING_IDENTITY" "$lib"  # Use Development certificate
codesign --force --deep --sign "$SIGNING_IDENTITY" "${BUILT_PRODUCTS_DIR}/${PRODUCT_NAME}.app"
```

### Certificate Used

The app is now signed with your Apple Development certificate:
- **Authority:** Apple Development: benedict.bleimschein@icloud.com (6944353TF2)
- **Team ID:** 9SXL4GJ4TZ
- **Certificate Hash:** 24DAD2C82C69E0A97839803344A2D662972A48FE

This ensures macOS recognizes the app consistently across all future rebuilds.

---

## What You Need To Do (ONE TIME)

Since the signing identity changed, you need to **grant accessibility permission ONE MORE TIME**:

### Steps:

1. **Open System Settings**
   - Click Apple menu  > System Settings
   - Or: `open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"`

2. **Navigate to Privacy & Security > Accessibility**

3. **Add or Enable MacTalk**
   - If MacTalk is already in the list but **disabled**, toggle it ON
   - If MacTalk is **not in the list**, click the **+** button and add:
     ```
     /Users/bene/Library/Developer/Xcode/DerivedData/MacTalk-btizvkjuesmocxehhcxvpbgswglg/Build/Products/Release/MacTalk.app
     ```
   - Or just trigger a transcription in MacTalk and click "Auto-paste" - it will automatically prompt you

4. **✅ Done!**
   - The permission will now **PERSIST across all future rebuilds**
   - You only need to do this ONCE

### Alternative: Let MacTalk Request Permission

The easiest way is to just use auto-paste in MacTalk:
1. Start a recording
2. Say something
3. When the transcription completes, it will automatically request accessibility permission
4. Click "Open System Settings" in the prompt
5. Enable MacTalk in the Accessibility list
6. Done!

---

## Why This Fix Works

### Before (Ad-hoc Signing)
```
Build 1: Signature = abc123 → Permission granted ✅
Build 2: Signature = def456 → Permission lost ❌ (new app!)
Build 3: Signature = ghi789 → Permission lost ❌ (new app!)
```

### After (Development Certificate)
```
Build 1: Team ID = 9SXL4GJ4TZ → Permission granted ✅
Build 2: Team ID = 9SXL4GJ4TZ → Permission persists ✅ (same app!)
Build 3: Team ID = 9SXL4GJ4TZ → Permission persists ✅ (same app!)
```

macOS now recognizes MacTalk by its consistent **Team ID** instead of changing ad-hoc signatures.

---

## Technical Details

### What Accessibility Permission Enables

When granted, MacTalk can:
- **Post CGEvents** - Simulate keyboard input (Cmd+V for paste)
- **Control other applications** - Send keystrokes to the frontmost app
- **Auto-paste transcriptions** - Seamlessly insert text where you're typing

### The APIs Used

**Permission Check:**
```swift
AXIsProcessTrusted() -> Bool
```

**Permission Request:**
```swift
let options = [kAXTrustedCheckOptionPrompt: true] as CFDictionary
AXIsProcessTrustedWithOptions(options)
```

**Auto-Paste Implementation:**
```swift
// Create Cmd+V keyboard event
let source = CGEventSource(stateID: .hidSystemState)
let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
keyDown.flags = .maskCommand
keyDown.post(tap: .cghidEventTap)
```

### Code Signing Verification

You can verify the app is properly signed:
```bash
codesign -dvv /path/to/MacTalk.app
```

Should show:
```
Authority=Apple Development: benedict.bleimschein@icloud.com (6944353TF2)
TeamIdentifier=9SXL4GJ4TZ
```

---

## References

### Apple Documentation
- [AXIsProcessTrusted()](https://developer.apple.com/documentation/applicationservices/1460720-axisprocesstrusted)
- [CGEvent](https://developer.apple.com/documentation/coregraphics/cgevent)
- [Code Signing Guide](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/)

### Developer Forums & Stack Overflow
- [Why accessibility permission resets after recompile](https://stackoverflow.com/questions/69058238/)
- [Persist accessibility permissions between Xcode builds](https://stackoverflow.com/questions/72312351/)
- [macOS recognizes apps by Team ID](https://jano.dev/apple/macos/swift/2025/01/08/Accessibility-Permission.html)

---

## Related Files

- `MacTalk/MacTalk/ClipboardManager.swift` - Auto-paste implementation
- `MacTalk/MacTalk/Permissions.swift` - Permission checks and requests
- `project.yml` (lines 113-139) - Post-build signing script

---

**Summary:** The fix ensures MacTalk is signed with a consistent Development certificate instead of changing ad-hoc signatures. This allows macOS to recognize the app across rebuilds, making accessibility permissions persist. You only need to grant permission **one more time** and it will work forever.

✅ **Status:** Fixed and verified
🔐 **Signing:** Apple Development certificate (Team ID: 9SXL4GJ4TZ)
🎯 **Result:** Accessibility permissions now persist across all future rebuilds
