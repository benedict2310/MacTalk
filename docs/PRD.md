# Product Requirements Document — MacTalk

## Mac-native Swift App for Local Voice Transcription (Whisper)

**Version:** 1.0
**Last Updated:** 2025-10-21
**Status:** Planning Phase

---

## 0. Summary

Build a Swift/macOS app that performs on-device transcription with Whisper and outputs results:
1. Directly at the current cursor (optional simulated paste)
2. To the clipboard

**Two capture modes:**
- **Mode A** — Microphone Only
- **Mode B** — "Input + Output Channel" (e.g., transcribe a call: mic + selected app/system audio)

All audio stays local. Use native macOS frameworks for capture/UI; integrate whisper.cpp (Metal) for inference.

---

## 1. Goals & Non-Goals

### Goals
- Near-real-time streaming transcription using Whisper
- Single-click toggle between Mic only and Mic + App/System audio
- Output to clipboard and optionally auto-paste at cursor
- App-store friendly posture (respect permissions; no private APIs)

### Non-Goals
- Cloud transcription
- Complex text editing beyond basic punctuation/auto-casing
- Speaker diarization (v1) — Consider later via VAD + energy-based channel hints

---

## 2. Primary Use Cases / User Stories

1. **Dictation anywhere:**
   "As a user, I press a hotkey, speak, and my words appear in the active text field; the transcript is also copied to clipboard."

2. **Call/meeting notes:**
   "As a user, I select 'Mic + App Audio', pick Zoom/FaceTime (or 'system audio'), and get a combined transcript in real time and a final cleaned transcript on stop."

3. **Hands-free mode:**
   "As a user, I want start/stop via global hotkey and visual HUD without switching windows."

---

## 3. User Experience (UX)

### 3.1 Surface

**Menu Bar App with:**
- Toggle: Mic only / Mic + App Audio
- Model selector: tiny/base/small/medium/large-v3/large-v3-turbo (quantized)
- Language auto / manual
- Auto-paste on/off
- Auto-punctuation & casing on/off
- Streaming partials on/off
- Noise/VAD on/off (basic)
- Last transcript preview; Copy / Save .txt / Clear
- Permissions status badges (Mic / Screen Recording / Accessibility)

**HUD Overlay (small floating panel):**
- Level meters per channel (Mic, App/System)
- Live partial transcript (single line)
- Start/Stop button + hotkey hint

### 3.2 Flows

**Start (Mic only):**
1. Hotkey pressed
2. Capture begins
3. Partials stream (optional)
4. On Stop → final transcript cleaned
5. Placed to clipboard
6. If enabled, Cmd-V simulated
7. HUD confirmation

**Start (Mic + App audio):**
1. User picks app/output in a sheet (ScreenCaptureKit picker)
2. Capture begins → mixed stream
3. Partials displayed
4. Stop → final transcript
5. Clipboard + (optional) paste

---

## 4. Functional Requirements

### 4.1 Audio Capture
- **Mic:** AVAudioEngine input node
- **App/System output:** ScreenCaptureKit (SCShareableContent + SCContentFilter + SCStream with capturesAudio = true) to capture a specific app, window, or display audio
- Provide a selector UI for apps/windows/displays
- Respect Screen Recording permission prompts

### 4.2 Mixing & Pre-processing
- AVAudioEngine graph with AVAudioMixerNode to combine mic (ch1) + app/system (ch2)
- Downmix to mono and resample to Whisper's expected format (e.g., PCM 16-kHz)
- Use AVAudioConverter
- **Optional VAD (lightweight):** WebRTC VAD (C library) to gate inference and punctuation; fallback to energy threshold if disabled

### 4.3 Whisper Inference
- Integrate whisper.cpp as a static library (Metal backend enabled)
- Support quantized GGML/GGUF models (e.g., Q5_0, Q8_0)
- **Streaming mode:** chunked inference (e.g., 0.5–1.0s windows) for partials; stitch with timestamps
- **Finalization:** when stopped or VAD silence tail, run a final pass for cleanup (timestamps → text, punctuation)

### 4.4 Output
- Always copy to clipboard (NSPasteboard)
- **If Auto-paste is enabled:**
  - Set clipboard, then simulate ⌘V via Accessibility/Quartz Events after verifying AXIsProcessTrusted
  - If not trusted or paste fails, show non-blocking notification with "Press ⌘V to paste"

### 4.5 Localization & Punctuation
- Language auto-detect (Whisper) with manual override menu
- Optional lightweight post-process for capitalization and sentence punctuation (rule-based), configurable

### 4.6 Hotkeys
- Global Start/Stop (user-configurable), registered via EventKit/Carbon hotkey APIs (or MAS-safe alternative)

### 4.7 Logging
- Local only: session start/stop, model, mode, durations, WER proxy (if ground truth provided in dev mode), errors

---

## 5. Non-Functional Requirements (Targets)

- **Latency (streaming partials):** < 300–500 ms perceived delay for short utterances (M4, small/medium model)
- **End-of-utterance finalization:** < 2s for typical sentence
- **CPU/GPU usage:** keep GPU < 60% on M4 during streaming with small/medium models; adaptive throttling when battery powered
- **Memory:** keep model + buffers within user-selected tier
- **Privacy:** no network calls for transcription; all local
- **Stability:** survive device changes (BT mic unplugged), resume gracefully

---

## 6. Architecture (High-Level)

```
[Hotkey/UI]
   → [Capture Controller]
       - Mic: AVAudioEngine.inputNode
       - App/System: ScreenCaptureKit SCStream (audio)
   → [Audio Mixer Graph]
       - AVAudioMixerNode (mic/app)
       - AVAudioConverter (mono 16 kHz)
   → [Ring Buffer / Chunker]
   → [Whisper Engine (whisper.cpp, Metal)]
       - Streaming decode (partials)
       - Final pass (cleanup)
   → [Post-Processor]
       - punctuation/casing (optional)
   → [Output Manager]
       - NSPasteboard setString
       - (optional) Accessibility-driven ⌘V
   → [HUD + Menu Bar UI]
```

