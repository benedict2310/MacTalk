# MacTalk

> A native macOS app for local voice transcription powered by Whisper

[![macOS](https://img.shields.io/badge/macOS-14.0+-blue.svg)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.9+-orange.svg)](https://swift.org/)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![Status](https://img.shields.io/badge/status-in%20development-yellow.svg)](docs/PROGRESS.md)

MacTalk is a privacy-focused, menu bar app that transcribes your voice in real-time using the Whisper speech recognition model. All processing happens locally on your Mac with Metal-accelerated inference—no cloud, no network calls, no compromises.

---

## Features

### Core Capabilities
- **Real-time Transcription:** Streaming inference with partial results appearing as you speak
- **Dual Capture Modes:**
  - **Mode A:** Microphone-only dictation
  - **Mode B:** Mic + App/System audio (perfect for transcribing calls or meetings)
- **Clipboard & Auto-Paste:** Instantly copy transcripts to clipboard, optionally paste at cursor
- **Multiple Model Sizes:** Choose from tiny (fast) to large-v3-turbo (accurate)
- **Privacy First:** 100% on-device processing, zero network requests during transcription
- **Metal Acceleration:** Optimized for Apple Silicon (M1/M2/M3/M4)

### User Experience
- **Menu Bar Integration:** Lightweight, always accessible, no Dock clutter
- **HUD Overlay:** Live transcript preview with audio level meters and stop button
- **Easy Controls:** Stop recording directly from HUD - no need to go back to menu bar
- **Global Hotkeys:** Start/stop transcription without switching apps
- **Automatic Model Downloads:** One-click model selection with progress tracking
- **Customizable Settings:** Model selection, language, auto-punctuation, and more

---

## Screenshots

### Menu Bar Interface
![MacTalk Menu](docs/screenshots/menu.png)

*Menu bar dropdown with recording modes, settings, and quick controls. Keyboard shortcuts for all major actions.*

### Recording in Action
![Recording HUD](docs/screenshots/recording.png)

*Live HUD overlay during transcription showing real-time waveform visualization and audio levels.*

---

## Requirements

- **macOS:** 14.0 (Sonoma) or later
- **Hardware:** Apple Silicon (M1 or newer) recommended
  - Intel Macs may work but are not optimized
- **RAM:** 8 GB minimum, 16 GB recommended for large models
- **Disk Space:** 5 GB (for models and build artifacts)

---

## Installation

### Option 1: Download Release

1. Download the latest `MacTalk-v1.0.0.zip` from [Releases](https://github.com/benedict2310/MacTalk/releases)
2. Unzip the archive and move `MacTalk.app` to your Applications folder
3. Right-click MacTalk.app and select "Open" (first launch only, due to unsigned app)
4. Grant required permissions when prompted (Microphone, Screen Recording, Accessibility)
5. Choose a Whisper model to download (recommended: small or medium)

### Option 2: Build from Source

See [SETUP.md](docs/SETUP.md) for detailed build instructions.

**Quick Start:**

```bash
# Clone repository
git clone https://github.com/yourusername/MacTalk.git
cd MacTalk

# Initialize submodules (whisper.cpp)
git submodule update --init --recursive

# Build whisper.cpp with Metal support
cd Vendor/whisper.cpp
mkdir build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release -DGGML_METAL=ON
cmake --build . --config Release
cd ../../..

# Open Xcode project
open MacTalk.xcodeproj
```

---

## Usage

### Quick Start

1. **Launch MacTalk:** Icon appears in menu bar
2. **Download a Model:** Select a model from the Model submenu (auto-downloads if needed)
3. **Start Recording:** Click menu bar icon → "Start (Mic Only)"
4. **Speak:** Your words appear in the HUD overlay with live audio levels
5. **Stop:** Click the "Stop Recording" button in the HUD or use menu bar
6. **Result:** Transcript copied to clipboard (and auto-pasted if enabled)

### Mode A: Dictation (Mic-Only)

Perfect for writing emails, documents, or notes:

1. Click menu bar icon → Select "Mic Only" mode
2. Press hotkey to start
3. Speak naturally
4. Press hotkey to stop
5. Paste transcript (Cmd-V) into any app

### Mode B: Call/Meeting Transcription

Transcribe both your mic and app audio (e.g., Zoom, FaceTime):

1. Click menu bar icon → Select "Mic + App Audio" mode
2. Choose app from picker (requires Screen Recording permission)
3. Press hotkey to start
4. Your voice + remote speaker transcribed together
5. Press hotkey to stop
6. Review and copy transcript

---

## Documentation

- **[PRD.md](docs/planning/PRD.md)** - Product Requirements Document
- **[ARCHITECTURE.md](docs/development/ARCHITECTURE.md)** - Technical design and architecture
- **[SETUP.md](docs/development/SETUP.md)** - Build and development setup guide
- **[TESTING.md](docs/testing/TESTING.md)** - Testing guide and procedures
- **[TEST_COVERAGE.md](docs/testing/TEST_COVERAGE.md)** - Test coverage report

---

## How It Works

```
┌─────────────────────────────────────────────────────────────┐
│                     User Speaks / Audio Plays               │
└──────────────────────┬──────────────────────────────────────┘
                       │
┌──────────────────────▼──────────────────────────────────────┐
│              Audio Capture Layer                            │
│  • AVAudioEngine (Mic)                                      │
│  • ScreenCaptureKit (App/System Audio)                      │
└──────────────────────┬──────────────────────────────────────┘
                       │
┌──────────────────────▼──────────────────────────────────────┐
│           Audio Processing Pipeline                         │
│  • Mix & Resample to 16kHz Mono                             │
│  • Ring Buffer (lock-free)                                  │
│  • Optional VAD (Voice Activity Detection)                  │
└──────────────────────┬──────────────────────────────────────┘
                       │
┌──────────────────────▼──────────────────────────────────────┐
│              Whisper.cpp Inference                          │
│  • Metal-accelerated GPU processing                         │
│  • Streaming chunks (0.5-1.0s windows)                      │
│  • Emit partial transcripts                                 │
└──────────────────────┬──────────────────────────────────────┘
                       │
┌──────────────────────▼──────────────────────────────────────┐
│             Post-Processing                                 │
│  • Punctuation insertion                                    │
│  • Capitalization                                           │
│  • Timestamp alignment                                      │
└──────────────────────┬──────────────────────────────────────┘
                       │
┌──────────────────────▼──────────────────────────────────────┐
│                Output Layer                                 │
│  • Copy to Clipboard                                        │
│  • Auto-Paste (via Accessibility APIs)                      │
│  • HUD Display                                              │
└─────────────────────────────────────────────────────────────┘
```

---

## Technology Stack

- **Language:** Swift 5.9+
- **UI Framework:** AppKit (macOS native)
- **Audio:** AVFoundation (AVAudioEngine, AVAudioMixerNode)
- **App Audio Capture:** ScreenCaptureKit (macOS 12.3+)
- **Inference Engine:** [whisper.cpp](https://github.com/ggerganov/whisper.cpp) (Metal backend)
- **Model Format:** GGML/GGUF (quantized: Q5_0, Q8_0)
- **Permissions:** Microphone, Screen Recording, Accessibility
- **Minimum Target:** macOS 14.0 (Sonoma)

---

## Model Sizes

MacTalk supports multiple Whisper model sizes, allowing you to balance speed vs. accuracy:

| Model | Size (Q5_0/Q5_1) | Speed (M4) | Accuracy | Use Case |
|-------|------------------|------------|----------|----------|
| **tiny** | ~32 MB | Fastest | Good | Quick dictation, constrained systems |
| **base** | ~60 MB | Very Fast | Better | Everyday use, balanced |
| **small** | ~190 MB | Fast | Great | Recommended default |
| **medium** | ~539 MB | Moderate | Excellent | High accuracy needs |
| **large-v3-turbo** | ~574 MB | Slower | Best | Maximum accuracy |

### Automatic Downloads

**NEW:** MacTalk now features intelligent automatic model downloads:

**User Experience:**
- **User Confirmation:** Dialog appears before downloading, showing model name and file size
- **One-Click Download:** Simple "Download" button starts the process
- **Resume Support:** Downloads automatically resume if interrupted (network issue, app quit, etc.)
- **Progress Tracking:** Real-time download progress shown in menu bar with percentage
- **Prevention:** Only one download at a time - no confusing concurrent downloads
- **Verification:** File size validation ensures downloads completed correctly

**Technical Features:**
- **Mirror Fallback:** Automatically tries alternate mirrors if primary source fails
- **Smart Storage:** Models stored in `~/Library/Application Support/MacTalk/Models/`
- **Integrity Checks:** 10% file size tolerance to catch corrupted downloads
- **Optional SHA-256:** When checksums are available, full cryptographic verification

**How to Use:**
1. Select a model from the menu bar → Model submenu
2. If not downloaded, a dialog appears with model details
3. Click "Download" to start, "Use Different Model" to choose another, or "Cancel"
4. Watch progress in menu bar as the model downloads
5. Model is automatically verified and ready to use when complete

No manual downloads or terminal commands required!

---

## Permissions

MacTalk requires the following permissions:

- **Microphone:** To capture your voice
- **Screen Recording:** To capture app/system audio (Mode B only)
- **Accessibility:** To auto-paste transcripts (optional)

All permissions are requested only when needed and can be managed in System Settings.

---

## Performance

**Target Metrics (M4, small model Q5_0):**
- Streaming latency: < 500ms (first partial transcript)
- End-to-end finalization: < 2s for 10-second utterance
- GPU utilization: < 60% during streaming
- Memory footprint: < 1 GB (with small model loaded)

**Tested Configurations:**
- macOS 14.5+ on M4 MacBook Pro (optimized)
- macOS 14.5+ on M1 MacBook Air (supported)

See [ARCHITECTURE.md](docs/ARCHITECTURE.md) for performance optimization strategies.

---

## Privacy & Security

- **Zero Network Calls:** All transcription happens locally on your Mac
- **No Telemetry:** No analytics, crash reporting, or usage tracking
- **Local Storage:** Models and settings stored only on your device
- **Open Source:** Review the code, build it yourself (coming soon)
- **Sandboxed:** Runs in macOS App Sandbox (if distributed via Mac App Store)

**Legal Note:** When using Mode B (app audio capture), ensure compliance with local recording laws. MacTalk displays a one-time consent reminder for two-party consent jurisdictions.

---

## Contributing

Contributions are welcome! Areas for contribution include:

- Testing and bug reports (especially on M1/M2/M3 Macs)
- UI/UX design and feedback
- Performance optimization
- Additional language support
- Documentation improvements

---

## FAQ

### Q: Does MacTalk work offline?
**A:** Yes. Once models are downloaded, no network connection is required for transcription.

### Q: Which model should I use?
**A:** Start with `small` for balanced speed and accuracy. Use `tiny` or `base` for faster performance, or `medium`/`large-v3-turbo` for maximum accuracy.

### Q: Can I transcribe calls from Zoom/Teams/FaceTime?
**A:** Yes, using Mode B (Mic + App Audio). Requires Screen Recording permission.

### Q: Does it work with languages other than English?
**A:** Yes, Whisper supports 99+ languages. The app defaults to English for best accuracy.

### Q: How is this different from macOS Dictation?
**A:**
- MacTalk works completely offline (Apple Dictation requires network for best quality)
- Supports app audio capture for transcribing calls
- Choice of multiple models (speed vs. accuracy tradeoff)
- Privacy-focused with no telemetry or network calls

---

## License

MacTalk is released under the **MIT License**. See [LICENSE](LICENSE) for details.

### Third-Party Licenses

- **whisper.cpp:** MIT License ([link](https://github.com/ggerganov/whisper.cpp/blob/master/LICENSE))
- **Whisper Models:** MIT License ([OpenAI Whisper](https://github.com/openai/whisper/blob/main/LICENSE))

---

## Acknowledgments

- [OpenAI Whisper](https://github.com/openai/whisper) for the foundational speech recognition model
- [whisper.cpp](https://github.com/ggerganov/whisper.cpp) by Georgi Gerganov for the excellent C/C++ implementation
- The open-source community for tools and inspiration

---

## Support

- **Issues:** [GitHub Issues](https://github.com/benedict2310/MacTalk/issues)
- **Discussions:** [GitHub Discussions](https://github.com/benedict2310/MacTalk/discussions)

---

**Built with privacy, powered by Metal, made for macOS.**
