# Xcode Project Setup & Build Instructions

**MacTalk - Whisper.cpp Integration Guide**

This document provides step-by-step instructions for setting up the Xcode project and integrating whisper.cpp with Metal acceleration.

---

## Prerequisites

- macOS 14.0 (Sonoma) or later
- Xcode 15.0 or later
- CMake 3.20+ (for whisper.cpp build)
- Apple Silicon Mac (M1/M2/M3/M4) recommended

---

## Step 1: Add whisper.cpp as Submodule

```bash
cd /path/to/MacTalk

# Add whisper.cpp as git submodule
git submodule add https://github.com/ggerganov/whisper.cpp third_party/whisper.cpp

# Initialize and update submodule
git submodule update --init --recursive
```

---

## Step 2: Create Xcode Project

### Option A: Use Xcode GUI

1. Open Xcode
2. File > New > Project
3. Select: macOS > App
4. Configure:
   - Product Name: **MacTalk**
   - Organization Identifier: **com.mactalk**
   - Interface: **AppKit**
   - Language: **Swift**
   - ☑️ Use Core Data: **No**
   - ☑️ Include Tests: **Yes**
5. Save to `/path/to/MacTalk/MacTalk/`

### Option B: Use Existing Project Structure

The skeleton already contains the source files in:
```
MacTalk/MacTalk/
├── AppDelegate.swift
├── StatusBarController.swift
├── ... (all other Swift files)
```

Simply create a new Xcode project in the `MacTalk/` directory and add these files.

---

## Step 3: Add Source Files to Xcode

### Add Swift Files

In Xcode:
1. Right-click on MacTalk group
2. Add Files to "MacTalk"...
3. Select all `.swift` files from `MacTalk/MacTalk/` and `MacTalk/MacTalk/Audio/`, `MacTalk/MacTalk/Whisper/`
4. Ensure "Copy items if needed" is **unchecked** (files are already in place)
5. Target: **MacTalk** (checked)

### Add whisper.cpp Sources

Add the following files from `third_party/whisper.cpp/`:

**Core Files:**
```
third_party/whisper.cpp/whisper.cpp
third_party/whisper.cpp/whisper.h
third_party/whisper.cpp/ggml/src/ggml.c
third_party/whisper.cpp/ggml/src/ggml-alloc.c
third_party/whisper.cpp/ggml/src/ggml-backend.c
third_party/whisper.cpp/ggml/src/ggml-quants.c
third_party/whisper.cpp/ggml/src/ggml-common.c
third_party/whisper.cpp/ggml/src/ggml-metal.m
```

**Optional (for better CPU fallback):**
```
third_party/whisper.cpp/ggml/src/ggml-blas.c
```

**How to add:**
1. In Xcode, right-click MacTalk group
2. Add Files to "MacTalk"...
3. Navigate to `third_party/whisper.cpp/`
4. Select files listed above
5. **Important:** Uncheck "Copy items if needed"
6. Ensure target is checked: **MacTalk**

---

## Step 4: Configure Build Settings

### 4.1 General Settings

Select **MacTalk** target > **General**:

- Deployment Target: **macOS 14.0**
- Supported Destinations: **Mac (Apple Silicon, Intel)**

### 4.2 Build Settings

Select **MacTalk** target > **Build Settings** > **All** > **Combined**

#### Compiler Flags

**Other C Flags:**
```
-DGGML_USE_METAL=1 -DGGML_USE_ACCELERATE=1
```

**Other C++ Flags:**
```
-std=c++17 -DGGML_USE_METAL=1 -DGGML_USE_ACCELERATE=1
```

**Apple Clang - Language:**
- C Language Dialect: `GNU17`
- C++ Language Dialect: `GNU++17`

#### Header Search Paths

Add these paths (recursive if needed):
```
$(SRCROOT)/third_party/whisper.cpp
$(SRCROOT)/third_party/whisper.cpp/ggml/include
$(SRCROOT)/third_party/whisper.cpp/common
$(PROJECT_DIR)/MacTalk/Whisper
```

#### Library Search Paths

```
$(PROJECT_DIR)/MacTalk/Libraries
```

(Leave empty for now; libraries will be statically linked)

### 4.3 Linking

**Link Binary With Libraries:**

