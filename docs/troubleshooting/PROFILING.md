# MacTalk pipeline observability

This guide describes the privacy-safe, local diagnostics available for a
recording session. It is an observability aid, not a continuously collected
performance monitor.

## Session report

Each session report is keyed by its session ID and records dimensions for the
provider, model ID, capture mode, language, and battery mode. Terminal outcomes
are typed (`completed`, `noSpeech`, `cancelled`, `startFailed`, or
`inferenceFailed`), rather than inferred from free-form text.

Capture timing uses monotonic host-clock timestamps and distinguishes the
first accepted capture callback from the first composed audio frame. The timing
boundaries are:

- prepare start and completion;
- first accepted capture;
- first composed audio;
- inference queue, incremental inference, and final inference;
- first partial result;
- stop-to-final completion; and
- output handoff.

Incremental and final inference real-time factor is inference duration divided
by audio duration. Audio duration uses **16,000 samples per second** for the
normalized mono Float32 stream; it is not wall-clock recording duration.

Reports are bounded JSONL records written locally at
`~/Library/Logs/MacTalk/pipeline-metrics.jsonl`. The store retains at most 100
records and 512 KiB. Writes are best effort and do not block audio capture.

The report contains **no transcript text, audio samples, target application identity, or raw errors**. It is never copied automatically and is not routed through auto-paste or a network service.

## Copying a report

The status-bar diagnostics menu provides **Copy Performance Report**. The
action copies the bounded, metadata-only report to the clipboard only when the
user explicitly selects it. It does not copy transcript output or trigger
auto-paste.

## Console and signposts

Pipeline logs use subsystem `com.mactalk.app` and category `pipeline`. To view
them in Console:

```bash
log stream --predicate 'subsystem == "com.mactalk.app" AND category == "pipeline"' --level info
```

The Instruments signposts are `TranscriptionSession`, `Inference`,
`FirstAudio`, `FirstComposedAudio`, and `FirstPartial`. Use them to inspect
session boundaries and latency without persisting content.

CPU and GPU figures are **Instruments measurements**, not continuously
collected runtime metrics. Use Time Profiler, Allocations, Metal System Trace,
or Energy Log for an investigation; do not treat a report as a CPU or memory
monitor.

## Hardware validation

Hardware validation is **bounded asynchronous hardware validation**: it is
opt-in, records metadata only (timestamps, sample counts, and typed results),
and uses a bounded pending queue. It never records audio or application
identity. Stream failures are represented by the typed `stream_error` outcome.

The deterministic and hosted Thread Sanitizer lanes use injected drivers and
sinks, and do not require TCC, capture hardware, models, or the network. The policy is no flaky absolute hosted performance threshold; hosted TSan validates
race safety and deterministic behavior, while Instruments is used for actual
performance measurements.