### Threads
- **Audio IO:** real-time
- **Inference:** dedicated queue (back-pressure aware)
- **UI:** main thread; throttled updates

---

## 7. Dependencies & Tech Choices

- **Whisper Inference:** whisper.cpp (Metal enabled). Ship as vendored submodule, build via Xcode script
- **Audio Capture & Mixing:** AVFoundation (AVAudioEngine, AVAudioMixerNode, AVAudioConverter)
- **App/System Audio:** ScreenCaptureKit for selecting and capturing app/display audio with audio samples
- **VAD (optional):** WebRTC VAD (C) or simple RMS gate
- **UI:** AppKit + Menu Bar extra (NSStatusBar) + HUD (borderless NSWindow)
- **Hotkeys:** MAS-compatible global hotkey library or Carbon fallback
- **Accessibility:** AX APIs for simulated paste (user-granted)

---

## 8. Model Management (Whisper)

**Models offered:**
- tiny / base / small / medium / large-v3 / large-v3-turbo (quantized variants: Q5_0, Q8_0)

**Download on first use** with checksum; store in `Application Support/MacTalk/Models/`

**Guidance in UI:**
- "Faster (tiny/base) → lower accuracy"
- "Balanced (small/medium)"
- "Highest accuracy (large-v3/turbo) → higher latency/memory"

**Rough size order-of-magnitude (Q5_0):**
- tiny: <100 MB
- base: ~150 MB
- small: ~500 MB
- medium: ~1–1.5 GB
- large-class: ~2–3+ GB

Language packs not required (multi-lingual models), but allow forcing language.

---

## 9. Permissions & Compliance

**Required Permissions:**
- **Microphone** (NSMicrophoneUsageDescription)
- **Screen Recording** (for ScreenCaptureKit audio of apps/system)
- **Accessibility** (to simulate ⌘V)

**Legal:**
Warn users about one-/two-party consent for call recording/transcription; show a one-time "I understand" gate for Mode B.

---

## 10. Settings

**Defaults:**
- Default mode: Mic only
- Auto-paste: off by default
- Streaming partials: on by default
- Model default: small (Q5_0)
- Language: auto
- Auto-punctuation: on

---

## 11. Performance Strategy

- Prefer Q5_0 quant for speed; let advanced users pick Q8_0 for quality
- Enable Metal path in whisper.cpp
- Use short chunks (e.g., 512–1000 ms) with overlap to reduce hallucinations
- VAD gating to avoid decoding silence
- **Back-pressure:** if inference falls behind, drop oldest partial chunk (never the latest) to keep latency tight
- **Battery saver:** reduce chunk rate or switch to a smaller model when on battery (optional setting)

---

## 12. Telemetry / Metrics (local only)

- Session duration, WPM, partial latency, finalization latency
- Model/mode used; average CPU/GPU utilization (coarse)
- Error counts (permission denied, device change)
- Export debug log for support (user-opt in)

---

## 13. Testing & Acceptance Criteria

### Functional
- **Mic-only:** Speak a sentence → partials visible within ≤500 ms; final text appears on Stop; clipboard updated
- **Auto-paste enabled:** Focused text field receives pasted string; if Accessibility not granted, user is prompted and paste is skipped gracefully
- **Mode B:** Select Zoom app audio + mic; both channels present (level meters show activity); transcript includes remote speaker words
- **Language auto-detect** works for English/German; manual override forces language
- **Model switch** works at runtime (with stop/restart)

### Performance
- With small (Q5_0) on M4, maintain partial latency ≤500 ms for typical dictation
- Finalization ≤2s for 10-second utterance

### Resilience
- Handle mic unplug gracefully (UI warning, auto-retry)
- If ScreenCaptureKit selection disappears (app closed), fall back to mic-only with toast

### Security/Privacy
- No network calls during transcription
- Permissions prompts appear only when needed

---

## 14. Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| Capturing "system audio" can require Screen Recording permission and user selection; some apps may restrict capture | Provide clear selection UI and guidance; fall back to mic-only |
| Auto-paste robustness varies by target app | Provide clipboard-only fallback; show clear status |
| Latency spikes on large models | Recommend smaller models for live dictation; allow post-processing final pass with larger model (future option) |
| Legal compliance for calls | Mandatory consent notice + per-session reminder when Mode B is used |

---

## 15. Release Plan

### v1.0 (MVP)
- Mic-only + Mic+App audio via ScreenCaptureKit
- Streaming partials, final transcript, clipboard + optional paste
- Model selector (tiny..medium + large-v3-turbo)
- Basic VAD, punctuation
- Menu bar UI + HUD

### v1.1
- Per-app presets (model, language)
- Basic command vocabulary (e.g., "new line", "comma")

### v1.2
- Saved session logs; export SRT/VTT
- Simple diarization heuristic (energy-based by channel)

---

## 16. Open Questions (track for v1)

- Provide a system-wide "Paste on Stop" timeout (e.g., paste only if stop < 2s old)?
- Offer per-app exception list (never auto-paste into password fields)?
- Optional final pass with larger model after streaming finishes for accuracy boosts?

---

## 17. Definition of Done (DoD)

- All acceptance criteria in §13 met on macOS 14+ (Sonoma/Sequoia), Apple Silicon (M1+), optimized for M4
- No network access during transcription; all third-party notices included
- App notarized; permissions flows verified on a clean user profile
- Measured metrics (latency/CPU/GPU) documented for each model tier
