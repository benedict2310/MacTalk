# MacTalk architecture (current)

**Evidence date:** 2026-07-26
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

`GeneratedModelProvenance.swift` is generated from the canonical lock and
checked-in immutable evidence described in
[`MODEL_PROVENANCE.md`](../security/MODEL_PROVENANCE.md). `ModelCatalog` records
Whisper filename, size, SHA-256, source, immutable revision, and URLs.
Production Whisper and Parakeet transfers share `BoundedModelDownloadTransport`;
download managers stage and verify bytes before publication. A mirror is a
byte-source fallback, never a provenance authority.

`NativeWhisperEngine` revalidates the selected Whisper artifact at the native
boundary before using the whisper.cpp bridge. Parakeet production composition
prepares the canonical source store, obtains a descriptor-backed
`VerifiedParakeetSourceSnapshot`, and constructs CoreML assets from verified
owned bytes through `VerifiedParakeetModelLoader`. The consumer handle retains
the complete snapshot and assets for its exact manager generation. Production
contains no compiled/path-based Parakeet loading fallback.

After a source manager is successfully published,
`ParakeetLegacyCompiledCleaner` best-effort retires an exactly validated legacy
compiled generation under exclusive store ownership. Cleanup failure is
retryable and does not discard the ready source manager or authorize legacy
loading. The detailed trust and solo-maintainer governance boundaries are
recorded in the provenance document.

The model, provider, and revision are carried together through
`EngineSelection`; UI must not display Whisper state for a Parakeet selection or
vice versa. A missing model produces a download requirement/effect. Generation
ownership prevents a stale or cancelled load from replacing a newer selection.
A real model is never implicit in deterministic unit tests.

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

## Pipeline observability

`PipelineSessionRecorder` owns one metadata-only report per session. Its
session dimensions include provider, model ID, capture mode, language, and
battery mode. Typed terminal outcomes are `completed`, `noSpeech`, `cancelled`,
`startFailed`, and `inferenceFailed`; transcript content is never part of a
report.

Capture and composition are separate boundaries: the first accepted capture
callback identifies capture arrival, while the first composed audio frame
identifies timestamp-aligned mixed output. Session timing also marks prepare,
queue, incremental inference, final inference, first partial, stop-to-final,
and output-handoff boundaries. Real-time factor is inference duration divided
by audio duration, using 16,000 samples per second for the normalized stream.

`PipelineMetricsStore` writes bounded JSONL locally to
`~/Library/Logs/MacTalk/pipeline-metrics.jsonl`, retaining at most 100 records
and 512 KiB. The privacy boundary contains no transcript text, audio samples, target
application identity, or raw errors. The status-bar action **Copy
Performance Report** copies this metadata-only report only on explicit user
request.

The typed `com.mactalk.app` / `pipeline` logger and signposts
`TranscriptionSession`, `Inference`, `FirstAudio`, `FirstComposedAudio`, and
`FirstPartial` provide local diagnostics. CPU and GPU figures are Instruments
measurements, not continuously collected runtime metrics. Hardware validation
is bounded asynchronous hardware validation: opt-in, asynchronous, bounded,
and metadata-only. Deterministic tests use injected dependencies, while the
hosted Thread Sanitizer lane checks race safety. No flaky absolute hosted
performance threshold is enforced.

## Build evidence

The reproducible configuration is in `project.yml`: macOS 26.0 deployment,
Swift 6.0 strict concurrency, DebugTSan configuration, and exact FluidAudio
0.15.5. Current command-level results are recorded in
[`docs/STATUS.md`](../STATUS.md). Do not infer support for another macOS,
Xcode, hardware model, model artifact, or notarization state from this
architecture document.
