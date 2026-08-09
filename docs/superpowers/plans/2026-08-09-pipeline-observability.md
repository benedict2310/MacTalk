# Speech-to-Text Pipeline Observability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `subagent-driven-development` (recommended) or `executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Raise MacTalk’s local speech-to-text observability from roughly 2/5 to 4/5 with privacy-preserving per-session metrics spanning capture through clipboard/auto-insert output.

**Architecture:** Add a lock-backed, constant-time `PipelineSessionRecorder` on capture-delivery and orchestration paths and an actor-isolated `PipelineMetricsStore` that persists one bounded JSONL record only after a session ends. `TranscriptionController` owns a session-ID-keyed recorder because its awaited partial/final callbacks bracket HUD presentation and synchronous output handoff; clipboard write and insert outcomes are recorded separately, while delayed Cmd-V fallback is explicitly only “scheduled,” never claimed complete. Capture exposes a typed health snapshot, status-bar diagnostics provide a local report without remote telemetry, and unified-log signposts expose session/inference intervals to Instruments. All persisted fields are typed dimensions/counters—not audio, transcript text, target-app identity, or raw error descriptions.

**Tech Stack:** Swift 6 strict concurrency, Foundation, AppKit, `OSAllocatedUnfairLock`, `DispatchTime.uptimeNanoseconds`, `os_signpost`, XCTest, JSONEncoder/JSONDecoder, XcodeGen.

---

## File structure

- Create `MacTalk/MacTalk/Utilities/PipelineObservability.swift`: report schema, monotonic recorder, derived latency/RTF calculations, resource snapshots, signposts, store protocol, bounded JSONL store, and report formatter.
- Create `MacTalk/MacTalkTests/PipelineObservabilityTests.swift`: deterministic recorder, privacy, persistence, bounded retention, permissions, formatting, and idempotency tests.
- Modify `MacTalk/MacTalk/Audio/AudioCapture.swift`: typed capture-health snapshot available through the live capture boundary.
- Modify `MacTalk/MacTalk/Audio/AudioHardwareValidationRecorder.swift`: bounded asynchronous file delivery so diagnostics never perform filesystem I/O on capture delivery.
- Modify `MacTalk/MacTalk/TranscriptionController.swift`: create/finalize one recorder per accepted session and instrument capture, conversion, composition, buffering, queueing, inference, presentation, stop, and output boundaries.
- Modify `MacTalk/MacTalkTests/TranscriptionControllerTests.swift`: deterministic end-to-end metrics tests for Whisper, Parakeet, no-speech, cancellation, fallback, and trimming.
- Modify `MacTalk/MacTalk/StatusBar/StatusBarSystemClients.swift`: injectable diagnostics client that renders and copies the local report.
- Modify `MacTalk/MacTalk/StatusBar/StatusMenuPresenter.swift`: stable “Copy Performance Report” item.
- Modify `MacTalk/MacTalk/StatusBarController.swift`: route the diagnostics action.
- Modify `MacTalk/MacTalkTests/StatusMenuPresenterTests.swift`: menu identifier/order/action contract.
- Modify `MacTalk/MacTalkTests/StatusBarControllerTests.swift` or the nearest existing status-bar dependency test: injected report-copy behavior.
- Modify `docs/troubleshooting/PROFILING.md`: replace stale APIs with implemented report/signpost workflow and exact metric semantics.
- Modify `docs/development/ARCHITECTURE.md`: document the local-only observability boundary.
- Modify `docs/testing/TESTING.md`: document deterministic observability coverage and performance validation policy.
- Modify `scripts/ci-docs-checks.sh` and `scripts/tests/test_ci_docs_checks.sh`: require privacy and report-location contracts.

## Explicit scope

Implemented now:

- one report per accepted/cancelled/failed recording session;
- provider/model/mode/power dimensions;
- monotonic prepare, conversion, queue, inference, first accepted capture, first composed audio, first-partial, stop-to-final, synchronous output-handoff, and total timings;
- incremental and final real-time factors;
- source callback/sample counts, capture drops, conversion failures, composed output, VAD skips, final-audio trimming, fallback count, pending inference high-water mark, and composition anomaly counters;
- optional start/end resident-memory samples and `maxObservedResidentMemoryAtCheckpoints` at safe non-callback checkpoints;
- local bounded JSONL persistence with owner-only permissions;
- unified-log summary and session/inference signposts;
- menu-accessible text report copied locally;
- no transcript/audio/error descriptions or target-app identity.