Add these frameworks:
- `Accelerate.framework`
- `Metal.framework`
- `MetalKit.framework`
- `AppKit.framework`
- `AVFoundation.framework`
- `CoreMedia.framework`
- `CoreAudio.framework`
- `AudioToolbox.framework`
- `QuartzCore.framework`
- `ScreenCaptureKit.framework` (macOS 12.3+)
- `Carbon.framework` (for hotkeys)

**How to add:**
1. Select MacTalk target
2. Build Phases > Link Binary With Libraries
3. Click **+**
4. Search for framework name
5. Add

### 4.4 Compile Sources As

For `ggml-metal.m` and `WhisperBridge.mm`:

1. Select MacTalk target
2. Build Phases > Compile Sources
3. Find `ggml-metal.m`
4. Double-click on "Compiler Flags" column
5. Add: `-x objective-c++`
6. Repeat for `WhisperBridge.mm`

Alternatively, set globally:
- Build Settings > Compile Sources As: **Objective-C++**

### 4.5 Bridging Header

**Swift Compiler - General:**

- Objective-C Bridging Header:
  ```
  MacTalk/Whisper/WhisperBridge.h
  ```

**Important:** Path is relative to project root.

### 4.6 Optimization

**Debug Configuration:**
- Optimization Level: `-Onone` (for debugging)
- Swift Optimization Level: `-Onone`

**Release Configuration:**
- Optimization Level: `-O3`
- Swift Optimization Level: `-O`
- Strip Debug Symbols: **Yes**
- Make Strings Read-Only: **Yes**

---

## Step 5: Configure Info.plist

The `Info.plist` file is already created at `MacTalk/MacTalk/Info.plist`.

Ensure it's set in:
- Target > Build Settings > Packaging > Info.plist File:
  ```
  MacTalk/Info.plist
  ```

---

## Step 6: Configure Signing & Capabilities

### Signing

1. Select MacTalk target
2. Signing & Capabilities tab
3. Check: **Automatically manage signing**
4. Select your **Team** (Apple Developer account)

### Capabilities

Add the following capabilities:

**App Sandbox (if targeting Mac App Store):**
- ☑️ Audio Input
- ☑️ User Selected Files (Read/Write)

**Hardened Runtime (for notarization):**
- Enable Hardened Runtime
- Check exceptions needed:
  - ☑️ Disable Library Validation (for whisper.cpp dynamic loading)

**Resource Access:**
- Add entitlements in `MacTalk.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.audio-input</key>
    <true/>
    <key>com.apple.security.automation.apple-events</key>
    <true/>
</dict>
</plist>
```

---

## Step 7: Add Metal Shader Library (ggml-metal.metal)

whisper.cpp includes Metal shaders for GPU acceleration.

### Option A: Automatic (Recommended)

Add to project:
```
third_party/whisper.cpp/ggml/src/ggml-metal.metal
```

1. In Xcode, add this file to project
2. Ensure target membership: **MacTalk**
3. Build Phase > Compile Sources should list it
4. Xcode will automatically compile to `.metallib`

### Option B: Pre-compiled

If you encounter issues, pre-compile:

```bash
cd third_party/whisper.cpp/ggml/src

xcrun -sdk macosx metal -c ggml-metal.metal -o ggml-metal.air
xcrun -sdk macosx metallib ggml-metal.air -o ggml-metal.metallib
```

Then add `ggml-metal.metallib` to:
- MacTalk/Resources/
- Ensure it's copied to app bundle (Build Phases > Copy Bundle Resources)

---

## Step 8: Build the Project

### First Build

1. Select scheme: **MacTalk**
2. Destination: **My Mac**
3. Product > Clean Build Folder (Cmd+Shift+K)
4. Product > Build (Cmd+B)

### Expected Output

If successful:
```
Build succeeded
```

Check for warnings about:
- Missing symbols (usually resolved by adding frameworks)
- Header not found (check Header Search Paths)

---

## Step 9: Download Whisper Models

Before running, download at least one model:

```bash
# Create models directory
mkdir -p ~/Library/Application\ Support/MacTalk/Models

# Download small model (recommended for testing)
cd ~/Library/Application\ Support/MacTalk/Models

curl -L -o ggml-small-q5_0.gguf \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small-q5_0.gguf
```

