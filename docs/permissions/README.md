# macOS Permissions System

MacTalk requires three macOS permissions to function fully. This folder consolidates all documentation related to permission handling, TCC (Transparency, Consent, and Control) system integration, and troubleshooting.

---

## Required Permissions

| Permission | Purpose | Required For | Prompt Timing |
|------------|---------|--------------|---------------|
| **Microphone** | Voice capture | Mic-only mode (Mode A) | On first mic access |
| **Screen Recording** | App audio capture via ScreenCaptureKit | Mic + App mode (Mode B) | On app audio source selection |
| **Accessibility** | Auto-paste simulation (Cmd+V) | Auto-paste feature | When enabling auto-paste in Settings |

---

## Quick Navigation

### Start Here
- **New to permissions?** → [PERMISSIONS_FINAL_SUMMARY.md](PERMISSIONS_FINAL_SUMMARY.md)
- **Implementing permissions?** → [TCC_PERMISSIONS_DEV_GUIDE.md](TCC_PERMISSIONS_DEV_GUIDE.md)
- **Testing permissions?** → [PERMISSION_TESTING_GUIDE.md](PERMISSION_TESTING_GUIDE.md)
- **Debugging issues?** → [TCC_FIX_SUMMARY.md](TCC_FIX_SUMMARY.md)

### Document Guide

#### 📋 [PERMISSIONS_FINAL_SUMMARY.md](PERMISSIONS_FINAL_SUMMARY.md)
**High-level overview of the permission system**

- Summary of all three permissions (Accessibility, Screen Recording, Microphone)
- Root causes of historical permission issues
- Code signing requirements for TCC persistence
- Overview of detection solutions

**Start here if:** You want a bird's-eye view of how permissions work in MacTalk

---

#### 🔍 [PERMISSION_DETECTION_SOLUTION.md](PERMISSION_DETECTION_SOLUTION.md)
**Technical implementation of permission detection logic**

- Detailed implementation of `Permissions.swift`
- How we detect Screen Recording permission (ScreenCaptureKit workaround)
- Session-based deduplication for permission prompts
- API limitations and workarounds (CGPreflight cache issue)

**Read this if:** You're implementing or modifying permission detection code

---

#### 🧪 [PERMISSION_TESTING_GUIDE.md](PERMISSION_TESTING_GUIDE.md)
**Complete testing procedures for all permission flows**

- How to reset TCC permissions for testing
- Step-by-step test scenarios for each permission
- Expected behavior at each stage (denied → granted → revoked)
- Integration test procedures

**Use this if:** You're testing permission flows or validating fixes

---

#### 📺 [SCREENCAPTUREKIT_PERMISSIONS.md](SCREENCAPTUREKIT_PERMISSIONS.md)
**ScreenCaptureKit-specific permission handling**

- How ScreenCaptureKit requests Screen Recording permission
- Relationship between Screen Recording and app audio capture
- SCShareableContent API and permission requirements
- ScreenCaptureKit error handling

**Read this if:** You're working on Mode B (Mic + App Audio) or ScreenCaptureKit integration

---

#### 🔧 [TCC_FIX_SUMMARY.md](TCC_FIX_SUMMARY.md)
**Summary of critical TCC database fixes**

- Code signing issue that broke permission persistence
- Why permissions were lost on every rebuild
- Transition from ad-hoc signing to Development certificate
- Before/after comparison

**Read this if:** You're debugging why permissions don't persist across builds

---

#### 📖 [TCC_PERMISSIONS_DEV_GUIDE.md](TCC_PERMISSIONS_DEV_GUIDE.md)
**Developer guide for macOS TCC system**

- How macOS TCC database works internally
- App identity (bundle ID + code signature designated requirement)
- Code signing best practices for development vs. distribution
- TCC database inspection with `tccutil` and SQL queries

**Read this if:** You want deep understanding of how macOS tracks app permissions

---

## Common Issues & Solutions

### Issue: Permissions lost after rebuilding app
**Root Cause:** Ad-hoc code signing changes signature on every build
**Solution:** Use Development certificate with stable Team ID ([TCC_FIX_SUMMARY.md](TCC_FIX_SUMMARY.md))

### Issue: Screen Recording shows "Not Granted" after granting permission
**Root Cause:** `CGPreflightScreenCaptureAccess()` has stale cache until app restart
**Solution:** Test actual `SCShareableContent` instead of relying on CGPreflight ([PERMISSION_DETECTION_SOLUTION.md](PERMISSION_DETECTION_SOLUTION.md))