Deferred deliberately:

- remote telemetry, upload, dashboards, alerts, or fleet analytics;
- continuous CPU/GPU sampling, which would add overhead and is better handled by Instruments;
- acoustic speech-onset detection. “First partial” is defined from accepted session start and separately from first composed audio, not from guessed phoneme onset;
- CI wall-clock benchmark gates on shared hosted runners. Deterministic metric semantics are blocking; hardware baselines remain controlled measurements.

### Task 1: Typed session recorder and derived metrics

**Files:**
- Create: `MacTalk/MacTalk/Utilities/PipelineObservability.swift`
- Create: `MacTalk/MacTalkTests/PipelineObservabilityTests.swift`

- [ ] **Step 1: Write failing recorder tests**

Create tests using an injected manual monotonic clock. The wished-for API is:

```swift
final class ManualPipelineClock: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: UInt64(0))
    var now: UInt64 { lock.withLock { $0 } }
    func advance(milliseconds: UInt64) {
        lock.withLock { $0 += milliseconds * 1_000_000 }
    }
}

func test_sessionRecorderCalculatesStageLatenciesAndRealTimeFactors() {
    let clock = ManualPipelineClock()
    let recorder = PipelineSessionRecorder(
        context: PipelineSessionContext(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            provider: .whisper,
            modelID: "whisper-base-q5_1",
            captureMode: .micOnly,
            language: "en",
            batteryMode: false,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        ),
        nowNanoseconds: { clock.now }
    )

    clock.advance(milliseconds: 100)
    recorder.recordMicrophoneInput(inputSamples: 4_800, convertedSamples: 1_600, conversionNanoseconds: 2_000_000)
    clock.advance(milliseconds: 20)
    recorder.recordComposedOutput(samples: 1_600)
    let inferenceID = UUID()
    recorder.recordInferenceQueued(id: inferenceID, kind: .incremental, audioSamples: 16_000)
    clock.advance(milliseconds: 25)
    recorder.recordInferenceStarted(id: inferenceID)
    clock.advance(milliseconds: 200)
    recorder.recordInferenceCompleted(id: inferenceID, succeeded: true)
    clock.advance(milliseconds: 25)
    recorder.recordPartialPresented()
    recorder.recordStopRequested()
    clock.advance(milliseconds: 300)
    recorder.recordFinalPresented()
    clock.advance(milliseconds: 5)
    recorder.recordOutputHandoff(
        clipboardWritten: true,
        insertOutcome: .notAttempted
    )

    let report = recorder.finish(
        outcome: .completed,
        capture: .zero,
        composition: .init()
    )
    XCTAssertEqual(report.latency.firstAcceptedCaptureMs, 100, accuracy: 0.001)
    XCTAssertEqual(report.latency.firstComposedAudioMs, 120, accuracy: 0.001)
    XCTAssertEqual(report.latency.firstPartialFromStartMs, 370, accuracy: 0.001)
    XCTAssertEqual(report.latency.firstPartialFromComposedAudioMs, 250, accuracy: 0.001)
    XCTAssertEqual(report.latency.stopToFinalMs, 300, accuracy: 0.001)
    XCTAssertEqual(report.latency.finalOutputHandoffMs, 5, accuracy: 0.001)
    XCTAssertEqual(report.incrementalInference.realTimeFactor, 0.2, accuracy: 0.001)
    XCTAssertEqual(report.queue.maximumDelayMs, 25, accuracy: 0.001)
}
```

Also add independent failing tests for:

- idempotent `finish` returning the same report;
- monotonic saturation when an injected clock moves backwards;
- distinct first accepted-capture and first composed-audio boundaries in dual-source mode;
- separate Whisper and Parakeet model dimensions;
- conversion failures, VAD skips, trimming, fallback, queue high-water mark, and composition counters;
- no raw transcript/error/target fields in encoded JSON.

