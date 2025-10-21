# MacTalk Development Roadmap

**Version:** 1.0
**Last Updated:** 2025-10-21
**Status:** Planning Phase

---

## Table of Contents

1. [Development Phases](#development-phases)
2. [Phase 0: Foundation](#phase-0-foundation-weeks-1-2)
3. [Phase 1: Core Audio](#phase-1-core-audio-weeks-3-4)
4. [Phase 2: Whisper Integration](#phase-2-whisper-integration-weeks-5-6)
5. [Phase 3: UI Implementation](#phase-3-ui-implementation-weeks-7-8)
6. [Phase 4: Mode B (App Audio)](#phase-4-mode-b-app-audio-weeks-9-10)
7. [Phase 5: Polish & Testing](#phase-5-polish--testing-weeks-11-12)
8. [Phase 6: Release Preparation](#phase-6-release-preparation-weeks-13-14)
9. [Post-Launch Roadmap](#post-launch-roadmap)

---

## Development Phases

### Timeline Overview

```
Weeks 1-2:  Foundation (Project setup, dependencies)
Weeks 3-4:  Core Audio (Mic capture, processing pipeline)
Weeks 5-6:  Whisper Integration (Model loading, inference)
Weeks 7-8:  UI Implementation (Menu bar, HUD, settings)
Weeks 9-10: Mode B (ScreenCaptureKit, app audio)
Weeks 11-12: Polish & Testing (Performance, edge cases)
Weeks 13-14: Release Preparation (Notarization, docs)
```

**Total Duration:** 14 weeks (3.5 months)

---

## Phase 0: Foundation (Weeks 1-2)

### Goals
- Set up development environment
- Establish project structure
- Integrate core dependencies
- Create basic app skeleton

### Milestones

#### M0.1: Xcode Project Setup
**Deliverables:**
- [ ] Create new macOS App project in Xcode
- [ ] Configure project settings:
  - Minimum deployment target: macOS 14.0
  - Bundle identifier: com.mactalk.app
  - Signing & capabilities configured
- [ ] Set up folder structure:
  ```
  MacTalk/
  ├── Sources/
  │   ├── App/           (AppDelegate, main)
  │   ├── Core/          (Models, controllers)
  │   ├── Audio/         (Capture, processing)
  │   ├── Inference/     (Whisper integration)
  │   ├── UI/            (Views, windows)
  │   └── Utilities/     (Helpers, extensions)
  ├── Resources/
  ├── Tests/
  └── Vendor/            (Third-party libs)
  ```
- [ ] Create Info.plist with usage descriptions

**Acceptance Criteria:**
- App builds and runs (shows empty window)
- Folder structure matches architecture doc

---

#### M0.2: Dependency Integration
**Deliverables:**
- [ ] Add whisper.cpp as git submodule
  ```bash
  git submodule add https://github.com/ggerganov/whisper.cpp Vendor/whisper.cpp
  ```
- [ ] Create build script for whisper.cpp with Metal support
- [ ] Set up Swift bridging header for C/C++ interop
- [ ] Add WebRTC VAD library (optional, can defer)
- [ ] Configure Swift Package Manager dependencies (if any)

**Acceptance Criteria:**
- whisper.cpp builds successfully with Metal enabled
- Can call `whisper_init_from_file()` from Swift
- Bridging header compiles without errors

---

#### M0.3: Basic App Structure
**Deliverables:**
- [ ] Implement AppDelegate with menu bar setup
- [ ] Create placeholder NSStatusItem
- [ ] Set up basic logging infrastructure
- [ ] Implement PermissionManager skeleton
- [ ] Create UserDefaults wrapper for settings

**Acceptance Criteria:**
- Menu bar icon appears on launch
- Click shows placeholder menu
- Logs written to Console.app

---

### Week-by-Week Tasks

**Week 1:**
- Day 1-2: Xcode project creation, basic app structure
- Day 3-4: whisper.cpp submodule integration and build script
- Day 5: Swift bridging header, test basic Whisper C API calls

**Week 2:**
- Day 1-2: Folder structure reorganization, create base classes
- Day 3-4: Logging infrastructure, PermissionManager skeleton
- Day 5: Documentation review, update PROGRESS.md

---

## Phase 1: Core Audio (Weeks 3-4)

### Goals
- Implement microphone capture with AVAudioEngine
- Build audio processing pipeline (mixing, conversion)
- Create ring buffer for audio chunks
- Basic level monitoring

### Milestones

#### M1.1: Microphone Capture
**Deliverables:**
- [ ] Implement `MicrophoneCapture` class
- [ ] Request microphone permission
- [ ] Initialize AVAudioEngine with input node
- [ ] Capture audio buffers in real-time
- [ ] Handle device changes (disconnect/reconnect)

**Code Focus:**
```swift
class MicrophoneCapture {
    private let engine = AVAudioEngine()
    private var isRunning = false

    func start() throws
    func stop()
    func installTap(callback: @escaping (AVAudioPCMBuffer) -> Void)
}
```

**Acceptance Criteria:**
- Microphone permission requested on first launch
- Audio captured at native sample rate
- Handles Bluetooth mic disconnect gracefully
- Level meter shows activity when speaking

---

#### M1.2: Audio Processing Pipeline
**Deliverables:**
- [ ] Implement `AudioMixerPipeline` class
- [ ] Create AVAudioMixerNode for multi-source mixing
- [ ] Add AVAudioConverter for resampling to 16kHz mono
- [ ] Implement format conversion (Float32)
- [ ] Add optional gain/normalization

**Acceptance Criteria:**
- Input audio (any sample rate) → output 16kHz mono Float32
- Conversion latency < 10ms
- No audio artifacts (clipping, distortion)

---

#### M1.3: Ring Buffer Implementation
**Deliverables:**
- [ ] Implement lock-free ring buffer
- [ ] Support concurrent read/write
- [ ] Provide chunk extraction (e.g., 1s windows)
- [ ] Handle overflow/underflow conditions

**Code Focus:**
```swift
class RingBuffer {
    private var buffer: [Float]
    private var writeIndex = atomic<Int>(0)
    private var readIndex = atomic<Int>(0)

    func write(_ samples: [Float])
    func read(count: Int) -> [Float]?
}
```

**Acceptance Criteria:**
- No race conditions (tested with Thread Sanitizer)
- Can sustain real-time audio rates (16kHz continuous)
- Graceful handling of buffer full/empty states

---

#### M1.4: Audio Level Monitoring
**Deliverables:**
- [ ] Calculate RMS levels for display
- [ ] Implement peak hold detection
- [ ] Add smoothing filter for UI updates
- [ ] Create AudioLevelMonitor utility class

**Acceptance Criteria:**
- Level meters respond in < 50ms
- Smooth visual updates (no jitter)
- Accurate dB scale representation

---

### Week-by-Week Tasks

**Week 3:**
- Day 1-2: MicrophoneCapture implementation and testing
- Day 3-4: AudioMixerPipeline and format conversion
- Day 5: Integration testing, handle edge cases

**Week 4:**
- Day 1-2: Ring buffer implementation (lock-free design)
- Day 3-4: Audio level monitoring, smoothing algorithms
- Day 5: End-to-end test (mic → processing → buffer)

---

## Phase 2: Whisper Integration (Weeks 5-6)

### Goals
- Load Whisper models from disk
- Implement streaming inference
- Handle partial and final transcripts
- Optimize for Metal/GPU acceleration

### Milestones

#### M2.1: Model Management
**Deliverables:**
- [ ] Create `ModelManager` class
- [ ] Implement model download with progress
- [ ] Add SHA256 checksum verification
- [ ] Store models in Application Support directory
- [ ] Support multiple model sizes (tiny → large-v3-turbo)

**Code Focus:**
```swift
class ModelManager {
    func downloadModel(_ type: ModelType, progress: @escaping (Double) -> Void) async throws
    func getModelPath(_ type: ModelType) -> URL?
    func verifyModel(_ type: ModelType) -> Bool
}
```

**Acceptance Criteria:**
- Models download successfully from Hugging Face
- Checksum mismatches trigger re-download
- Progress UI shows download percentage
- Models persist across app restarts

---

#### M2.2: Whisper Engine Core
**Deliverables:**
- [ ] Implement `WhisperEngine` class
- [ ] Load model with `whisper_init_from_file()`
- [ ] Configure inference parameters (language, threads, etc.)
- [ ] Implement single-shot transcription
- [ ] Add error handling for model loading failures

**Acceptance Criteria:**
- Can load and initialize any model size
- Transcribe 10s audio sample in < 5s (small model, M4)
- Metal backend activated (verify in Metal debugger)

---

#### M2.3: Streaming Inference
**Deliverables:**
- [ ] Implement chunked processing (0.5-1.0s windows)
- [ ] Add overlap stitching to prevent word breaks
- [ ] Emit partial transcripts during recording
- [ ] Implement timestamp tracking for de-duplication
- [ ] Add back-pressure handling (drop old chunks if needed)

**Code Focus:**
```swift
class WhisperEngine {
    func transcribeStreaming(_ chunk: [Float]) -> PartialTranscript
    func finalizeTranscript() -> FinalTranscript

    struct PartialTranscript {
        let text: String
        let timestamp: TimeInterval
        let confidence: Float
    }
}
```

**Acceptance Criteria:**
- Partial transcripts appear within 500ms of speech
- No duplicate words in final output
- Handles speech pauses gracefully
- Latency targets met (see ARCHITECTURE.md §10)

---

#### M2.4: Post-Processing
**Deliverables:**
- [ ] Implement basic punctuation insertion
- [ ] Add capitalization rules (sentence start, proper nouns)
- [ ] Create `TranscriptPostProcessor` class
- [ ] Make post-processing optional (user setting)

**Acceptance Criteria:**
- Sentences end with periods
- First word capitalized
- Common proper nouns capitalized (I, Monday, etc.)
- Processing adds < 50ms latency

---

### Week-by-Week Tasks

**Week 5:**
- Day 1-2: ModelManager, download infrastructure
- Day 3-4: WhisperEngine core, single-shot transcription
- Day 5: Test with all model sizes, verify Metal usage

**Week 6:**
- Day 1-3: Streaming inference implementation
- Day 4: Post-processing (punctuation, capitalization)
- Day 5: Integration test (audio pipeline → Whisper → text)

---

## Phase 3: UI Implementation (Weeks 7-8)

### Goals
- Build menu bar app interface
- Create HUD overlay
- Implement settings window
- Add hotkey support

### Milestones

#### M3.1: Menu Bar App
**Deliverables:**
- [ ] Create custom NSStatusItem view
- [ ] Add icon states (idle, recording, processing, error)
- [ ] Implement dropdown menu with actions
- [ ] Show last transcript preview
- [ ] Add Quick Settings submenu

**Acceptance Criteria:**
- Icon animates during recording
- Menu shows current mode and model
- Click "Start" begins transcription
- Last transcript displays (truncated if > 100 chars)

---

#### M3.2: HUD Overlay
**Deliverables:**
- [ ] Create borderless NSPanel for HUD
- [ ] Add level meters (custom NSView)
- [ ] Display live partial transcript
- [ ] Implement Start/Stop button
- [ ] Make HUD draggable and position-persistent

**Code Focus:**
```swift
class HUDController: NSWindowController {
    private let levelMeterView: AudioLevelMeterView
    private let transcriptLabel: NSTextField
    private let actionButton: NSButton

    func show()
    func hide()
    func updateLevels(mic: Float, app: Float?)
    func updatePartialTranscript(_ text: String)
}
```

**Acceptance Criteria:**
- HUD appears on hotkey press
- Level meters animate smoothly (60 FPS)
- Partial transcript scrolls if too long
- HUD position saves to UserDefaults

---

#### M3.3: Settings Window
**Deliverables:**
- [ ] Create NSWindow with tab view
- [ ] Implement tabs:
  - General (mode, model, language)
  - Output (auto-paste, punctuation)
  - Audio (input device, VAD)
  - Advanced (performance tuning)
  - Permissions (status indicators)
- [ ] Bind UI to UserDefaults
- [ ] Add validation for inputs

**Acceptance Criteria:**
- Settings persist across launches
- Changes apply immediately (or on next session)
- Permission status shows green/red badges
- "Grant Permission" buttons work correctly

---

#### M3.4: Hotkey Support
**Deliverables:**
- [ ] Implement global hotkey registration
- [ ] Use Carbon or MASShortcut library
- [ ] Add hotkey customization in Settings
- [ ] Handle conflicts (already registered by other app)

**Acceptance Criteria:**
- Default hotkey (e.g., Cmd+Shift+Space) starts/stops
- User can change hotkey in Settings
- Hotkey works when app in background
- Graceful error if hotkey unavailable

---

### Week-by-Week Tasks

**Week 7:**
- Day 1-2: Menu bar app, icon states, dropdown menu
- Day 3-4: HUD overlay, level meters, partial transcript display
- Day 5: Polish animations, test on different screen sizes

**Week 8:**
- Day 1-3: Settings window (all tabs), UserDefaults binding
- Day 4: Hotkey registration and customization
- Day 5: UI polish, accessibility (VoiceOver testing)

---

## Phase 4: Mode B (App Audio) (Weeks 9-10)

### Goals
- Integrate ScreenCaptureKit for app/system audio
- Build app picker UI
- Implement audio source mixing
- Handle permissions and edge cases

### Milestones

#### M4.1: ScreenCaptureKit Integration
**Deliverables:**
- [ ] Implement `ScreenCaptureKitManager` class
- [ ] Query available audio sources (apps, windows, displays)
- [ ] Create SCStream with audio capture
- [ ] Convert CMSampleBuffer to AVAudioPCMBuffer
- [ ] Handle Screen Recording permission

**Code Focus:**
```swift
class ScreenCaptureKitManager: NSObject, SCStreamDelegate, SCStreamOutput {
    func getAvailableAudioSources() async throws -> [AudioSource]
    func startCapture(_ source: AudioSource) async throws
    func stream(_ stream: SCStream, didOutputSampleBuffer: CMSampleBuffer, of: SCStreamOutputType)
}
```

**Acceptance Criteria:**
- Can enumerate running apps with audio
- Captures app audio successfully (test with Zoom, Safari)
- Audio quality matches original (no degradation)
- Screen Recording permission requested correctly

---

#### M4.2: App Picker UI
**Deliverables:**
- [ ] Create NSWindow sheet for app selection
- [ ] Show table view with app names and icons
- [ ] Add search/filter functionality
- [ ] Include "System Audio" option
- [ ] Show live audio preview (level meter)

**Acceptance Criteria:**
- All audio-capable apps listed
- Filter narrows results in real-time
- Selected app persists for session
- Preview shows activity for selected source

---

#### M4.3: Multi-Source Mixing
**Deliverables:**
- [ ] Extend AudioMixerPipeline for dual input
- [ ] Balance levels between mic and app audio
- [ ] Implement channel separation (optional for diarization)
- [ ] Add per-channel level controls

**Acceptance Criteria:**
- Both mic and app audio audible in transcript
- Level balance adjustable in Settings
- No phase cancellation or artifacts
- Latency still within targets (< 500ms)

---

#### M4.4: Edge Case Handling
**Deliverables:**
- [ ] Handle app closure during capture
- [ ] Fallback to mic-only if app audio lost
- [ ] Show toast notification on source change
- [ ] Retry logic for transient failures

**Acceptance Criteria:**
- Closing Zoom mid-session → graceful fallback
- Notification shows "App audio lost, mic-only mode"
- Can re-select app without stopping session

---

### Week-by-Week Tasks

**Week 9:**
- Day 1-3: ScreenCaptureKit implementation, audio capture
- Day 4-5: App picker UI, search/filter

**Week 10:**
- Day 1-2: Multi-source mixing in AudioMixerPipeline
- Day 3-4: Edge case handling, fallback logic
- Day 5: End-to-end test (mic + app → transcript)

---

## Phase 5: Polish & Testing (Weeks 11-12)

### Goals
- Performance optimization
- Comprehensive testing (unit, integration, UI)
- Bug fixes from alpha testing
- Accessibility improvements

### Milestones

#### M5.1: Performance Optimization
**Deliverables:**
- [ ] Profile with Instruments (Time Profiler, Allocations)
- [ ] Optimize hot paths in audio pipeline
- [ ] Reduce memory footprint
- [ ] Implement adaptive quality (battery mode)
- [ ] Test on M1 (not just M4)

**Acceptance Criteria:**
- GPU usage < 60% during streaming (small model, M4)
- Memory stays under budget (see ARCHITECTURE.md §10)
- Battery mode reduces power by 30%+
- Runs smoothly on M1

---

#### M5.2: Automated Testing
**Deliverables:**
- [ ] Write unit tests:
  - Ring buffer (concurrent operations)
  - Audio format conversion
  - Transcript post-processing
  - Model download & checksum
- [ ] Integration tests:
  - Mic → Whisper → clipboard (end-to-end)
  - Multi-source mixing
  - Permission flows (manual)
- [ ] UI tests:
  - Menu bar interactions
  - Settings persistence
  - HUD display

**Acceptance Criteria:**
- Code coverage > 70% (excluding UI)
- All tests pass on CI (GitHub Actions)
- No regressions detected

---

#### M5.3: Alpha Testing
**Deliverables:**
- [ ] Recruit 5-10 alpha testers
- [ ] Distribute TestFlight build (or .dmg)
- [ ] Collect feedback via survey
- [ ] Triage and fix critical bugs
- [ ] Iterate on UX based on feedback

**Acceptance Criteria:**
- No P0 crashes in alpha testing
- Average rating > 4/5 stars
- Key use cases validated (dictation, call transcription)

---

#### M5.4: Accessibility & Localization Prep
**Deliverables:**
- [ ] VoiceOver support for all UI elements
- [ ] Keyboard navigation (tab order, shortcuts)
- [ ] Prepare for localization (extract strings)
- [ ] Test with Accessibility Inspector

**Acceptance Criteria:**
- All UI accessible via VoiceOver
- Can operate app without mouse
- Strings ready for translation (NSLocalizedString)

---

### Week-by-Week Tasks

**Week 11:**
- Day 1-2: Performance profiling and optimization
- Day 3-5: Unit and integration test writing

**Week 12:**
- Day 1-2: Alpha build distribution, feedback collection
- Day 3-4: Bug fixes from alpha testing
- Day 5: Accessibility testing and improvements

---

## Phase 6: Release Preparation (Weeks 13-14)

### Goals
- Finalize documentation
- Notarization and signing
- Create release builds
- Prepare marketing materials

### Milestones

#### M6.1: Documentation
**Deliverables:**
- [ ] User guide (in-app or web)
- [ ] FAQ document
- [ ] Privacy policy
- [ ] Third-party licenses (whisper.cpp, WebRTC VAD)
- [ ] Developer documentation (if open-source)

**Acceptance Criteria:**
- User guide covers all features
- Privacy policy reviewed by legal (if applicable)
- Licenses included in About window

---

#### M6.2: Notarization & Signing
**Deliverables:**
- [ ] Code signing certificate configured
- [ ] Enable Hardened Runtime
- [ ] Submit for notarization via Xcode
- [ ] Staple notarization ticket to .dmg
- [ ] Test on clean macOS install

**Acceptance Criteria:**
- App runs on Gatekeeper-enabled Mac without warning
- Notarization status: "approved"
- Signed binary verifies: `codesign --verify --verbose`

---

#### M6.3: Release Build
**Deliverables:**
- [ ] Create Release build configuration
- [ ] Optimize binary size (strip symbols)
- [ ] Bundle default model (tiny or base) for offline use
- [ ] Create installer .dmg with custom background
- [ ] Test installation on macOS 14, 15

**Acceptance Criteria:**
- .dmg < 200 MB (with bundled tiny model)
- Installs to /Applications cleanly
- First launch experience smooth (no errors)

---

#### M6.4: Marketing & Distribution
**Deliverables:**
- [ ] Create website or landing page
- [ ] Write blog post / announcement
- [ ] Prepare demo video (2-3 minutes)
- [ ] Set up GitHub Releases (if open-source)
- [ ] Submit to Mac App Store (if applicable)

**Acceptance Criteria:**
- Landing page live with download link
- Demo video uploaded to YouTube
- GitHub repository public (if open-source)

---

### Week-by-Week Tasks

**Week 13:**
- Day 1-2: Documentation writing (user guide, FAQ)
- Day 3-4: Notarization and signing setup
- Day 5: Test notarized build on multiple Macs

**Week 14:**
- Day 1-2: Release build creation, .dmg packaging
- Day 3-4: Marketing materials (website, video)
- Day 5: Launch! Monitor for issues, prepare hotfix if needed

---

## Post-Launch Roadmap

### v1.1 (1-2 months post-launch)
**Focus:** User-requested features

**Planned Features:**
- [ ] Per-app model/language presets
- [ ] Command vocabulary ("new line", "comma", "period")
- [ ] Keyboard shortcuts for common actions
- [ ] Export transcript history (.txt, .md)
- [ ] Dark mode UI refinements

**Success Metrics:**
- 10,000+ downloads
- < 1% crash rate
- Average rating > 4.5/5

---

### v1.2 (3-4 months post-launch)
**Focus:** Advanced features

**Planned Features:**
- [ ] Speaker diarization (basic, energy-based)
- [ ] Export to SRT/VTT (subtitle formats)
- [ ] Session logs with audio playback
- [ ] Integration with note-taking apps (Obsidian, Notion)
- [ ] Custom vocabulary lists (domain-specific terms)

**Success Metrics:**
- 50,000+ downloads
- Featured on MacStories or similar
- 100+ GitHub stars (if open-source)

---

### v2.0 (6+ months post-launch)
**Focus:** Platform expansion & AI features

**Planned Features:**
- [ ] iOS companion app (iPhone/iPad)
- [ ] iCloud sync for transcript history
- [ ] AI-powered summarization (local, via MLX or similar)
- [ ] Multi-language session support (auto-switch)
- [ ] Plugin architecture for third-party processors

**Success Metrics:**
- 100,000+ downloads across platforms
- Sponsorship or partnership opportunities
- Community-contributed plugins

---

## Risk Mitigation

### Technical Risks

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Whisper.cpp build issues on Xcode 16 | Medium | High | Test early, follow upstream closely, have build script fallback |
| ScreenCaptureKit API changes in macOS 16 | Low | Medium | Use compatibility checks, graceful degradation |
| Performance targets not met on M1 | Medium | Medium | Offer CPU-only mode, recommend model downgrade |
| App Store rejection (sandboxing) | Low | High | Prepare direct download version, clear entitlements |

### Schedule Risks

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Whisper integration takes longer | Medium | High | Prototype early (Week 2), adjust timeline if needed |
| Alpha testing reveals major UX issues | Medium | Medium | Allocate buffer week (Week 12.5), simplify features if necessary |
| Notarization delays | Low | Low | Start process early (Week 13), have backup plan for soft launch |

---

## Success Criteria (v1.0 Launch)

### Functional
- ✅ Mic-only transcription works with < 500ms latency
- ✅ Mode B (mic + app) captures both sources accurately
- ✅ Auto-paste functions in 90%+ of tested apps
- ✅ All 5 model sizes downloadable and usable
- ✅ Hotkeys work reliably

### Non-Functional
- ✅ App launches in < 2 seconds (cold start)
- ✅ GPU usage < 60% during streaming (small model, M4)
- ✅ Memory usage < 2 GB (with large model loaded)
- ✅ Zero network calls during transcription (verified via Little Snitch)

### User Experience
- ✅ First-time setup takes < 2 minutes (incl. permissions)
- ✅ Users can complete primary use cases without reading docs
- ✅ No P0 crashes in first week of launch
- ✅ Positive feedback from alpha testers (> 4/5 rating)

---

## Dependencies & Assumptions

### Dependencies
- Xcode 15+ available throughout development
- whisper.cpp stable API (minimal breaking changes)
- macOS 14/15 Beta access for testing
- TestFlight or direct distribution channel

### Assumptions
- Single developer (full-time) or small team (2-3 part-time)
- Access to M1/M4 Mac for testing
- Budget for code signing certificate ($99/year)
- Optional: budget for landing page hosting

---

## Appendix: Task Checklist Template

Use this for weekly planning:

```markdown
## Week X: [Phase Name]

### Goals
- [ ] Goal 1
- [ ] Goal 2

### Tasks
- [ ] Day 1: [Task]
- [ ] Day 2: [Task]
- [ ] Day 3: [Task]
- [ ] Day 4: [Task]
- [ ] Day 5: [Task]

### Blockers
- None / [List blockers]

### Completed
- [x] [Completed tasks from previous week]

### Notes
- [Any relevant notes or decisions]
```

---

**Next Steps:**
1. Review this roadmap with stakeholders
2. Set up project tracking (GitHub Projects, Jira, etc.)
3. Begin Phase 0, Week 1 tasks
4. Update PROGRESS.md weekly

---

**Document Version Control:**
- v1.0 (2025-10-21): Initial roadmap
