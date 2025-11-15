# MacTalk Setup & Build Guide

**Version:** 1.0
**Last Updated:** 2025-10-21

---

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Development Environment Setup](#development-environment-setup)
3. [Repository Setup](#repository-setup)
4. [Dependency Installation](#dependency-installation)
5. [Building whisper.cpp](#building-whispercpp)
6. [Xcode Configuration](#xcode-configuration)
7. [Running the App](#running-the-app)
8. [Testing](#testing)
9. [Common Issues](#common-issues)
10. [Development Workflow](#development-workflow)

---

## Prerequisites

### Hardware Requirements
- Mac with Apple Silicon (M1, M2, M3, or M4)
  - Intel Macs may work but are not optimized
- Minimum 8 GB RAM (16 GB recommended for large models)
- 5 GB free disk space (for models and build artifacts)

### Software Requirements
- **macOS:** 14.0 (Sonoma) or later
  - For development, 15.0 (Sequoia) recommended
- **Xcode:** 15.0 or later
  - Command Line Tools installed
- **Git:** 2.30 or later
- **CMake:** 3.20 or later (for whisper.cpp)

---

## Development Environment Setup

### 1. Install Xcode

Download from the Mac App Store or [Apple Developer Downloads](https://developer.apple.com/download/).

```bash
# Verify Xcode installation
xcode-select -p
# Should output: /Applications/Xcode.app/Contents/Developer

# Install Command Line Tools if not already installed
xcode-select --install
```

### 2. Install Homebrew (if not already installed)

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

### 3. Install CMake

```bash
brew install cmake
```

### 4. Verify Environment

```bash
# Check versions
xcodebuild -version         # Should be 15.0+
cmake --version             # Should be 3.20+
git --version               # Should be 2.30+
sw_vers                     # Check macOS version
```

---

## Repository Setup

### 1. Clone the Repository

```bash
git clone https://github.com/yourusername/MacTalk.git
cd MacTalk
```

### 2. Initialize Git Submodules

MacTalk uses whisper.cpp as a submodule:

```bash
git submodule update --init --recursive
```

This will clone whisper.cpp into `Vendor/whisper.cpp`.

### 3. Verify Submodule

```bash
cd Vendor/whisper.cpp
git log -1
# Should show recent whisper.cpp commit
cd ../..
```

---

## Dependency Installation

### whisper.cpp (via git submodule)

Already initialized in previous step. Verify:

```bash
ls Vendor/whisper.cpp
# Should show: CMakeLists.txt, whisper.cpp, whisper.h, etc.
```

### Optional: WebRTC VAD (for advanced VAD)

If implementing VAD in Phase 1:

```bash
cd Vendor
git clone https://github.com/dpirch/libfvad.git
cd libfvad
autoreconf -i
./configure
make
cd ../..
```

Or use a simpler RMS-based VAD initially.

---

## Building whisper.cpp

### 1. Configure Build with Metal Support

```bash
cd Vendor/whisper.cpp

# Create build directory
mkdir -p build
cd build

# Configure with Metal backend
cmake .. \
    -DCMAKE_BUILD_TYPE=Release \
    -DGGML_METAL=ON \
    -DGGML_METAL_NDEBUG=ON \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0

# Build
cmake --build . --config Release -j $(sysctl -n hw.ncpu)
```

### 2. Verify Build

```bash
# Check for libwhisper.a
ls -lh libwhisper.a
# Should show ~5-10 MB static library

# Check for Metal library
ls -lh bin/*.metallib
# Should show ggml-metal.metallib

# Test with sample
./bin/main -m ../models/ggml-tiny.bin -f ../samples/jfk.wav
# (Will fail if model not downloaded, but binary should execute)
```

### 3. Copy Build Artifacts

```bash
cd ../../..  # Back to MacTalk root

# Create libs directory
mkdir -p MacTalk/Libraries

# Copy static library
cp Vendor/whisper.cpp/build/libwhisper.a MacTalk/Libraries/

# Copy Metal library
cp Vendor/whisper.cpp/build/bin/ggml-metal.metallib MacTalk/Resources/

# Copy headers
mkdir -p MacTalk/Include
cp Vendor/whisper.cpp/whisper.h MacTalk/Include/
cp Vendor/whisper.cpp/ggml.h MacTalk/Include/
cp Vendor/whisper.cpp/ggml-metal.h MacTalk/Include/
```

---

## Xcode Configuration

### 1. Create Xcode Project

If not already created:

```bash
# Option A: Create via Xcode GUI
# File > New > Project > macOS > App
# Product Name: MacTalk
# Organization Identifier: com.yourdomain
# Interface: AppKit
# Language: Swift

# Option B: Use command line (for advanced users)
mkdir -p MacTalk/MacTalk.xcodeproj
# (Manual project creation is complex; use Xcode GUI)
```

### 2. Configure Build Settings

Open `MacTalk.xcodeproj` in Xcode:

**General Tab:**
- Minimum Deployments: macOS 14.0
- Supported Destinations: Mac (Apple Silicon, Intel)

**Build Settings:**

1. **Header Search Paths:**
   ```
   $(PROJECT_DIR)/Include
   $(PROJECT_DIR)/Vendor/whisper.cpp
   ```

2. **Library Search Paths:**
   ```
   $(PROJECT_DIR)/Libraries
   ```

3. **Other Linker Flags:**
   ```
   -lwhisper
   -framework Accelerate
   -framework Metal
   -framework Foundation
   ```

4. **Swift Compiler - Code Generation:**
   - Optimization Level (Release): `-O`
   - Optimization Level (Debug): `-Onone`

5. **Apple Clang - Language:**
   - C Language Dialect: `gnu17`
   - C++ Language Dialect: `GNU++17`

### 3. Create Bridging Header

Create `MacTalk/MacTalk-Bridging-Header.h`:

```objc
//
//  MacTalk-Bridging-Header.h
//

#ifndef MacTalk_Bridging_Header_h
#define MacTalk_Bridging_Header_h

// Whisper.cpp C API
#include "whisper.h"
#include "ggml.h"

#endif /* MacTalk_Bridging_Header_h */
```

**Add to Build Settings:**
- Objective-C Bridging Header: `MacTalk/MacTalk-Bridging-Header.h`

### 4. Configure Info.plist

Add required usage descriptions:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>NSMicrophoneUsageDescription</key>
    <string>MacTalk needs microphone access to transcribe your voice.</string>

    <key>NSAppleEventsUsageDescription</key>
    <string>MacTalk needs accessibility permission to auto-paste transcriptions.</string>

    <!-- Note: NSScreenCaptureDescription not needed; runtime prompt via ScreenCaptureKit -->

    <key>LSUIElement</key>
    <true/>  <!-- Menu bar app, no Dock icon -->

    <key>CFBundleIdentifier</key>
    <string>com.yourdomain.MacTalk</string>

    <key>CFBundleVersion</key>
    <string>1</string>

    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
</dict>
</plist>
```

### 5. Add Capabilities

In Xcode:
1. Select MacTalk target
2. Signing & Capabilities tab
3. Add:
   - **Hardened Runtime** (for notarization)
   - Enable: Audio Input, User Selected Files (if saving transcripts)

### 6. Configure Signing

**For Development:**
- Team: Your Apple Developer account
- Signing Certificate: Development

**For Release:**
- Team: Your Apple Developer account
- Signing Certificate: Developer ID Application

---

## Running the App

### 1. Build and Run in Xcode

1. Select "MacTalk" scheme
2. Select "My Mac" as destination
3. Press `Cmd+R` to build and run

**Expected on First Launch:**
- App icon appears in menu bar
- Console log shows initialization messages
- No errors (whisper library may not be loaded yet)

### 2. Verify Whisper Integration

Add test code in `AppDelegate.swift`:

```swift
import Cocoa

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        testWhisperLibrary()
    }

    func testWhisperLibrary() {
        let version = whisper_print_system_info()
        print("Whisper system info:")
        if let versionStr = version {
            print(String(cString: versionStr))
        }
    }
}
```

**Expected Output in Console:**
```
Whisper system info:
system_info: n_threads = 8 / 10 | Metal
```

### 3. Debug Common Issues

**Issue: Linker error "library not found for -lwhisper"**
- Solution: Verify `libwhisper.a` is in `MacTalk/Libraries/`
- Ensure Library Search Paths includes `$(PROJECT_DIR)/Libraries`

**Issue: "Use of unresolved identifier 'whisper_print_system_info'"**
- Solution: Check bridging header path in Build Settings
- Verify `whisper.h` is in `MacTalk/Include/`

**Issue: Metal library not found at runtime**
- Solution: Ensure `ggml-metal.metallib` is in app bundle Resources
- Add to "Copy Bundle Resources" build phase if needed

---

## Testing

### 1. Unit Tests

Create test target in Xcode:
1. File > New > Target > Unit Testing Bundle
2. Name: `MacTalkTests`

Example test:

```swift
import XCTest
@testable import MacTalk

class RingBufferTests: XCTestCase {
    func testWriteAndRead() {
        let buffer = RingBuffer(capacity: 1000)
        let samples: [Float] = [1.0, 2.0, 3.0]

        buffer.write(samples)
        let read = buffer.read(count: 3)

        XCTAssertEqual(read, samples)
    }
}
```

Run tests: `Cmd+U`

### 2. Integration Tests

Test audio pipeline end-to-end:

```swift
func testMicrophoneToWhisper() async throws {
    let capture = MicrophoneCapture()
    let whisper = WhisperEngine()

    try await whisper.loadModel(.tiny)

    var audioSamples: [Float] = []

    try capture.start { buffer in
        audioSamples.append(contentsOf: buffer.floatChannelData![0].withMemoryRebound(to: Float.self, capacity: Int(buffer.frameLength)) {
            Array(UnsafeBufferPointer(start: $0, count: Int(buffer.frameLength)))
        })
    }

    // Record for 3 seconds
    try await Task.sleep(nanoseconds: 3_000_000_000)
    capture.stop()

    // Transcribe
    let transcript = whisper.transcribe(audioSamples)
    XCTAssertFalse(transcript.text.isEmpty)
}
```

### 3. UI Tests

Enable UI testing:
1. File > New > Target > UI Testing Bundle
2. Record interactions with Xcode Test recorder

---

## Common Issues

### Xcode Build Issues

**1. "Command CodeSign failed"**
- **Cause:** Signing certificate not configured
- **Fix:**
  - Xcode > Preferences > Accounts > Add your Apple ID
  - Project Settings > Signing > Select team

**2. "Sandbox: rsync.samba deny(1) file-write-create"**
- **Cause:** Hardened Runtime restrictions
- **Fix:** Disable "Hardened Runtime" during development (re-enable for release)

**3. "Metal validation errors"**
- **Cause:** Metal shader compilation issue
- **Fix:**
  - Ensure `ggml-metal.metallib` is in bundle
  - Check Product > Scheme > Edit Scheme > Run > Diagnostics > Enable Metal API Validation

### Runtime Issues

**1. Microphone permission not requested**
- **Fix:** Ensure `NSMicrophoneUsageDescription` in Info.plist
- Manually trigger: System Settings > Privacy & Security > Microphone

**2. ScreenCaptureKit crashes**
- **Cause:** Missing Screen Recording permission
- **Fix:** System Settings > Privacy & Security > Screen Recording > Add MacTalk

**3. Auto-paste doesn't work**
- **Cause:** Accessibility permission denied
- **Fix:** System Settings > Privacy & Security > Accessibility > Add MacTalk

**4. "Model not found" error**
- **Cause:** Whisper model not downloaded
- **Fix:** Implement model download logic (see ModelManager in ARCHITECTURE.md)

### Performance Issues

**1. High CPU usage during transcription**
- **Check:** Is Metal backend enabled?
  - Console should show: `system_info: ... | Metal`
- **Fix:** Rebuild whisper.cpp with `-DGGML_METAL=ON`

**2. Latency > 1 second**
- **Causes:**
  - Model too large (try smaller: tiny/base)
  - Chunk size too long (reduce to 0.5s)
  - Main thread blocking (move inference to background queue)

---

## Development Workflow

### Daily Development

```bash
# 1. Pull latest changes
git pull origin main

# 2. Update submodules (if whisper.cpp updated)
git submodule update --remote

# 3. Rebuild whisper.cpp if needed
cd Vendor/whisper.cpp/build
cmake --build . --config Release
cp libwhisper.a ../../../MacTalk/Libraries/
cd ../../..

# 4. Open Xcode and develop
open MacTalk.xcodeproj

# 5. Commit changes
git add .
git commit -m "feat: add streaming transcription"
git push
```

### Rebuilding whisper.cpp

Only needed when:
- Whisper.cpp submodule updated
- Changing build flags (e.g., enable/disable Metal)

```bash
cd Vendor/whisper.cpp/build
rm -rf *  # Clean build
cmake .. -DCMAKE_BUILD_TYPE=Release -DGGML_METAL=ON
cmake --build . --config Release -j $(sysctl -n hw.ncpu)
```

### Running Without Xcode

Build release version:

```bash
xcodebuild -project MacTalk.xcodeproj \
    -scheme MacTalk \
    -configuration Release \
    -derivedDataPath build

# Run
open build/Build/Products/Release/MacTalk.app
```

---

## Model Download (for Testing)

Download sample Whisper models:

```bash
mkdir -p ~/Library/Application\ Support/MacTalk/Models

cd ~/Library/Application\ Support/MacTalk/Models

# Tiny model (fastest, least accurate)
curl -L -o ggml-tiny.bin \
    https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin

# Small model (balanced)
curl -L -o ggml-small.bin \
    https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin

# Verify downloads
ls -lh
```

**Note:** Production app should download these on-demand with user consent.

---

## Debugging Tips

### 1. Enable Verbose Logging

Add to `AppDelegate`:

```swift
func applicationDidFinishLaunching(_ aNotification: Notification) {
    #if DEBUG
    setenv("WHISPER_DEBUG", "1", 1)
    setenv("GGML_METAL_DEBUG", "1", 1)
    #endif
}
```

### 2. Instruments Profiling

- **Time Profiler:** Find slow code paths
  - Xcode > Product > Profile (Cmd+I) > Time Profiler
- **Allocations:** Find memory leaks
  - Instruments > Allocations > Record
- **Metal System Trace:** GPU performance
  - Instruments > Metal System Trace

### 3. Console Filtering

In Console.app:

```
# Filter for MacTalk logs
process:MacTalk

# Filter for errors
process:MacTalk AND level:error
```

---

## Next Steps

Once setup is complete:

1. Verify all tests pass: `Cmd+U` in Xcode
2. Read [ARCHITECTURE.md](ARCHITECTURE.md) for design details
3. Review [PROGRESS.md](../planning/PROGRESS.md) for current status

---

## Resources

- **Whisper.cpp GitHub:** https://github.com/ggerganov/whisper.cpp
- **ScreenCaptureKit Docs:** https://developer.apple.com/documentation/screencapturekit
- **AVAudioEngine Guide:** https://developer.apple.com/documentation/avfaudio/avaudioengine
- **Swift Concurrency:** https://docs.swift.org/swift-book/LanguageGuide/Concurrency.html

---

## Getting Help

**Issues during setup?**

1. Check [Common Issues](#common-issues) section above
2. Search existing GitHub Issues: https://github.com/yourusername/MacTalk/issues
3. Create new issue with:
   - macOS version (`sw_vers`)
   - Xcode version (`xcodebuild -version`)
   - Error logs (Console.app or Xcode)
   - Steps to reproduce

---

**Document Version Control:**
- v1.0 (2025-10-21): Initial setup guide