- [ ] **Step 2: Run RED**

Run:

```bash
xcodebuild test -project MacTalk.xcodeproj -scheme MacTalk \
  -only-testing:MacTalkTests/PipelineObservabilityTests
```

Expected: compilation fails because `PipelineSessionRecorder` and report types do not exist.

- [ ] **Step 3: Run signed build/restart after the test edit**

```bash
./build.sh run
```

Expected: the app target builds and launches; the new tests remain RED until implementation.

- [ ] **Step 4: Implement the minimal typed recorder**

Define public-to-module types with no free-form sensitive payloads:

```swift
enum PipelineSessionOutcome: String, Codable, Sendable {
    case completed, noSpeech, cancelled, startFailed, inferenceFailed
}

enum PipelineInferenceKind: String, Codable, Sendable {
    case incremental, final
}

struct PipelineSessionContext: Codable, Sendable, Equatable {
    let id: UUID
    let provider: ASRProvider
    let modelID: String
    let captureMode: SettingsCaptureMode
    let language: String?
    let batteryMode: Bool
    let startedAt: Date
}

struct CaptureHealthMetrics: Codable, Sendable, Equatable {
    var microphoneDroppedBuffers: UInt64 = 0
    var microphoneCallbacks: UInt64 = 0
    var applicationCallbacks: UInt64 = 0
    var applicationLossEvents: UInt64 = 0
    static let zero = CaptureHealthMetrics()
}

struct PipelineSessionReport: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let context: PipelineSessionContext
    let outcome: PipelineSessionOutcome
    let completedAt: Date
    let latency: PipelineLatencyMetrics
    let audio: PipelineAudioMetrics
    let queue: PipelineQueueMetrics
    let incrementalInference: PipelineInferenceMetrics
    let finalInference: PipelineInferenceMetrics
    let output: PipelineOutputMetrics
    let composition: AudioCompositionMetrics
    let resources: PipelineResourceMetrics
}
```

Make `ASRProvider` and `AudioCompositionMetrics` conform to `Codable`. Implement `PipelineSessionRecorder` as `@unchecked Sendable` with all mutable state in `OSAllocatedUnfairLock`. Store integer nanoseconds and sample counts; derive milliseconds and RTF only when producing the immutable report. A finish guard caches the first report.

Recorder methods reachable from capture delivery may update primitive counters only: they must never allocate arrays, format, log, sample resources, await, invoke external code, or perform report generation while locked. Never call recorder methods while holding `audioState` or composer locks. Add a contention stress test that holds/report-finalizes on another thread while capture-delivery counter updates continue.

Use `DispatchTime.now().uptimeNanoseconds` in production. Never use `Date` for durations. Acquire battery state with `await MainActor.run { PerformanceMonitor.currentBatteryMode }`, or inject an immutable battery snapshot provider; never access the MainActor property directly from the controller.

- [ ] **Step 5: Run GREEN and signed build/restart**

Run the focused test command, then:

```bash
./build.sh run
```

Expected: all recorder tests pass and the signed app launches.

- [ ] **Step 6: Commit**

```bash
git add MacTalk/MacTalk/Utilities/PipelineObservability.swift \
  MacTalk/MacTalkTests/PipelineObservabilityTests.swift \
  MacTalk/MacTalk/Audio/TimestampedAudioComposer.swift \
  MacTalk/MacTalk/Audio/ASREngine.swift
git commit -m "Add typed pipeline session metrics"
```

### Task 2: Bounded local store, privacy, and report formatter

**Files:**
- Modify: `MacTalk/MacTalk/Utilities/PipelineObservability.swift`
- Modify: `MacTalk/MacTalkTests/PipelineObservabilityTests.swift`

- [ ] **Step 1: Write failing persistence/report tests**

Test a temporary injected file URL:

```swift
func test_storeRetainsOnlyNewestOneHundredReportsWithOwnerOnlyPermissions() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let url = directory.appendingPathComponent("pipeline-metrics.jsonl")
    let store = PipelineMetricsStore(
        fileURL: url,
        retentionLimit: 100,
        maximumFileBytes: 512 * 1024,
        maximumLineBytes: 8 * 1024
    )

    for index in 0..<105 {
        await store.record(makeReport(index: index))
    }

    let reports = await store.reports(limit: 200)
    XCTAssertEqual(reports.count, 100)
    XCTAssertEqual(reports.first?.context.id, makeID(5))
    let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
    XCTAssertEqual(mode?.intValue, 0o600)
}
```

