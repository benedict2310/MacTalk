# MacTalk architecture (current)

**Evidence date:** 2026-07-18
**Source of truth:** Swift sources under `MacTalk/MacTalk`, `project.yml`, and
`MacTalk.xcodeproj` generated from it. This document describes the current
implementation, not the historical stories in `docs/stories/`.

## Boundaries

MacTalk is an AppKit menu-bar application. `main.swift` creates the
`NSApplication` and `AppDelegate`; `AppDelegate` composes the status bar,
settings, HUD, permission, model, engine, and output coordinators. There is no
SwiftUI application entry point.

```
AppKit (menu bar, settings, HUD)
              |
       StatusBarController
              |
  coordinators / TranscriptionController
       |                  |
 audio capture       engine lifecycle
       |             /                \
 timeline composer  NativeWhisperEngine  ParakeetEngine
       |             |                  |
 16 kHz mono        whisper.cpp/Metal    FluidAudio 0.15.5
              |
 clipboard + optional Accessibility insertion
```

The project defines two providers in `ASREngine.swift`: `.whisper` and
`.parakeet`. `ASREngine` is the provider-neutral boundary with `prepare`,
`reset`, incremental `process`, and terminal `finalize`. The controller does
not own a concrete Whisper-only API.

## Ownership and lifecycle

- **`StatusBarController`** is the AppKit composition root. It wires
  `EngineLifecycleCoordinator`, `RecordingSessionCoordinator`, permission and
  output coordinators, settings observation, menu presentation, and model
  download effects.
- **`EngineLifecycleCoordinator`** is the sole owner of the loaded engine and
  the complete `(provider, modelID, revision)` identity. It resolves only
  already-available engines. `ModelDownloadCoordinator` owns download
  requirements and clients; engine resolution never silently downloads.
- **`TranscriptionController`** owns one recording session's capture, timeline,
  audio buffers, chunk/final ordering, and session gates. `AudioSessionGate` and
  `appAudioGate` reject callbacks from stopped or replaced sessions.
- **`AppSettings`** owns the synchronized persisted `SettingsSnapshot`.
  `snapshotAtRecordingStart()` is latched for a recording, so settings edits
  affect the next session rather than mutating active inference.
- **`RecordingSessionCoordinator`** owns status-bar recording intent and
  delegates actual audio/inference lifecycle to the controller. UI coordinators
  do not reach into engine internals.

State transitions are serialized at their ownership boundary. A provider/model
change while recording is deferred until idle; a failed app-audio stream
preserves committed microphone timeline and falls back to mic-only.

## Audio timeline and concurrency

`AudioCapture` copies render data into a bounded preallocated handoff. The
render callback does not allocate, lock, enqueue Foundation audio objects, or
invoke application code. A worker owns the copied `AudioCaptureFrame` and
invokes the session callback after the real-time callback returns. Overflow
increments a diagnostic counter and drops the newest frame.

`ScreenAudioCapture` supplies app/system CMSampleBuffers. Each source has an
independent conversion state. `SerializedAudioCompositionPipeline` is the sole
append path for microphone and app audio. `TimestampedAudioComposer` aligns
host-clock timestamps, waits at most 4,000 output frames (250 ms) for bounded
reordering, fills missing coverage with silence, and mixes overlap at 0.5 +
0.5 with finite-value replacement and clamping. Stop drains converter tails
once. The timestamp-aligned composition decision is recorded in
[ADR-001](adr/ADR-001-timestamp-aligned-audio-composition.md).

The normalized stream is 16 kHz, mono, Float32. The controller keeps bounded
chunk and final-audio state (10 minutes maximum), schedules incremental work
serially, and validates the session ID before and after conversion. Whisper uses
incremental processing; Parakeet's provider flag disables overlapping
incremental/final requests because FluidAudio's shared manager must not be
called concurrently in those paths. UI callbacks are `@MainActor` callbacks.

No current production type named `RingBuffer` is used; the former generic
ring-buffer API was removed. Do not copy the obsolete snippets from historical
stories into new code.

## Engine and model trust

`NativeWhisperEngine` validates the selected model at the native boundary and
uses the whisper.cpp bridge. `ParakeetEngine` is selected through FluidAudio
and its pinned model revision. `ModelCatalog` records Whisper filename, size,
SHA-256, source, immutable revision, and URLs. Downloaders stage files and
verify integrity before installation; the mirror URL is a byte-source fallback,
not a provenance authority. A real model is never implicit in deterministic
unit tests.

The model, provider, and revision are carried together through
`EngineSelection`; UI must not display Whisper state for a Parakeet selection or
vice versa. A missing model produces a download requirement/effect. A stale or
cancelled load cannot replace a newer selection.

## Privacy and output

Transcription is local after the selected model is provisioned. The source
contains URLSession model downloaders, so the stronger claim “the app has no
network code” is false. Deterministic tests inject network traps and do not
contact providers. The opt-in debug logger is disabled unless
`MACTALK_DEBUG_LOGGING=1` (or the debug argument) is present; rendered messages
contain event names and character counts, not transcript/error text. Production
`print` diagnostics still exist in a few lifecycle paths and must not be
interpreted as a privacy audit.

Output is owned by `OutputCoordinator`: it writes the final cleaned transcript
to `NSPasteboard` and, when enabled and trusted, delegates insertion to
`AutoInsertManager` (Accessibility API with a Cmd-V fallback). Accessibility
is not required for clipboard-only output. Permission state is checked before
requesting or enabling auto-paste.

## Settings and UI flow

`AppSettings` persists provider, Whisper model ID, optional language, capture
mode, notifications, and auto-paste in `UserDefaults` under a lock, posts
`settingsDidChange`, and migrates legacy keys. `SettingsWindowController` edits
this store. `StatusBarController` observes the notification on the main queue;
engine lifecycle receives an immutable snapshot and prewarms only while idle.
The HUD receives controller partial/final and level callbacks on MainActor.

## Build evidence

The reproducible configuration is in `project.yml`: macOS 26.0 deployment,
Swift 6.0 strict concurrency, DebugTSan configuration, and exact FluidAudio
0.15.5. Current command-level results are recorded in
[`docs/STATUS.md`](../STATUS.md). Do not infer support for another macOS,
Xcode, hardware model, model artifact, or notarization state from this
architecture document.
