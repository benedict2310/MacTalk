# MacTalk Architecture Documentation

**Version:** 1.0
**Last Updated:** 2025-10-21

---

## Table of Contents

1. [Overview](#overview)
2. [System Architecture](#system-architecture)
3. [Component Design](#component-design)
4. [Data Flow](#data-flow)
5. [Threading Model](#threading-model)
6. [Audio Pipeline](#audio-pipeline)
7. [Whisper Integration](#whisper-integration)
8. [UI Components](#ui-components)
9. [Security & Permissions](#security--permissions)
10. [Performance Considerations](#performance-considerations)

---

## Overview

MacTalk is a native macOS application built with Swift and AppKit that provides real-time, on-device voice transcription using the Whisper speech recognition model. The app supports two capture modes:

1. **Microphone-only transcription**
2. **Combined microphone + system/app audio transcription**

All processing occurs locally on the device using Metal-accelerated inference for optimal performance on Apple Silicon.

---

## System Architecture

### High-Level Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                         User Interface Layer                     │
│  ┌────────────────┐  ┌─────────────────┐  ┌─────────────────┐  │
│  │  Menu Bar App  │  │  Settings Panel │  │   HUD Overlay   │  │
│  └────────────────┘  └─────────────────┘  │   (Floating)    │  │
│                                            └─────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│                      Application Layer                          │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │              TranscriptionController                        │ │
│  │  - Session management                                       │ │
│  │  - Mode switching (Mic-only / Mic+App)                     │ │
│  │  - State coordination                                       │ │
│  └────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│                      Audio Capture Layer                         │
│  ┌──────────────────┐         ┌──────────────────────────────┐  │
│  │ MicrophoneCapture│         │  ScreenCaptureKit Manager    │  │
│  │ (AVAudioEngine)  │         │  (System/App Audio Capture)  │  │
│  └──────────────────┘         └──────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│                     Audio Processing Layer                       │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │              AudioMixerPipeline                             │ │
│  │  ┌──────────┐  ┌───────────┐  ┌─────────────┐            │ │
│  │  │  Mixer   │→ │ Converter │→ │ Ring Buffer │            │ │
│  │  │  Node    │  │ (16kHz)   │  │             │            │ │
│  │  └──────────┘  └───────────┘  └─────────────┘            │ │
│  └────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│                      Inference Layer                             │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │              WhisperEngine                                  │ │
│  │  ┌──────────────┐  ┌──────────────┐  ┌─────────────────┐  │ │
│  │  │  Model Mgr   │  │ Inference    │  │ Post-Processor  │  │ │
│  │  │  (GGML/GGUF) │  │ (Metal)      │  │ (Punctuation)   │  │ │
│  │  └──────────────┘  └──────────────┘  └─────────────────┘  │ │
│  └────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│                       Output Layer                               │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │              OutputManager                                  │ │
│  │  ┌──────────────────┐  ┌────────────────────────────────┐ │ │
│  │  │  Clipboard Mgr   │  │  Auto-Paste (Accessibility)    │ │ │
│  │  │  (NSPasteboard)  │  │  (CGEvent / AX APIs)           │ │ │
│  │  └──────────────────┘  └────────────────────────────────┘ │ │
│  └────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
```

---

## Component Design

### 1. TranscriptionController

**Responsibilities:**
- Central coordinator for transcription sessions
- Manages state transitions (idle → recording → processing → stopped)
- Handles mode switching between Mic-only and Mic+App
- Coordinates between audio capture, inference, and output

**Key APIs:**
```swift
class TranscriptionController {
    func startTranscription(mode: CaptureMode)
    func stopTranscription()
    func pauseTranscription()
    func resumeTranscription()
    func switchMode(_ newMode: CaptureMode)
}

enum CaptureMode {
    case microphoneOnly
    case microphoneAndApp(SCRunningApplication)
    case microphoneAndSystem
}
```

### 2. MicrophoneCapture

**Responsibilities:**
- Initialize and manage AVAudioEngine
- Capture microphone input
- Handle device changes (e.g., Bluetooth disconnect)
- Provide audio level monitoring

**Implementation:**
```swift
class MicrophoneCapture {
    private let engine = AVAudioEngine()
    private let inputNode: AVAudioInputNode

    func start(callback: @escaping (AVAudioPCMBuffer) -> Void)
    func stop()
    func getCurrentLevel() -> Float
}
```

### 3. ScreenCaptureKitManager

**Responsibilities:**
- Enumerate available audio sources (apps, windows, displays)
- Create and manage SCStream for app/system audio capture
- Handle permission requests
- Convert CMSampleBuffer to AVAudioPCMBuffer

**Implementation:**
```swift
class ScreenCaptureKitManager: NSObject, SCStreamDelegate, SCStreamOutput {
    func getAvailableAudioSources() async throws -> [AudioSource]
    func startCapture(source: AudioSource, callback: @escaping (AVAudioPCMBuffer) -> Void)
    func stopCapture()

    // SCStreamOutput
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType)
}

struct AudioSource {
    let type: SourceType
    let identifier: String
    let displayName: String

    enum SourceType {
        case application(SCRunningApplication)
        case window(SCWindow)
        case display(SCDisplay)
    }
}
```

### 4. AudioMixerPipeline

**Responsibilities:**
- Combine multiple audio sources using AVAudioMixerNode
- Convert to Whisper-compatible format (16kHz, mono, float32)
- Buffer management with ring buffer
- VAD (Voice Activity Detection) processing

**Implementation:**
```swift
class AudioMixerPipeline {
    private let mixerNode = AVAudioMixerNode()
    private let converter: AVAudioConverter
    private let ringBuffer: RingBuffer
    private let vadProcessor: VADProcessor?

    func addAudioSource(_ source: AudioSource, buffer: AVAudioPCMBuffer)
    func processAndEnqueue()
    func getNextChunk(duration: TimeInterval) -> AVAudioPCMBuffer?
}
```

### 5. WhisperEngine

**Responsibilities:**
- Load and manage Whisper models (GGML/GGUF format)
- Perform streaming inference with Metal acceleration
- Handle chunking and timestamp management
- Provide partial and final transcripts

**Implementation:**
```swift
class WhisperEngine {
    private var context: OpaquePointer?
    private let modelPath: String
    private let config: WhisperConfig

    func loadModel() throws
    func transcribe(audioBuffer: [Float], streaming: Bool) -> TranscriptResult
    func transcribeStreaming(audioBuffer: [Float]) -> PartialTranscript
    func finalizeTranscript() -> String

    struct WhisperConfig {
        let language: String?
        let modelSize: ModelSize
        let quantization: Quantization
        let enableMetal: Bool
    }
}
```

### 6. OutputManager

**Responsibilities:**
- Copy transcript to clipboard
- Simulate paste via Accessibility APIs (if enabled)
- Handle permission checks
- Provide fallback mechanisms

**Implementation:**
```swift
class OutputManager {
    func copyToClipboard(_ text: String)
    func autoPaste(_ text: String) -> PasteResult
    func checkAccessibilityPermission() -> Bool

    enum PasteResult {
        case success
        case permissionDenied
        case targetAppUnsupported
        case failed(Error)
    }
}
```

---

## Data Flow

### Mic-Only Transcription Flow

```
1. User activates hotkey
   ↓
2. TranscriptionController.startTranscription(.microphoneOnly)
   ↓
3. MicrophoneCapture initializes AVAudioEngine
   ↓
4. Audio buffers → AudioMixerPipeline (conversion to 16kHz mono)
   ↓
5. Ring buffer accumulates samples
   ↓
6. WhisperEngine pulls chunks (e.g., 1s windows)
   ↓
7. Streaming inference → Partial transcripts emitted
   ↓
8. HUD updates with live text
   ↓
9. User presses stop hotkey
   ↓
10. Final inference pass with full context
   ↓
11. Post-processing (punctuation, capitalization)
   ↓
12. OutputManager copies to clipboard
   ↓
13. If auto-paste enabled: simulate Cmd-V
   ↓
14. HUD shows confirmation
```

### Mic + App Audio Flow

```
1. User selects Mode B
   ↓
2. ScreenCaptureKitManager presents app picker
   ↓
3. User selects target app (e.g., Zoom)
   ↓
4. Screen Recording permission check
   ↓
5. SCStream configured with audio capture
   ↓
6. Parallel capture:
   - Microphone → Buffer A
   - App audio → Buffer B
   ↓
7. AudioMixerPipeline merges streams
   ↓
8. [Same as steps 5-14 from Mic-Only flow]
```

---

## Threading Model

### Thread Safety Strategy

1. **Main Thread (UI)**
   - All UI updates
   - User interaction handling
   - Settings changes

2. **Audio IO Thread (Real-time priority)**
   - AVAudioEngine callbacks
   - ScreenCaptureKit audio output
   - Ring buffer writes
   - **Critical:** Must not block; no locks; use lock-free structures

3. **Inference Queue (QoS: userInitiated)**
   - Whisper model inference
   - Chunking and buffering
   - Can be throttled based on battery state

4. **Background Queue (QoS: utility)**
   - Model downloading
   - File I/O for saved transcripts
   - Telemetry logging

### Synchronization

- **Ring Buffer:** Lock-free circular buffer with atomic read/write pointers
- **State Machine:** Actor-based TranscriptionController (Swift 6.0+)
- **Callbacks:** Use DispatchQueue.main.async for UI updates from background threads

---

## Audio Pipeline

### Audio Format Specifications

**Input Formats (Variable):**
- Microphone: typically 48kHz stereo or mono
- ScreenCaptureKit: 48kHz stereo (AAC decoded to PCM)

**Processing Format:**
- Mixer output: 16kHz mono float32 (native Whisper format)
- Sample rate conversion: AVAudioConverter with high-quality algorithm

### Ring Buffer Design

```swift
class RingBuffer {
    private var buffer: [Float]
    private var writeIndex: atomic<Int>
    private var readIndex: atomic<Int>
    private let capacity: Int

    func write(_ samples: [Float]) -> Bool
    func read(count: Int) -> [Float]?
    func availableSamples() -> Int
}
```

**Capacity:** 10 seconds @ 16kHz = 160,000 samples

### VAD Integration (Optional)

- **WebRTC VAD:** C library integration via bridging header
- **Energy-based fallback:** RMS threshold detection
- **Purpose:**
  - Gate inference (don't process silence)
  - Improve punctuation (detect sentence boundaries)
  - Reduce hallucinations

---

## Whisper Integration

### whisper.cpp Integration

**Build Configuration:**
```bash
# Build whisper.cpp with Metal support
cmake -B build \
    -DGGML_METAL=ON \
    -DGGML_METAL_NDEBUG=ON \
    -DCMAKE_BUILD_TYPE=Release

cmake --build build --config Release
```

**Xcode Integration:**
- Add whisper.cpp as a git submodule
- Create build phase script to compile native library
- Link libwhisper.a + Metal framework
- Create Swift bridging header for C API

### Model Management

**Storage Location:**
```
~/Library/Application Support/MacTalk/Models/
├── ggml-tiny-q5_0.bin
├── ggml-base-q5_0.bin
├── ggml-small-q5_0.bin
├── ggml-medium-q5_0.bin
└── ggml-large-v3-turbo-q5_0.bin
```

**Download Strategy:**
- On-demand download from Hugging Face or official mirror
- SHA256 checksum verification
- Progress UI during download
- Fallback to smallest model if download fails

### Streaming Inference

**Chunk Strategy:**
```
Audio stream:  [===0.5s===][===0.5s===][===0.5s===]...
Inference:         [====1.0s====]
                       [====1.0s====]
                           [====1.0s====]
```

- 0.5s input stride
- 1.0s window with 0.5s overlap
- Prevents word splitting at boundaries
- Timestamps used to de-duplicate overlaps

---

## UI Components

### 1. Menu Bar Extra

**NSStatusItem** with custom view:
- Icon states: idle / recording / processing
- Click → dropdown menu with:
  - Start/Stop
  - Mode selector
  - Model selector
  - Settings
  - Last transcript preview
  - Quit

### 2. HUD Overlay

**Borderless NSWindow (NSPanel):**
- Always on top
- Level: NSWindow.Level.floating
- Semi-transparent background
- Components:
  - Audio level meters (Core Graphics custom view)
  - Live transcript label (scrolling single line)
  - Start/Stop button
  - Mode indicator

**Position:** Top-right corner with configurable offset

### 3. Settings Window

**NSWindow with tabs:**
- General: default mode, model, language
- Output: auto-paste, punctuation, clipboard behavior
- Audio: input device selector, VAD settings, level thresholds
- Advanced: chunk size, overlap, Metal device selector
- Permissions: status indicators with "Grant" buttons

### 4. App Audio Picker

**Sheet presented from HUD:**
- SCShareableContent query results
- Table view with:
  - App icon
  - App name
  - Window titles (if applicable)
- Search/filter field
- System audio option

---

## Security & Permissions

### Permission Request Flow

```swift
class PermissionManager {
    func requestMicrophoneAccess() async -> Bool {
        return await AVCaptureDevice.requestAccess(for: .audio)
    }

    func requestScreenRecordingAccess() -> Bool {
        // Triggering SCShareableContent triggers prompt
        Task {
            _ = try? await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        }
        return checkScreenRecordingAccess()
    }

    func requestAccessibilityAccess() -> Bool {
        let options: NSDictionary = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true
        ]
        return AXIsProcessTrustedWithOptions(options)
    }
}
```

### Usage Descriptions (Info.plist)

```xml
<key>NSMicrophoneUsageDescription</key>
<string>MacTalk needs microphone access to transcribe your voice.</string>

<key>NSScreenCaptureUsageDescription</key>
<string>MacTalk needs screen recording permission to capture app audio for transcription.</string>

<key>NSAppleEventsUsageDescription</key>
<string>MacTalk needs accessibility permission to auto-paste transcriptions.</string>
```

### Sandboxing Considerations

**Entitlements (if targeting Mac App Store):**
```xml
<key>com.apple.security.device.audio-input</key>
<true/>
<key>com.apple.security.device.camera</key>
<false/>
<key>com.apple.security.automation.apple-events</key>
<true/>
```

**Note:** ScreenCaptureKit works in sandboxed apps as of macOS 12.3+

---

## Performance Considerations

### Metal Optimization

- Enable Metal backend in whisper.cpp build
- Use GPU for matrix operations
- Monitor GPU utilization via `IOReporting` framework
- Adaptive throttling:
  - Battery: reduce inference frequency, prefer smaller model
  - Thermal: skip frames if temperature critical

### Memory Management

**Budget by Model:**
| Model | RAM | VRAM (approx) |
|-------|-----|---------------|
| tiny  | 100 MB | 50 MB |
| base  | 150 MB | 75 MB |
| small | 500 MB | 250 MB |
| medium | 1.5 GB | 750 MB |
| large-v3-turbo | 2.5 GB | 1.2 GB |

**Strategies:**
- Release model from memory when idle (configurable timeout)
- Use autoreleasepool in inference loop
- Monitor memory pressure via `DispatchSource.makeMemoryPressureSource`

### Latency Optimization

**Target Latencies (M4, small model Q5_0):**
- Audio capture → ring buffer: < 10ms
- Ring buffer → inference queue: < 50ms
- Inference (1s chunk): 200–300ms
- Post-processing: < 20ms
- Total perceived latency: < 400ms

**Techniques:**
- Pre-warm model on app launch
- Use small initial chunks (256ms) for faster first word
- Throttle UI updates to 10 Hz to reduce main thread load

---

## Error Handling

### Recoverable Errors

| Error | Recovery Strategy |
|-------|-------------------|
| Mic disconnected | Show alert, pause transcription, auto-resume on reconnect |
| App audio source closed | Fall back to mic-only, notify user |
| Inference timeout | Skip chunk, log warning, continue with next |
| Low memory warning | Suggest smaller model, offer to switch |

### Fatal Errors

| Error | User Action |
|-------|-------------|
| Model file corrupted | Re-download model |
| Metal device unavailable | Offer CPU fallback (significantly slower) |
| Permission denied (mic) | Show settings guidance, disable app |

---

## Future Extensibility

### Planned Enhancements

1. **Speaker Diarization:**
   - Use channel energy to infer mic vs. remote speaker
   - Prefix transcript lines with [You] / [Remote]

2. **Command Mode:**
   - Recognize special phrases ("new line", "comma")
   - Transform to formatting in final transcript

3. **Multi-language Sessions:**
   - Auto-detect language switches mid-session
   - Support code-switching transcription

4. **Export Formats:**
   - SRT/VTT for subtitles
   - Formatted notes (Markdown)
   - Audio + transcript bundle

### Plugin Architecture (v2.0)

```swift
protocol TranscriptProcessor {
    func process(_ transcript: String) -> String
}

class ProcessorRegistry {
    func register(_ processor: TranscriptProcessor, forType: String)
    func apply(transcript: String) -> String
}
```

Allow third-party processors for:
- Custom punctuation rules
- Domain-specific vocabulary
- Integration with note-taking apps

---

## Testing Strategy

### Unit Tests
- Ring buffer correctness (thread-safe operations)
- Audio format conversion
- VAD accuracy (with known audio samples)
- Model loading and inference (mocked)

### Integration Tests
- End-to-end transcription with sample audio files
- Permission flows (requires manual testing)
- Multi-source audio mixing

### Performance Tests
- Latency benchmarks per model/device combination
- Memory leak detection (Instruments)
- GPU utilization profiling

### UI Tests
- Menu bar interactions
- HUD display and updates
- Settings persistence

---

## Build & Deployment

### Minimum Requirements
- macOS 14.0+ (Sonoma)
- Xcode 15.0+
- Apple Silicon (M1 or later) — optimized for M4

### Build Configurations

**Debug:**
- Verbose logging enabled
- Developer HUD with metrics
- Shorter model download timeout (for testing)

**Release:**
- Optimizations enabled (`-O3`)
- Logging reduced to warnings/errors
- App notarization and hardened runtime

### Distribution

**Option 1: Direct Download**
- Notarized .dmg
- Sparkle framework for updates

**Option 2: Mac App Store**
- Sandbox enabled
- Receipt validation
- App Review compliance (no private APIs)

---

## Appendix: Code Snippets

### Example: ScreenCaptureKit Audio Setup

```swift
func setupAppAudioCapture(app: SCRunningApplication) async throws {
    let content = try await SCShareableContent.excludingDesktopWindows(
        false,
        onScreenWindowsOnly: true
    )

    guard let window = app.windows.first else {
        throw CaptureError.noWindowsAvailable
    }

    let filter = SCContentFilter(desktopIndependentWindow: window)

    let config = SCStreamConfiguration()
    config.capturesAudio = true
    config.excludesCurrentProcessAudio = true
    config.sampleRate = 48000
    config.channelCount = 2

    let stream = SCStream(filter: filter, configuration: config, delegate: self)
    try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
    try await stream.startCapture()
}

// SCStreamOutput implementation
func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
    guard type == .audio else { return }

    // Convert CMSampleBuffer to AVAudioPCMBuffer
    guard let audioBuffer = convertToAudioBuffer(sampleBuffer) else { return }

    // Send to mixer
    audioMixer.addAppAudio(audioBuffer)
}
```

### Example: Whisper Streaming Inference

```swift
func processAudioChunk(_ samples: [Float]) -> PartialTranscript {
    var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
    params.n_threads = 4
    params.language = "en"
    params.translate = false
    params.print_realtime = false
    params.print_progress = false
    params.no_timestamps = false

    // Run inference
    let result = whisper_full(context, params, samples, Int32(samples.count))
    guard result == 0 else {
        return PartialTranscript(text: "", confidence: 0)
    }

    // Extract text
    let nSegments = whisper_full_n_segments(context)
    var text = ""
    for i in 0..<nSegments {
        if let cStr = whisper_full_get_segment_text(context, i) {
            text += String(cString: cStr)
        }
    }

    return PartialTranscript(text: text, confidence: 0.95)
}
```

---

## References

- [whisper.cpp GitHub](https://github.com/ggerganov/whisper.cpp)
- [ScreenCaptureKit Documentation](https://developer.apple.com/documentation/screencapturekit)
- [AVAudioEngine Guide](https://developer.apple.com/documentation/avfaudio/avaudioengine)
- [Accessibility Programming Guide](https://developer.apple.com/library/archive/documentation/Accessibility/Conceptual/AccessibilityMacOSX/)

---

**Document Version Control:**
- v1.0 (2025-10-21): Initial architecture design