Add tests proving:

- malformed/partial old lines are skipped rather than blocking new reports;
- oversized files are rotated/recovered without being fully loaded, and oversized lines are rejected;
- report text groups provider/model/mode separately;
- p50/p95 and failure/drop totals are correct;
- an empty store produces a useful “No completed sessions” report;
- JSON and text never contain supplied transcript, raw error, or target-app canaries;
- persistence happens only when `record` is called, never from recorder hot-path methods.

- [ ] **Step 2: Run RED and signed build/restart**

Run the focused tests and confirm failures for missing store behavior, then run `./build.sh run`.

- [ ] **Step 3: Implement the store and formatter**

Add:

```swift
protocol PipelineMetricsStoring: Sendable {
    func record(_ report: PipelineSessionReport) async
    func reports(limit: Int) async -> [PipelineSessionReport]
    func formattedReport(limit: Int) async -> String
}

actor PipelineMetricsStore: PipelineMetricsStoring {
    static let shared = PipelineMetricsStore()
    static let defaultURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/MacTalk", isDirectory: true)
        .appendingPathComponent("pipeline-metrics.jsonl")
}
```

On each completed session, validate that the app-owned directory and metrics file are not symlinks and are owned by the current user; reject an insecure pre-existing path before any read or replacement. Read at most `maximumFileBytes` from the tail of the JSONL file, reject lines over `maximumLineBytes`, decode valid records, append one report, keep the newest 100, and atomically replace the file. Rotate/recover an oversized or line-hostile regular file rather than loading it in full. Create the temporary replacement with `0600`, then verify `0600` after replacement; create the app-owned directory with `0700`. File work remains actor-isolated and occurs only after capture/inference/output handoff completes.

The formatter must show schema/version, report location, observation count, dimensions, p50/p95 first-partial and stop-to-final latency, incremental/final RTF, capture drops, conversion failures, composition anomalies, VAD skips, trimming, fallback, and failure outcomes. Percentiles use nearest rank (`max(0, ceil(p * n) - 1)`) over only reports that contain that metric; cancelled/failed/no-speech reports still contribute to outcome counts but not a missing latency distribution. Render `n/a` when no eligible values exist. Do not include session target identity or transcript-derived counts.

- [ ] **Step 4: Run GREEN and signed build/restart**

Run focused tests and `./build.sh run`.

- [ ] **Step 5: Commit**

```bash
git add MacTalk/MacTalk/Utilities/PipelineObservability.swift \
  MacTalk/MacTalkTests/PipelineObservabilityTests.swift
git commit -m "Persist bounded local performance reports"
```

### Task 3: Instrument the controller end to end

**Files:**
- Modify: `MacTalk/MacTalk/TranscriptionController.swift`
- Modify: `MacTalk/MacTalk/Audio/AudioCapture.swift`
- Modify: `MacTalk/MacTalk/StatusBar/RecordingSessionCoordinator.swift`
- Modify: `MacTalk/MacTalk/StatusBar/ProductionRecordingSession.swift`
- Modify: `MacTalk/MacTalkTests/TranscriptionControllerTests.swift`
- Modify: `MacTalk/MacTalkTests/RecordingSessionCoordinatorTests.swift`
- Modify: `MacTalk/MacTalkTests/DeterministicHarness.swift`

- [ ] **Step 1: Write failing deterministic pipeline tests**

Add an actor test sink:

```swift
actor RecordingPipelineMetricsStore: PipelineMetricsStoring {
    private(set) var recorded: [PipelineSessionReport] = []
    func record(_ report: PipelineSessionReport) { recorded.append(report) }
    func reports(limit: Int) -> [PipelineSessionReport] { Array(recorded.suffix(limit)) }
    func formattedReport(limit: Int) -> String { "test" }
}
```

