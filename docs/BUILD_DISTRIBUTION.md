# MacTalk Build & Distribution Guide

**Version:** 1.0
**Last Updated:** 2025-10-22
**Target:** Phase 5 - Release Preparation

---

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Development Build](#development-build)
3. [Release Build](#release-build)
4. [Code Signing](#code-signing)
5. [Notarization](#notarization)
6. [Distribution](#distribution)
7. [Troubleshooting](#troubleshooting)

---

## Prerequisites

### Development Environment

- **macOS:** 14.0 (Sonoma) or later
- **Xcode:** 15.0 or later
- **Command Line Tools:** Installed via `xcode-select --install`
- **Apple Developer Account:** Required for distribution

### Repository Setup

```bash
# Clone repository
git clone https://github.com/yourusername/MacTalk.git
cd MacTalk

# Initialize submodules (whisper.cpp)
git submodule update --init --recursive
```

### Build whisper.cpp

```bash
# Navigate to whisper.cpp
cd third_party/whisper.cpp

# Create build directory
mkdir build && cd build

# Configure with Metal support
cmake .. \
  -DCMAKE_BUILD_TYPE=Release \
  -DGGML_METAL=ON \
  -DGGML_USE_ACCELERATE=1 \
  -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64"

# Build
cmake --build . --config Release

# Verify libwhisper.a was created
ls -la libwhisper.a
```

---

## Development Build

### Using Xcode GUI

1. **Open Project**
   ```bash
   open MacTalk/MacTalk.xcodeproj
   ```

2. **Select Scheme**
   - Product → Scheme → MacTalk

3. **Select Destination**
   - Product → Destination → My Mac

4. **Build**
   - Product → Build (Cmd+B)

5. **Run**
   - Product → Run (Cmd+R)

### Using Command Line

```bash
# Build for development (Debug)
xcodebuild build \
  -project MacTalk/MacTalk.xcodeproj \
  -scheme MacTalk \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build

# Run tests
xcodebuild test \
  -project MacTalk/MacTalk.xcodeproj \
  -scheme MacTalk \
  -destination 'platform=macOS,arch=arm64' \
  -enableCodeCoverage YES

# Built app location
ls -la build/Build/Products/Debug/MacTalk.app
```

---

## Release Build

### Clean Build

```bash
# Clean derived data
rm -rf ~/Library/Developer/Xcode/DerivedData/MacTalk-*

# Clean in Xcode
# Product → Clean Build Folder (Cmd+Shift+K)
```

### Build for Release

```bash
# Build Release configuration
xcodebuild build \
  -project MacTalk/MacTalk.xcodeproj \
  -scheme MacTalk \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build \
  MARKETING_VERSION=1.0.0 \
  CURRENT_PROJECT_VERSION=1

# Universal binary (Intel + Apple Silicon)
xcodebuild build \
  -project MacTalk/MacTalk.xcodeproj \
  -scheme MacTalk \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath build \
  ARCHS="arm64 x86_64"

# Built app location
open build/Build/Products/Release
```

### Verify Build

```bash
# Check architectures
lipo -info build/Build/Products/Release/MacTalk.app/Contents/MacOS/MacTalk
# Expected: Architectures in the fat file: MacTalk are: arm64 x86_64

# Check code signing
codesign --verify --verbose build/Build/Products/Release/MacTalk.app

# Check entitlements
codesign -d --entitlements - build/Build/Products/Release/MacTalk.app
```

---

## Code Signing

### Development Signing

```bash
# Sign with development certificate
codesign --force --deep --sign "Apple Development: Your Name (TEAM_ID)" \
  build/Build/Products/Release/MacTalk.app

# Verify
codesign --verify --verbose build/Build/Products/Release/MacTalk.app
```

### Distribution Signing

```bash
# Sign with distribution certificate
codesign --force --deep \
  --sign "Developer ID Application: Your Name (TEAM_ID)" \
  --options runtime \
  --entitlements MacTalk/MacTalk.entitlements \
  build/Build/Products/Release/MacTalk.app

# Verify hardened runtime
codesign --display --verbose build/Build/Products/Release/MacTalk.app
```

### Required Entitlements

Create `MacTalk.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- Audio Recording -->
    <key>com.apple.security.device.audio-input</key>
    <true/>

    <!-- Accessibility (for auto-paste) -->
    <key>com.apple.security.automation.apple-events</key>
    <true/>

    <!-- Hardened Runtime -->
    <key>com.apple.security.cs.allow-jit</key>
    <true/>
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
    <true/>
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
</dict>
</plist>
```

---

## Notarization

### Prerequisites

1. **App-Specific Password**
   - Generate at: https://appleid.apple.com/account/manage
   - Store in Keychain:
     ```bash
     xcrun notarytool store-credentials "MacTalk-Notary" \
       --apple-id "your-email@example.com" \
       --team-id "YOUR_TEAM_ID" \
       --password "app-specific-password"
     ```

### Create DMG

```bash
# Install create-dmg
brew install create-dmg

# Create DMG
create-dmg \
  --volname "MacTalk" \
  --volicon "MacTalk/Assets.xcassets/AppIcon.appiconset/icon_512x512.png" \
  --window-pos 200 120 \
  --window-size 800 400 \
  --icon-size 100 \
  --icon "MacTalk.app" 200 190 \
  --hide-extension "MacTalk.app" \
  --app-drop-link 600 185 \
  "MacTalk-1.0.0.dmg" \
  "build/Build/Products/Release/MacTalk.app"
```

### Sign DMG

```bash
codesign --force --sign "Developer ID Application: Your Name (TEAM_ID)" \
  MacTalk-1.0.0.dmg
```

### Submit for Notarization

```bash
# Submit
xcrun notarytool submit MacTalk-1.0.0.dmg \
  --keychain-profile "MacTalk-Notary" \
  --wait

# Check status
xcrun notarytool log "submission-id" \
  --keychain-profile "MacTalk-Notary"
```

### Staple Notarization

```bash
# Staple ticket to DMG
xcrun stapler staple MacTalk-1.0.0.dmg

# Verify
xcrun stapler validate MacTalk-1.0.0.dmg
spctl -a -vvv -t install MacTalk-1.0.0.dmg
```

---

## Distribution

### Direct Download

1. **Upload to GitHub Releases**
   ```bash
   # Create release
   gh release create v1.0.0 \
     MacTalk-1.0.0.dmg \
     --title "MacTalk v1.0.0" \
     --notes "Initial release"
   ```

2. **Update Download Links**
   - Update README.md with download link
   - Update website/landing page

### Mac App Store (Optional)

1. **Archive for App Store**
   ```bash
   xcodebuild archive \
     -project MacTalk/MacTalk.xcodeproj \
     -scheme MacTalk \
     -configuration Release \
     -archivePath MacTalk.xcarchive
   ```

2. **Export for App Store**
   ```bash
   xcodebuild -exportArchive \
     -archivePath MacTalk.xcarchive \
     -exportPath MacTalk-AppStore \
     -exportOptionsPlist ExportOptions.plist
   ```

3. **Upload to App Store Connect**
   ```bash
   xcrun altool --upload-app \
     --type macos \
     --file MacTalk-AppStore/MacTalk.pkg \
     --username "your-email@example.com" \
     --password "app-specific-password"
   ```

---

## Troubleshooting

### Common Issues

#### Issue: "Code signature invalid"

**Solution:**
```bash
# Re-sign with correct certificate
codesign --force --deep \
  --sign "Developer ID Application: Your Name (TEAM_ID)" \
  MacTalk.app
```

#### Issue: "Notarization failed"

**Check logs:**
```bash
xcrun notarytool log "submission-id" --keychain-profile "MacTalk-Notary"
```

**Common causes:**
- Unsigned nested frameworks
- Missing entitlements
- Invalid bundle ID
- Hardened runtime issues

**Solution:** Fix issues and resubmit

#### Issue: "Gatekeeper blocks app"

**Cause:** Not notarized or notarization ticket not stapled

**Solution:**
```bash
# Staple ticket
xcrun stapler staple MacTalk.app

# Verify
spctl -a -vvv MacTalk.app
```

#### Issue: "Whisper.cpp library not found"

**Cause:** libwhisper.a not linked correctly

**Solution:**
1. Verify libwhisper.a exists in `third_party/whisper.cpp/build/`
2. Check Xcode build settings: Library Search Paths
3. Rebuild whisper.cpp if needed

#### Issue: "Metal shaders not found"

**Cause:** ggml-metal.metal not included in bundle

**Solution:**
1. Add `ggml-metal.metal` to Xcode project
2. Ensure it's in "Copy Bundle Resources" build phase

### Verification Checklist

Before releasing:

- [ ] App builds without errors
- [ ] All tests pass (Cmd+U)
- [ ] Code coverage > 85%
- [ ] Code signed correctly
- [ ] Notarized successfully
- [ ] Stapled notarization ticket
- [ ] Gatekeeper accepts app
- [ ] Tested on clean macOS install
- [ ] All models downloadable
- [ ] Permissions requested correctly
- [ ] No crashes in typical usage
- [ ] Documentation up to date
- [ ] Version number updated

---

## Automated Build Script

Create `scripts/build-release.sh`:

```bash
#!/bin/bash
set -e

VERSION=$1
if [ -z "$VERSION" ]; then
  echo "Usage: ./build-release.sh <version>"
  exit 1
fi

echo "Building MacTalk v$VERSION..."

# Clean
rm -rf build
rm -f MacTalk-*.dmg

# Build
xcodebuild build \
  -project MacTalk/MacTalk.xcodeproj \
  -scheme MacTalk \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath build \
  MARKETING_VERSION=$VERSION \
  ARCHS="arm64 x86_64"

# Sign
codesign --force --deep \
  --sign "Developer ID Application" \
  --options runtime \
  build/Build/Products/Release/MacTalk.app

# Create DMG
create-dmg \
  --volname "MacTalk" \
  --window-size 800 400 \
  --icon-size 100 \
  --icon "MacTalk.app" 200 190 \
  --app-drop-link 600 185 \
  "MacTalk-$VERSION.dmg" \
  "build/Build/Products/Release/MacTalk.app"

# Sign DMG
codesign --force --sign "Developer ID Application" \
  "MacTalk-$VERSION.dmg"

# Notarize
xcrun notarytool submit "MacTalk-$VERSION.dmg" \
  --keychain-profile "MacTalk-Notary" \
  --wait

# Staple
xcrun stapler staple "MacTalk-$VERSION.dmg"

echo "✅ Build complete: MacTalk-$VERSION.dmg"
```

Usage:
```bash
chmod +x scripts/build-release.sh
./scripts/build-release.sh 1.0.0
```

---

## Release Checklist

1. **Pre-Release**
   - [ ] Update version number in Xcode
   - [ ] Update CHANGELOG.md
   - [ ] Run all tests
   - [ ] Update documentation
   - [ ] Tag release in git

2. **Build**
   - [ ] Clean build
   - [ ] Build Release configuration
   - [ ] Run release build script
   - [ ] Verify architectures (universal binary)

3. **Sign & Notarize**
   - [ ] Sign with distribution certificate
   - [ ] Create DMG
   - [ ] Sign DMG
   - [ ] Submit for notarization
   - [ ] Staple notarization ticket

4. **Test**
   - [ ] Test on macOS 14 (Sonoma)
   - [ ] Test on macOS 15 (Sequoia)
   - [ ] Test on M1 Mac
   - [ ] Test on M4 Mac
   - [ ] Verify all features work
   - [ ] Check permissions flow

5. **Distribute**
   - [ ] Upload to GitHub Releases
   - [ ] Update download links
   - [ ] Announce release
   - [ ] Monitor for issues

---

## Additional Resources

- [Apple Code Signing Guide](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/)
- [Notarization Guide](https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution)
- [Xcode Build Settings Reference](https://help.apple.com/xcode/mac/current/#/itcaec37c2a6)
- [create-dmg Documentation](https://github.com/sindresorhus/create-dmg)

---

**Document Version:** 1.0
**Last Updated:** 2025-10-22
**Next Review:** Before v1.0 release