**Other models:**

```bash
# Tiny (fastest, ~75 MB)
curl -L -o ggml-tiny-q5_0.gguf \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny-q5_0.gguf

# Base (~140 MB)
curl -L -o ggml-base-q5_0.gguf \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base-q5_0.gguf

# Large-v3-turbo (highest quality, ~2.8 GB)
curl -L -o ggml-large-v3-turbo-q5_0.gguf \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.gguf
```

---

## Step 10: Run the App

1. Product > Run (Cmd+R)
2. Grant microphone permission when prompted
3. Menu bar icon (🎙️) should appear
4. Click icon to access menu
5. Select model in Settings
6. Start transcription!

---

## Troubleshooting

### Build Errors

**Error: "Library not found for -lwhisper"**
- **Cause:** Whisper sources not added to target
- **Fix:** Ensure all whisper.cpp files are in Compile Sources (Build Phases)

**Error: "Use of unresolved identifier 'wt_whisper_init'"**
- **Cause:** Bridging header not configured
- **Fix:** Set Objective-C Bridging Header path in Build Settings

**Error: "'whisper.h' file not found"**
- **Cause:** Header search paths not set
- **Fix:** Add header search paths (see Step 4.2)

**Error: "ld: symbol(s) not found for architecture arm64"**
- **Cause:** Missing framework or source file
- **Fix:** Check Link Binary With Libraries and Compile Sources phases

**Error: "Metal validation failed"**
- **Cause:** Metal shader not compiled
- **Fix:** Add `ggml-metal.metal` to project and ensure it compiles

### Runtime Errors

**App crashes on launch:**
- Check Console.app for crash logs
- Verify all frameworks are linked
- Ensure Info.plist is valid

**"Model file not found":**
- Download models to `~/Library/Application Support/MacTalk/Models/`
- Check ModelManager code points to correct path

**No audio capture:**
- Grant microphone permission in System Settings
- Check Console for AVAudioEngine errors

**Auto-paste doesn't work:**
- Grant Accessibility permission in System Settings
- Run `Permissions.ensureAccessibilityPrompt()`

---

## Performance Optimization

### Metal Backend Verification

In Console.app, filter for "WhisperBridge" and look for:
```
[WhisperBridge] Whisper context initialized successfully
```

Check Whisper system info includes "Metal" in output.

### GPU Utilization

Monitor with Activity Monitor > GPU tab during transcription.

Expected: 40-60% GPU usage with small/medium models on M4.

### Memory Usage

Expected:
- tiny: ~200 MB
- small: ~600 MB
- medium: ~1.5 GB
- large-v3-turbo: ~3 GB

Use Instruments > Allocations to profile.

---

## Next Steps

Once the app builds and runs:

1. Test microphone-only transcription
2. Test app audio capture (Mode B)
3. Verify auto-paste works
4. Profile performance with Instruments

---

## Reference: Complete File Structure

```
MacTalk/
├── MacTalk.xcodeproj
├── MacTalk/
│   ├── AppDelegate.swift
│   ├── StatusBarController.swift
│   ├── HUDWindowController.swift
│   ├── TranscriptionController.swift
│   ├── Permissions.swift
│   ├── ClipboardManager.swift
│   ├── HotkeyManager.swift
│   ├── Audio/
│   │   ├── AudioCapture.swift
│   │   ├── ScreenAudioCapture.swift
│   │   ├── AudioMixer.swift
│   │   └── RingBuffer.swift
│   ├── Whisper/
│   │   ├── WhisperEngine.swift
│   │   ├── ModelManager.swift
│   │   ├── WhisperBridge.h
│   │   └── WhisperBridge.mm
│   ├── Info.plist
│   └── MacTalk.entitlements
├── third_party/
│   └── whisper.cpp/  (git submodule)
└── docs/
    └── XCODE_BUILD.md (this file)
```

---

## Additional Resources

- [SETUP.md](SETUP.md) - General development setup
- [ARCHITECTURE.md](ARCHITECTURE.md) - Technical architecture
- [whisper.cpp GitHub](https://github.com/ggerganov/whisper.cpp)
- [Xcode Build Settings Reference](https://developer.apple.com/documentation/xcode/build-settings-reference)

---

**Last Updated:** 2025-10-21