Use the existing `DeterministicManualScheduler` so tests control timestamps exactly. Construct the recorder with `nowNanoseconds: { scheduler.nowNanoseconds }`, and coordinate timestamp advances with deterministic ASR barriers. Add focused tests proving:

- Whisper records prepare, first audio, incremental queue delay/inference/RTF, first presented partial, stop-to-final, output completion, and completed outcome;
- Parakeet records no incremental inference and a separate final RTF under model ID `parakeet`;
- silent finalization records `.noSpeech` and VAD skip without text;
- mic-start failure, missing app source, app-start failure, prepare failure, public cancellation, app-owner cleanup’s cancel-plus-stop sequence, duplicate stop, stop-then-restart before tail drain, and replacement start each write exactly one correctly attributed cancelled/failed report;
- application loss increments fallback/loss but preserves mic-only completion;
- final-audio cap removal increments trimmed samples;
- capture-drop snapshot and `AudioCompositionMetrics` are copied at finish;
- no report is written before finalization or cancellation.

- [ ] **Step 2: Run RED and signed build/restart**

Run:

```bash
xcodebuild test -project MacTalk.xcodeproj -scheme MacTalk \
  -only-testing:MacTalkTests/TranscriptionControllerTests
```

Confirm expected failures, then run `./build.sh run`.

- [ ] **Step 3: Expose typed capture health**

Extend the capture protocol without exposing implementation objects:

```swift
protocol TranscriptionCaptureSession: AnyObject {
    var healthSnapshot: CaptureHealthMetrics { get }
    // existing lifecycle methods
}

extension TranscriptionCaptureSession {
    var healthSnapshot: CaptureHealthMetrics { .zero }
}
```

`LiveTranscriptionCaptureSession.healthSnapshot` returns the microphone drop count. Controller-owned recorder events count accepted microphone/application callbacks and application-loss events, avoiding mutable callback counters in ScreenCaptureKit.

- [ ] **Step 4: Add one recorder per session**

Inject the store:

```swift
init(
    engine: any ASREngine,
    captureSession: any TranscriptionCaptureSession = LiveTranscriptionCaptureSession(),
    settings: AppSettings = .shared,
    scheduler: any TranscriptionScheduler = DispatchTranscriptionScheduler(),
    metricsStore: any PipelineMetricsStoring = PipelineMetricsStore.shared
)
```

Store recorders in a session-ID-keyed lifecycle owner. Its invariant is: `finish(sessionID:outcome:)` atomically removes (“takes”) a recorder exactly once; duplicate stop/cancel/failure paths are no-ops. Before replacement `start`, invalidate callbacks, cancel prior work, atomically take the displaced recorder, and persist it as cancelled before installing the new session. Durable persistence is guaranteed through explicit application/session cleanup, which already calls `cancelStart` before releasing the controller; test that cleanup path. `deinit` cannot await the actor store and therefore may only atomically close signposts and perform a documented best-effort nonblocking enqueue—never claim crash/forced-termination durability. Create a recorder only after provider/settings validation, with:

```swift
let modelID = recordingSettings.provider == .whisper
    ? recordingSettings.whisperModelID
    : "parakeet"
```

Record engine prepare/reset duration, accepted callback input/output samples and conversion duration/failure, composed samples at the sole emit closure, and final capture/composition snapshots. Wire the recorder clock explicitly to `timingScheduler.nowNanoseconds`. Obtain the battery dimension through a MainActor/injected immutable snapshot before recorder creation.

- [ ] **Step 5: Instrument queueing, inference, UI, and output**

For every chunk, create one inference UUID at task creation. Record queue time before awaiting `previousTask`, start after the await, completion in `defer`, and current pending-task high-water mark. Record audio samples submitted separately for incremental/final RTF.

