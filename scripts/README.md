# Build Scripts

This directory contains build automation scripts for MacTalk.

## Scripts

### verify-signing.sh

Verifies a Developer ID signed `MacTalk.app`: Team ID and certificate
consistency across nested dylibs, hardened-runtime flags, the exact approved
release entitlements, `codesign --verify --deep --strict`, and `spctl`. Exit
status 2 means the Developer ID credentials are unavailable, 3 means the
bundle is unsigned or invalid (including a non-notarization Gatekeeper
rejection), and 4 means Gatekeeper identified a valid Developer ID app as
Unnotarized Developer ID.

```bash
SIGNING_IDENTITY='Developer ID Application: Name (TEAM_ID)' \
SIGNING_TEAM_ID='TEAM_ID' scripts/verify-signing.sh /path/to/MacTalk.app
```

### post-build-sign.sh

**Purpose:** Automatically re-signs all whisper.cpp dylibs and the app bundle after Xcode's build phase.

**Why it's needed:** On macOS 26 (Tahoe), whisper.cpp libraries built separately have different Team IDs than the main app. This causes the app to crash on launch with "different Team IDs" error. The post-build script fixes this by re-signing all libraries to match.

**When it runs:** Automatically after every build via XcodeGen post-build script configuration in `project.yml`.

**What it does:**
1. Re-signs all `.dylib` files in `MacTalk.app/Contents/Frameworks/`
2. Re-signs the app bundle with `--deep` flag
3. Prints progress messages with emoji indicators

**Configuration:** Defined in `project.yml` under `postBuildScripts`.

**Output example:**
```
🔐 [Post-Build] Re-signing whisper.cpp libraries...
   ✅ Signed: libggml-base.dylib
   ✅ Signed: libggml-cpu.dylib
   ✅ Signed: libggml-metal.dylib
   ✅ Signed: libggml.dylib
   ✅ Signed: libwhisper.1.dylib
🔐 [Post-Build] Re-signing app bundle...
✅ [Post-Build] Code signing complete!
```

**Troubleshooting:**
- If the script fails, check that `codesign` is in your PATH
- Verify that the Frameworks directory exists in the app bundle
- Check Xcode build logs for script execution errors

## Related Files

- `../project.yml` - Defines when and how scripts are executed
- `../build.sh` - Convenience wrapper for building and running MacTalk
- `../CLAUDE.md` - Full build documentation

## Notes

These scripts are part of the automated build process and should not need manual execution. They are called automatically by Xcode during the build.