### Issue: Accessibility permission dialog appears multiple times
**Root Cause:** No session deduplication for permission prompts
**Solution:** Track prompt state in `UserDefaults` to show once per session ([PERMISSIONS_FINAL_SUMMARY.md](PERMISSIONS_FINAL_SUMMARY.md))

### Issue: App crashes when accessing microphone
**Root Cause:** Missing `NSMicrophoneUsageDescription` in Info.plist
**Solution:** Add usage description string to Info.plist

---

## Testing Permissions

### Reset All Permissions (for testing)

```bash
# Reset MacTalk TCC permissions
tccutil reset Microphone com.mactalk.app
tccutil reset ScreenCapture com.mactalk.app
tccutil reset Accessibility com.mactalk.app

# Or use the script (if available)
./scripts/reset-tcc-permissions.sh
```

### Manual Permission Management

**System Settings:**
- Microphone: System Settings → Privacy & Security → Microphone
- Screen Recording: System Settings → Privacy & Security → Screen Recording
- Accessibility: System Settings → Privacy & Security → Accessibility

---

## Implementation Checklist

When implementing a new feature that requires permissions:

- [ ] Add usage description to `Info.plist` (NSMicrophoneUsageDescription, etc.)
- [ ] Check permission state before accessing protected resource
- [ ] Show clear UI indication of permission status
- [ ] Provide link/button to System Settings if permission denied
- [ ] Handle permission denial gracefully (no crashes)
- [ ] Test with permissions granted, denied, and revoked mid-session
- [ ] Verify permission persists across app restarts
- [ ] Add permission check to Settings → Permissions tab

---

## Architecture Overview

```
User Action (e.g., Start Recording)
         ↓
Permissions.swift check
         ↓
    ┌─────────┴─────────┐
    │ Permission Denied  │ Permission Granted
    ↓                    ↓
Show System Prompt    Proceed with feature
    ↓                    ↓
User Grants/Denies   AudioCapture/ScreenCaptureKit
    ↓
TCC Database Updated
    ↓
App can now access resource
```

**Key Components:**
- `Permissions.swift` - Central permission management (289 lines)
- `Info.plist` - Usage descriptions for prompts
- `SettingsWindowController.swift` - Permissions tab UI
- TCC Database - macOS system permission storage

---

## Related Documentation

- **Architecture:** [../development/ARCHITECTURE.md](../development/ARCHITECTURE.md)
- **Testing:** [../testing/TESTING.md](../testing/TESTING.md)
- **Troubleshooting:** [../troubleshooting/](../troubleshooting/)
- **ScreenCaptureKit Issues:** [../troubleshooting/TROUBLESHOOTING_SCREENCAPTURE.md](../troubleshooting/TROUBLESHOOTING_SCREENCAPTURE.md)

---

## Code Signing Requirements

**Development:**
```yaml
# project.yml
DEVELOPMENT_TEAM: "9SXL4GJ4TZ"  # Apple Development certificate
CODE_SIGN_IDENTITY: "Apple Development"
```

**Distribution:**
```yaml
# project.yml (Release configuration)
DEVELOPMENT_TEAM: "YOUR_TEAM_ID"
CODE_SIGN_IDENTITY: "Apple Distribution"
```

**Why This Matters:** macOS TCC uses code signature to identify your app. Changing signatures = new TCC entry = lost permissions. See [TCC_FIX_SUMMARY.md](TCC_FIX_SUMMARY.md) for details.

---

## macOS Versions

Permission behavior varies by macOS version:

- **macOS 14 (Sonoma):** Minimum supported version
- **macOS 15 (Sequoia):** Current target, stricter TCC enforcement
- **macOS 16 (Tahoe/26):** Tested and working

Always test on oldest and newest supported versions.

---

## Additional Resources

**Apple Documentation:**
- [TCC and User Privacy](https://developer.apple.com/documentation/security/protecting_user_privacy)
- [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit)
- [Accessibility](https://developer.apple.com/documentation/accessibility)

**Internal:**
- Permission integration tests: `MacTalkTests/PermissionFlowIntegrationTests.swift`
- Unit tests: `MacTalkTests/PermissionsTests.swift`

---

**Last Updated:** 2025-11-14
**Maintained by:** MacTalk Development Team