Change `throttledUIUpdate` to return whether it invoked `onPartial`; after the awaited callback returns, mark first partial presented. Change the final callback contract across `TranscriptionController`, `TranscriptionSession`, `ProductionTranscriptionSession`, test fakes, and `RecordingSessionCoordinator` from `(String) -> Void` to `(String) -> OutputResult?`. Make `RecordingSessionCoordinator.receiveFinal` return the exact synchronous `OutputResult` it emits, or `nil` for a stale/rejected final. Around awaited `onFinal`, mark final presentation before invocation and synchronous output handoff after it returns. Map `OutputResult.clipboardWritten` and `insertOutcome` into typed `PipelineOutputMetrics`; a `nil` result is a rejected handoff. A `.cmdVFallback` outcome means delayed paste was scheduled/unverified; never name or report it as paste completion. Add contract tests for success, stale `nil`, target change, permission denial, and Cmd-V scheduling. `stop()` records stop request before shutdown.

Finalize and persist exactly once after output and before `onFinalizationComplete`. Start failures and cancellation finalize with typed outcomes; inference errors increment a typed count without retaining descriptions.

- [ ] **Step 6: Add low-overhead resource checkpoints and signposts**

Capture optional resident memory at session start, after inference completion, and finalization—never on capture callbacks—through an injected sampler. Name the derived field `maxObservedResidentMemoryAtCheckpoints`; do not call it peak memory. Emit:

```swift
os_signpost(.begin, log: PipelineSignposts.log, name: "TranscriptionSession", signpostID: sessionSignpostID)
os_signpost(.event, log: PipelineSignposts.log, name: "FirstAudio", signpostID: sessionSignpostID)
os_signpost(.event, log: PipelineSignposts.log, name: "FirstPartial", signpostID: sessionSignpostID)
os_signpost(.end, log: PipelineSignposts.log, name: "TranscriptionSession", signpostID: sessionSignpostID)
```

Use separate generated signpost IDs for overlapping inference intervals. Signpost messages contain provider/model/mode and numeric durations only.

- [ ] **Step 7: Run GREEN, focused regressions, and signed build/restart**

Run:

```bash
xcodebuild test -project MacTalk.xcodeproj -scheme MacTalk \
  -only-testing:MacTalkTests/PipelineObservabilityTests \
  -only-testing:MacTalkTests/TranscriptionControllerTests \
  -only-testing:MacTalkTests/ConcurrencyStressTests \
  -only-testing:MacTalkTests/AudioCompositionTests
./build.sh run
```

Expected: all focused tests pass; app builds, launches, and capture hot paths perform no persistence.

- [ ] **Step 8: Commit**

```bash
git add MacTalk/MacTalk/TranscriptionController.swift \
  MacTalk/MacTalk/Audio/AudioCapture.swift \
  MacTalk/MacTalk/StatusBar/RecordingSessionCoordinator.swift \
  MacTalk/MacTalk/StatusBar/ProductionRecordingSession.swift \
  MacTalk/MacTalkTests/TranscriptionControllerTests.swift \
  MacTalk/MacTalkTests/RecordingSessionCoordinatorTests.swift \
  MacTalk/MacTalkTests/DeterministicHarness.swift
git commit -m "Instrument transcription sessions end to end"
```

### Task 4: Remove hardware-recorder observer effect

**Files:**
- Modify: `MacTalk/MacTalk/Audio/AudioHardwareValidationRecorder.swift`
- Modify: `MacTalk/MacTalkTests/PipelineObservabilityTests.swift`

- [ ] **Step 1: Write failing bounded asynchronous-writer tests**

Inject a scheduler and sink seam. Prove that `recordMicrophone` returns without calling the sink, scheduled work writes later, pending work is bounded, overflow increments a diagnostic-drop count, and resulting CSV still excludes samples/transcript content. Also prove a caller-supplied existing parent directory is never chmodded.

```swift
func test_hardwareRecorderNeverWritesSynchronouslyFromCaptureDelivery() {
    let scheduler = ManualDiagnosticsScheduler()
    let sink = RecordingDiagnosticsSink()
    let recorder = AudioHardwareValidationRecorder(
        sink: sink,
        schedule: scheduler.schedule,
        maximumPendingRecords: 2
    )

    recorder.recordMicrophone(sessionID: UUID(), hostNanoseconds: 10, sampleCount: 160)
    XCTAssertTrue(sink.lines.isEmpty)
    scheduler.runNext()
    XCTAssertEqual(sink.lines.count, 1)
}
```

- [ ] **Step 2: Run RED and signed build/restart**

