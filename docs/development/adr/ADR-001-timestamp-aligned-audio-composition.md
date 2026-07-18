# ADR-001: Timestamp-aligned microphone and application audio composition

- **Status:** Accepted
- **Date:** 2026-07-17

## Decision

MacTalk composes microphone and ScreenCaptureKit audio into one normalized 16 kHz mono stream. Each source owns an independent stateful resampler; a bounded timestamped composer is the only append path to ASR.

Microphone tap frames preserve the first-frame Core Audio host timestamp in the bounded owned ring. ScreenCaptureKit presentation timestamps are converted to signed nanoseconds in the same host-clock domain. The first accepted microphone timestamp anchors output frame zero; application audio received first is bounded and replayed after anchoring.

The composer waits up to 4,000 output frames (250 ms) for cross-source reordering. Missing frames become silence, source-only coverage remains unity gain, and overlapping sources are mixed at 0.5 + 0.5 with finite-value replacement and clamping. Discontinuities larger than the bounded zero-fill window are elided and counted rather than allocating unbounded silence. The pure composer exposes an explicit `tick`/expiry operation but does not infer callback lateness from media progress. `SerializedAudioCompositionPipeline` owns an injected monotonic arrival clock and cancellable scheduler, keeping one bounded expiry task; a counterpart callback cancels that task before expiry, while expiry renders available coverage and starts a new bounded window only when pending data remains.

Composition is session-scoped and serialized. Stop drains converter tails through the composer once; cancel and replacement reject old session data. Application failure drains committed dual-source time, switches to microphone-only without resetting the microphone converter or timeline, and rejects queued application callbacks.

## Rejected alternatives

Independent ASR streams and transcript merging would duplicate engine lifecycle and UI semantics. Callback-arrival time is not a media clock and would make alignment queue-schedule dependent. Sharing one resampler between sources corrupts source phase. Immediate callback-order concatenation doubles simultaneous duration and is schedule dependent. RMS/AGC normalization is history dependent and unrelated to timeline correctness.

## Validation boundary

Deterministic unit tests cover timestamp placement, lateness, bounded storage, gain, fallback, lifecycle, and callback serialization in `MacTalkTests/AudioCompositionTests.swift` and `AudioCaptureIntegrationTests.swift`. The signed Release build baseline passed, but manual validation with simultaneous acoustic/electronic impulses and an app-audio loss event was not run on this documentation baseline. Those checks validate framework/device timestamp behavior rather than pure integer math.