Run `PipelineObservabilityTests`, confirm synchronous behavior fails the test, then run `./build.sh run`.

- [ ] **Step 3: Implement bounded asynchronous delivery**

Capture only primitive metadata at the call site. Under a small lock, reject when pending count equals the configured bound. Schedule formatting/open/seek/write/close on the existing utility queue and decrement pending count in `defer`. Keep recorder disabled unless the environment variable is present. Set a newly created log file to `0600`. Only create/chmod `0700` for a recorder-owned new directory; never chmod a pre-existing caller-supplied parent. Reject symlinked/insecure output files rather than following them. Sanitize application-loss output to a typed `stream_error` result rather than raw error text.

- [ ] **Step 4: Run GREEN and signed build/restart**

Run focused tests and `./build.sh run`.

- [ ] **Step 5: Commit**

```bash
git add MacTalk/MacTalk/Audio/AudioHardwareValidationRecorder.swift \
  MacTalk/MacTalkTests/PipelineObservabilityTests.swift
git commit -m "Make hardware diagnostics nonblocking"
```

### Task 5: User-accessible local performance report

**Files:**
- Modify: `MacTalk/MacTalk/StatusBar/StatusBarSystemClients.swift`
- Modify: `MacTalk/MacTalk/StatusBar/StatusMenuPresenter.swift`
- Modify: `MacTalk/MacTalk/StatusBarController.swift`
- Modify: `MacTalk/MacTalkTests/StatusMenuPresenterTests.swift`
- Modify: `MacTalk/MacTalkTests/StatusBarControllerTests.swift` (add a dedicated complete `StatusBarDependencies` fake fixture)

- [ ] **Step 1: Write failing menu and client tests**

Require stable item ID `application.performanceReport`, title `Copy Performance Report`, and selector `StatusBarController.copyPerformanceReport`. Add a dedicated complete `StatusBarDependencies` fake fixture (none currently exists), inject a fake diagnostics client, and prove one invocation occurs. Update every direct `StatusBarDependencies` construction site or provide an explicit diagnostics default only where production behavior remains unambiguous.

Desired boundary:

```swift
@MainActor
protocol PipelineDiagnosticsClient: AnyObject {
    func copyPerformanceReport() async -> Bool
}

@MainActor
final class SystemPipelineDiagnosticsClient: PipelineDiagnosticsClient {
    private let store: any PipelineMetricsStoring
    init(store: any PipelineMetricsStoring = PipelineMetricsStore.shared) { self.store = store }

    func copyPerformanceReport() async -> Bool {
        let report = await store.formattedReport(limit: 20)
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(report, forType: .string)
    }
}
```

- [ ] **Step 2: Run RED and signed build/restart**

Run status menu/controller focused tests, confirm missing item/client failures, then run `./build.sh run`.

- [ ] **Step 3: Implement the injected action**

Add the diagnostics client to `StatusBarDependencies.live`, add the menu item adjacent to Settings/Permissions, and route:

```swift
@objc func copyPerformanceReport() {
    Task { @MainActor [weak self] in
        guard let self else { return }
        let copied = await dependencies.pipelineDiagnostics.copyPerformanceReport()
        if !copied { NSSound.beep() }
    }
}
```

Do not route this report through transcription output or auto-paste.

- [ ] **Step 4: Run GREEN and signed build/restart**

Run focused tests and `./build.sh run`.

- [ ] **Step 5: Commit**

```bash
git add MacTalk/MacTalk/StatusBar/StatusBarSystemClients.swift \
  MacTalk/MacTalk/StatusBar/StatusMenuPresenter.swift \
  MacTalk/MacTalk/StatusBarController.swift \
  MacTalk/MacTalkTests/StatusMenuPresenterTests.swift \
  MacTalk/MacTalkTests/StatusBarControllerTests.swift
git commit -m "Expose local pipeline performance reports"
```

### Task 6: Documentation contracts and complete validation

**Files:**
- Modify: `docs/troubleshooting/PROFILING.md`
- Modify: `docs/development/ARCHITECTURE.md`
- Modify: `docs/testing/TESTING.md`
- Modify: `scripts/ci-docs-checks.sh`
- Modify: `scripts/tests/test_ci_docs_checks.sh`

- [ ] **Step 1: Write failing documentation contract fixtures**

Require documentation to state:

- local-only, no remote upload;
- exact JSONL location `~/Library/Logs/MacTalk/pipeline-metrics.jsonl`;
- no transcript/audio/target identity/raw errors;
- monotonic timing and metric definitions;
- report menu action and `log stream`/Instruments signpost commands;
- hardware validation recorder is bounded and asynchronous;
- shared hosted CI does not enforce absolute performance thresholds.

Delete one required phrase in a fixture and prove `scripts/ci-docs-checks.sh` fails.

- [ ] **Step 2: Run RED and signed build/restart**

Run:

```bash
bash scripts/tests/test_ci_docs_checks.sh
```

Confirm the new contract fails, then run `./build.sh run`.

- [ ] **Step 3: Correct documentation**

Replace stale `measureAsync` and missing-`await` examples with the actual menu/store/signpost workflow. Clearly distinguish implemented runtime metrics from Instruments-only CPU/GPU profiling and from controlled hardware baselines.

- [ ] **Step 4: Run GREEN and signed build/restart**

Run docs fixtures/checks, then `./build.sh run`.

- [ ] **Step 5: Run complete validation**

```bash
xcodebuild test -project MacTalk.xcodeproj -scheme MacTalk
bash scripts/tests/test_ci_workflow_semantics.sh
bash scripts/ci-static-checks.sh
bash scripts/ci-security-checks.sh
bash scripts/ci-docs-checks.sh
bash -n scripts/*.sh scripts/tests/*.sh
git diff --check
./build.sh run
```

Do not run local TSan on macOS 26; the known Apple runtime crash remains external. Ensure deterministic selection includes `PipelineObservabilityTests`; update the explicit list under a failing semantic test first if necessary.

- [ ] **Step 6: Privacy and performance review**

Dispatch fresh read-only reviewers to verify:

- no sensitive fields or raw errors can enter reports/logs;
- no filesystem, resource sampling, formatting, or signpost allocation was added to the real-time render callback;
- session finalization is exactly once across completion/cancel/failure;
- metrics are dimensioned by provider/model/mode and do not mix engine state;
- RTF denominators and latency boundaries are documented and correct;
- JSONL retention, bounded reads/lines, owner-only permissions, current-user ownership, and symlink rejection are enforced;
- graceful cleanup durably records the session, while deinit/forced termination is explicitly best-effort;
- nearest-rank percentile populations exclude missing values but outcome counts include every report.

Apply any Critical/Important fixes through new RED/GREEN cycles and rerun `./build.sh run` after every edit.

- [ ] **Step 7: Commit documentation/validation changes**

```bash
git add docs/troubleshooting/PROFILING.md \
  docs/development/ARCHITECTURE.md \
  docs/testing/TESTING.md \
  scripts/ci-docs-checks.sh \
  scripts/tests/test_ci_docs_checks.sh
git commit -m "Document pipeline observability contracts"
```

- [ ] **Step 8: Push, open PR, and verify integration**

```bash
git push -u origin feat/pipeline-observability
gh pr create --base main --head feat/pipeline-observability \
  --title "Add end-to-end pipeline observability" \
  --body-file /tmp/mactalk-pipeline-observability-pr.md
```

Wait for all blocking PR checks and a fresh review. Merge normally only after green evidence; never force-push or alter immutable release tags.

## Self-review

- Spec coverage: the plan covers dimensions, capture/composition/backpressure health, monotonic stage timings, RTF, inference/end-to-end/output latency, bounded local persistence, report access, signposts, privacy, overhead, docs, testing, and integration.
- Scope control: remote telemetry, continuous CPU/GPU monitoring, guessed speech onset, and flaky hosted absolute benchmark gates are explicitly deferred with rationale.
- Type consistency: one `PipelineSessionReport` flows recorder → `PipelineMetricsStoring` → JSONL/formatter → injected status diagnostics client.
- TDD: every production behavior is preceded by an independently failing focused test and RED observation.
- Runtime policy: every source, test, docs, or script edit is followed by `./build.sh run`; local TSan is not rerun on the known incompatible macOS 26 runtime.
