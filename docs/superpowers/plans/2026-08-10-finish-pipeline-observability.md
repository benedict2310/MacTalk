# Finish Pipeline Observability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `subagent-driven-development` (recommended) or `executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Recover the interrupted ScreenCapture retirement work, finish the remaining privacy-safe observability features, validate them, and merge the feature through a green pull request.

**Architecture:** Preserve the approved `PipelineSessionRecorder` and `PipelineMetricsStore`. Finish capture retirement as a generation-owned state machine whose synchronous stop request only marks retirement and whose async boundary proves shutdown before releasing ownership. Keep capture callbacks limited to bounded primitive metadata collection, expose reports through an injected status-bar diagnostics client, and make explicit cleanup durable while retaining best-effort semantics for forced termination.

**Tech Stack:** Swift 6 strict concurrency, AppKit, ScreenCaptureKit, CoreMedia, `OSAllocatedUnfairLock`/`NSLock`, actors, XCTest, XcodeGen, shell contract tests, GitHub Actions, hosted Thread Sanitizer.

---

## Working-state constraints

- Work only in `/Users/bene/Dev-Source-NoBackup/MacTalk/.worktrees/stabilize-mactalk` on `feat/pipeline-observability`.
- Preserve intentional untracked `.pi-subagents/`.
- Do not stash, reset, clean, rebase, force-push, or discard the current WIP.
- Do not run local TSan on macOS 26. Use the hosted macOS 15 lane after pushing.
- Run signed `./build.sh run` after every source, test, script, workflow, or documentation edit.
- Never alter immutable tags `v1.1.3`, `v1.1.4`, or `v1.1.5`.
- Use one writer at a time and obtain fresh read-only spec and security/concurrency reviews before closing each implementation todo.

## Current baseline

Committed head is `fa83a38`; the branch is 12 commits ahead of `origin/main`. Eight tracked files contain an interrupted ScreenCapture retirement change. `git diff --check` passes, but the last source edit occurred after the most recent recorded test/build, so the current WIP must be treated as unverified.

The approved core lives in:

- `MacTalk/MacTalk/Utilities/PipelineObservability.swift`
- `MacTalk/MacTalkTests/PipelineObservabilityTests.swift`

Do not redesign that core without a failing integration test demonstrating a concrete defect.

## File responsibility map

- `MacTalk/MacTalk/Audio/ScreenAudioCapture.swift`: generation-owned ScreenCaptureKit discovery/start/retirement only.
- `MacTalk/MacTalk/TranscriptionController.swift`: session ownership, capture/inference metrics, terminal outcomes, and durable explicit finalization.
- `MacTalk/MacTalk/StatusBar/RecordingSessionCoordinator.swift`: request ownership and joining cancelled start/cleanup work.
- `MacTalk/MacTalk/Audio/AudioHardwareValidationRecorder.swift`: bounded, asynchronous, opt-in hardware metadata delivery.
- `MacTalk/MacTalk/StatusBar/StatusBarSystemClients.swift`: injected diagnostics-report client and live composition.
- `MacTalk/MacTalk/StatusBar/StatusMenuPresenter.swift`: stable report menu item.
- `MacTalk/MacTalk/StatusBarController.swift`: report-copy action routing only.
- `scripts/deterministic-test-selection.sh`: explicit deterministic and hosted-TSan class declarations.
- `docs/troubleshooting/PROFILING.md`: user-facing runtime metrics and Instruments workflow.

### Task 1: Recover and close ScreenCapture retirement

**Files:**
- Modify: `MacTalk/MacTalk/Audio/ScreenAudioCapture.swift`
- Modify: `MacTalk/MacTalk/TranscriptionController.swift`
- Modify: `MacTalk/MacTalk/Utilities/PipelineObservability.swift`
- Modify: `MacTalk/MacTalk/StatusBar/RecordingSessionCoordinator.swift`
- Modify: `MacTalk/MacTalk/StatusBar/ProductionRecordingSession.swift`
- Modify: `MacTalk/MacTalk/StatusBarController.swift`
- Modify: `MacTalk/MacTalk/AppDelegate.swift`
- Modify: `MacTalk/MacTalkTests/ScreenAudioCaptureTests.swift`
- Modify: `MacTalk/MacTalkTests/TranscriptionControllerTests.swift`
- Modify: `MacTalk/MacTalkTests/RecordingSessionCoordinatorTests.swift`

- [ ] **Step 1: Establish the exact current RED or GREEN state without editing**

Run:

```bash
cd /Users/bene/Dev-Source-NoBackup/MacTalk/.worktrees/stabilize-mactalk
xcodebuild test \
  -project MacTalk.xcodeproj \
  -scheme MacTalk \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  -only-testing:MacTalkTests/ScreenAudioCaptureTests \
  -only-testing:MacTalkTests/TranscriptionControllerTests \
  -only-testing:MacTalkTests/RecordingSessionCoordinatorTests
```

Expected: a nonzero test count. Record every compile diagnostic or failing test. Do not edit tests merely to match current behavior.

- [ ] **Step 2: Add the missing controller-level retirement-failure test**

Extend `DeterministicCaptureSession` in `MacTalk/MacTalkTests/DeterministicHarness.swift` with a typed, retryable stop failure:

```swift
var stopAndWaitFailuresRemaining = 0
private(set) var stopAndWaitCount = 0

func stopAndWait() async throws {
    stopAndWaitCount += 1
    if stopAndWaitFailuresRemaining > 0 {
        stopAndWaitFailuresRemaining -= 1
        throw ScreenCaptureLifecycleError.stopFailed
    }
}
```

Add to `TranscriptionControllerTests` using its existing `scheduler` fixture and direct controller construction:

```swift
func test_explicitCleanupRetriesFailedCaptureRetirementBeforeCompleting() async throws {
    let capture = DeterministicCaptureSession()
    capture.stopAndWaitFailuresRemaining = 1
    let metricsStore = RecordingPipelineMetricsStore()
    let controller = TranscriptionController(
        engine: DeterministicASREngine(),
        captureSession: capture,
        scheduler: scheduler,
        metricsStore: metricsStore
    )

    try await controller.start(mode: .micOnly)
    controller.stop()
    await advanceStopScheduler()
    for _ in 0..<100 where capture.stopAndWaitCount == 0 { await Task.yield() }

    XCTAssertEqual(capture.stopAndWaitCount, 1)
    XCTAssertEqual(await metricsStore.count, 0)

    try await controller.stopAndWait()
    await metricsStore.waitForCount(1)

    XCTAssertEqual(capture.stopAndWaitCount, 2)
    XCTAssertEqual(await metricsStore.count, 1)
}
```

- [ ] **Step 3: Run the new test to verify RED**

Run the three focused classes again. Expected: the new test fails because failed normal retirement either finalizes early, is not retained, or is not retried by explicit cleanup.

Run signed validation after the test edit:

```bash
./build.sh run
```

- [ ] **Step 4: Finish the operation-state invariants**

Keep the existing `Completion`, `Operation`, and `stopToken` design in `ScreenAudioCapture.swift`, but enforce these exact transitions:

```swift
func requestStop() {
    lock.withLock { current?.retired = true }
}

func stopAndWait() async throws {
    guard let operation = lock.withLock({ () -> Operation? in
        current?.retired = true
        return current
    }) else { return }

    try await operation.startCompletion.wait()
    try await stopIfNeeded(operation)
    clearIfCurrent(operation)
}
```

`start` must publish `Operation` before its first suspension, resolve `startCompletion` exactly once, and perform a post-start stop whenever the operation was retired—even when `startCapture` failed after partial activation:

```swift
do {
    let stream = try await driver.makeStream(
        for: request,
        sessionID: sessionID,
        onAudioSampleBuffer: onAudioSampleBuffer,
        onStreamError: onStreamError
    )
    lock.withLock {
        operation.stream = stream
        operation.active = true
    }
    try await driver.startCapture(stream)
    _ = operation.startCompletion.resolve(.success(()))
} catch {
    _ = operation.startCompletion.resolve(.failure(error))
    if lock.withLock({ operation.stream != nil }) {
        try await stopIfNeeded(operation)
    }
    clearIfCurrent(operation)
    throw error
}

if lock.withLock({ operation.retired }) {
    try await stopIfNeeded(operation)
    clearIfCurrent(operation)
    throw CancellationError()
}
```

`stopIfNeeded` must single-flight concurrent callers, retain ownership on failure, and clear the cached task only when the matching token is current:

```swift
private func stopIfNeeded(_ operation: Operation) async throws {
    let (task, token) = lock.withLock { () -> (Task<Void, Error>?, UInt64) in
        guard let stream = operation.stream else { return (nil, operation.stopToken) }
        if let task = operation.stopTask { return (task, operation.stopToken) }
        operation.stopToken &+= 1
        let token = operation.stopToken
        let task = Task { try await driver.stopCapture(stream) }
        operation.stopTask = task
        return (task, token)
    }
    guard let task else { return }

    do {
        try await task.value
        lock.withLock {
            guard operation.stopToken == token else { return }
            operation.stopTask = nil
            operation.stream = nil
            operation.active = false
        }
    } catch {
        lock.withLock {
            guard operation.stopToken == token else { return }
            operation.stopTask = nil
        }
        throw ScreenCaptureLifecycleError.stopFailed
    }
}
```

Never clear `current` while `operation.stream` remains nonnil. A replacement `start` must await successful retirement of the previous operation before calling `makeStream` for the replacement.

- [ ] **Step 5: Propagate retirement failure without false completion**

Keep `TranscriptionCaptureSession.stopAndWait() async throws`. In `TranscriptionController`, normal scheduled stop may retain the typed failure for explicit cleanup, but it must not write a completed report until retirement succeeds. When explicit `stopAndWait()` observes a prior scheduled failure, it must claim a new single-flight finalization attempt, call `captureSession.stopAndWait()` again, clear the stored failure only after successful retirement, and then finish/persist exactly once. A second failed stop must propagate to coordinator cleanup, status-bar cleanup, and application termination; no cleanup callback may report success.

Change the cleanup handle itself to preserve typed failure and strong ownership:

```swift
final class SessionCleanup: @unchecked Sendable {
    let task: Task<Void, Error>
    private let owner: AnyObject

    init(task: Task<Void, Error>, owner: AnyObject) {
        self.task = task
        self.owner = owner
    }

    func wait() async throws {
        _ = owner
        try await task.value
    }
}
```

`requestCancelStart()` must create a strongly captured throwing task instead of catching and returning:

```swift
let task = Task { [self] in
    try await captureSession.stopAndWait()
    await cancelPendingChunkTasks(sessionID: sessionID)
    await finalizeRecorder(sessionID: sessionID, outcome: .cancelled)
}
return SessionCleanup(task: task, owner: self)
```

Update coordinator `PendingCancellation` to retain the strong session, original start task, and cleanup handle:

```swift
private struct PendingCancellation {
    let session: any TranscriptionSession
    let startWork: Task<Void, Never>
    var cleanup: SessionCleanup
}
```

The first failed wait must leave the entry in `pendingCancellations` and install a fresh retry handle without authorizing a replacement:

```swift
private func awaitPendingCancellation(_ id: UUID) async throws {
    guard var pending = pendingCancellations[id] else { return }
    await pending.startWork.value
    do {
        try await pending.cleanup.wait()
        pendingCancellations.removeValue(forKey: id)
    } catch {
        pending.cleanup = pending.session.requestCancelStart()
        pendingCancellations[id] = pending
        throw error
    }
}
```

A second explicit `cleanup()` is the retry trigger: it awaits the retained replacement handle and removes the entry only after capture retirement and metrics persistence succeed. `requestStart` must remain idle while any pending cancellation is failed/unproven; it may await successful pending entries but must never overwrite or discard them.

Add `test_cancelledStartCleanupPropagatesRetirementFailureAndRetriesBeforeReplacement` to `RecordingSessionCoordinatorTests`: suspend the original start, make the first stop fail, assert the first `cleanup()` throws and replacement authorization remains zero, call `cleanup()` a second time after allowing stop to succeed, then assert exactly one cancellation report before a later explicit `requestStart` authorizes the replacement.

Create a compiling typed logger in `PipelineObservability.swift`:

```swift
enum PipelineLog {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.mactalk.app",
        category: "pipeline"
    )

    static func captureRetirementFailed() {
        logger.error("capture_retirement_failed")
    }
}
```

Use only the typed method:

```swift
catch {
    PipelineLog.captureRetirementFailed()
    throw ScreenCaptureLifecycleError.stopFailed
}
```

Do not persist or log `error.localizedDescription` or target/application identity.

- [ ] **Step 6: Run GREEN and signed build/restart**

Run:

```bash
xcodebuild test \
  -project MacTalk.xcodeproj \
  -scheme MacTalk \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  -only-testing:MacTalkTests/ScreenAudioCaptureTests \
  -only-testing:MacTalkTests/TranscriptionControllerTests \
  -only-testing:MacTalkTests/RecordingSessionCoordinatorTests \
  -only-testing:MacTalkTests/AppPickerIntegrationTests \
  -only-testing:MacTalkTests/AppAudioSourceCoordinatorTests \
  -only-testing:MacTalkTests/PipelineObservabilityTests \
  -only-testing:MacTalkTests/ConcurrencyStressTests
./build.sh run
git diff --check
```

Expected: all selected tests pass, signed build succeeds, MacTalk relaunches, and diff check is empty.

- [ ] **Step 7: Review and commit the recovered WIP**

Obtain fresh spec and security/concurrency reviews. Required approval assertions:

- a stop before activation cannot count as shutdown;
- no publication gap permits early cleanup return;
- a failed stop is retained and retryable;
- concurrent waiters share one stop;
- replacement waits for proven retirement;
- no protected stream can survive explicit cleanup;
- no report is finalized before capture retirement;
- no raw error or application identity is logged.

Fix every Critical/Important finding through a new RED/GREEN cycle, then commit:

```bash
git add MacTalk/MacTalk/AppDelegate.swift \
  MacTalk/MacTalk/Audio/ScreenAudioCapture.swift \
  MacTalk/MacTalk/StatusBar/ProductionRecordingSession.swift \
  MacTalk/MacTalk/StatusBar/RecordingSessionCoordinator.swift \
  MacTalk/MacTalk/StatusBarController.swift \
  MacTalk/MacTalk/TranscriptionController.swift \
  MacTalk/MacTalk/Utilities/PipelineObservability.swift \
  MacTalk/MacTalkTests/DeterministicHarness.swift \
  MacTalk/MacTalkTests/RecordingSessionCoordinatorTests.swift \
  MacTalk/MacTalkTests/ScreenAudioCaptureTests.swift \
  MacTalk/MacTalkTests/TranscriptionControllerTests.swift
git commit -m "Fix durable screen capture retirement"
```

### Task 2: Make hardware validation recording nonblocking and secure

**Files:**
- Modify: `MacTalk/MacTalk/Audio/AudioHardwareValidationRecorder.swift`
- Modify: `MacTalk/MacTalk/TranscriptionController.swift`
- Modify: `MacTalk/MacTalk/DebugLogger.swift`
- Create: `MacTalk/MacTalkTests/AudioHardwareValidationRecorderTests.swift`
- Modify: `MacTalk/MacTalkTests/PrivacyLoggingTests.swift`
- Regenerate: `MacTalk.xcodeproj/project.pbxproj`

- [ ] **Step 1: Add failing callback-isolation and boundedness tests**

Define an injected sink and manual scheduler in the new test file:

```swift
final class RecordingHardwareSink: AudioHardwareValidationSinking, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var records: [AudioHardwareValidationRecord] = []
    func append(_ record: AudioHardwareValidationRecord) throws {
        lock.withLock { records.append(record) }
    }
}

final class ManualHardwareScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private var jobs: [@Sendable () -> Void] = []
    func schedule(_ job: @escaping @Sendable () -> Void) { lock.withLock { jobs.append(job) } }
    func runAll() {
        let pending = lock.withLock { defer { jobs.removeAll() }; return jobs }
        pending.forEach { $0() }
    }
}
```

Add tests proving:

```swift
func test_recordMicrophoneNeverWritesOnCaller() {
    let sink = RecordingHardwareSink()
    let scheduler = ManualHardwareScheduler()
    let recorder = AudioHardwareValidationRecorder(
        sink: sink,
        maximumPendingRecords: 2,
        schedule: scheduler.schedule
    )

    recorder.recordMicrophone(sessionID: UUID(), hostNanoseconds: 10, sampleCount: 160)
    XCTAssertTrue(sink.records.isEmpty)
    scheduler.runAll()
    XCTAssertEqual(sink.records.count, 1)
}

func test_pendingRecordsAreBounded() {
    let sink = RecordingHardwareSink()
    let scheduler = ManualHardwareScheduler()
    let recorder = AudioHardwareValidationRecorder(
        sink: sink,
        maximumPendingRecords: 2,
        schedule: scheduler.schedule
    )
    let sessionID = UUID()

    recorder.recordMicrophone(sessionID: sessionID, hostNanoseconds: 1, sampleCount: 160)
    recorder.recordMicrophone(sessionID: sessionID, hostNanoseconds: 2, sampleCount: 160)
    recorder.recordMicrophone(sessionID: sessionID, hostNanoseconds: 3, sampleCount: 160)

    XCTAssertEqual(recorder.droppedRecordCount, 1)
    scheduler.runAll()
    XCTAssertEqual(sink.records.count, 2)
}
```

Also add filesystem tests for symlink rejection, FIFO/non-regular rejection, file mode `0600`, existing parent mode preservation, and typed `stream_error` output.

- [ ] **Step 2: Run RED and signed build/restart**

Run:

```bash
xcodebuild test -project MacTalk.xcodeproj -scheme MacTalk \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  -only-testing:MacTalkTests/AudioHardwareValidationRecorderTests
./build.sh run
```

Expected: compile failure because the sink/scheduler injection does not exist.

- [ ] **Step 3: Implement typed bounded delivery**

Introduce metadata-only records:

```swift
enum AudioHardwareValidationResult: String, Sendable {
    case received
    case streamError = "stream_error"
}

struct AudioHardwareValidationRecord: Sendable, Equatable {
    let event: String
    let sessionID: UUID
    let arrivalUptimeNanoseconds: UInt64
    let mediaHostNanoseconds: Int64?
    let ptsValue: Int64?
    let ptsTimescale: Int32?
    let sampleCount: Int
    let result: AudioHardwareValidationResult
}

protocol AudioHardwareValidationSinking: Sendable {
    func append(_ record: AudioHardwareValidationRecord) throws
}
```

The recorder call path must only create the value and enqueue it under a small lock:

```swift
private func enqueue(_ record: AudioHardwareValidationRecord) {
    let accepted = state.withLock { state -> Bool in
        guard state.pending < maximumPendingRecords else {
            state.dropped &+= 1
            return false
        }
        state.pending += 1
        return true
    }
    guard accepted else { return }
    schedule { [weak self] in
        guard let self else { return }
        defer { self.state.withLock { $0.pending -= 1 } }
        try? self.sink.append(record)
    }
}
```

Change `recordApplicationLoss` to accept no raw error string:

```swift
func recordApplicationLoss(sessionID: UUID) {
    enqueue(AudioHardwareValidationRecord(
        event: "application_loss",
        sessionID: sessionID,
        arrivalUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds,
        mediaHostNanoseconds: nil,
        ptsValue: nil,
        ptsTimescale: nil,
        sampleCount: 0,
        result: .streamError
    ))
}
```

Replace `DebugLogMessage.error(description:)` with a value-free event and change all controller call sites:

```swift
enum DebugLogMessage: Sendable {
    case event(String)
    case transcriptCompleted(characterCount: Int)
    case clipboardUpdated(characterCount: Int)
    case operationFailed

    var rendered: String {
        switch self {
        case let .event(message): return message
        case let .transcriptCompleted(count): return "transcription.completed chars=\(count)"
        case let .clipboardUpdated(count): return "clipboard.updated chars=\(count)"
        case .operationFailed: return "operation.failed"
        }
    }
}
```

Use `DebugLogger.shared.log(.operationFailed)` for engine and application-stream failures. Change `handleAppAudioError` to call `hardwareValidationRecorder.recordApplicationLoss(sessionID:)` without an error argument.

Remove the recorder initializer’s `print("... \(error.localizedDescription)")`; either remain silent or emit only `PipelineLog.hardwareValidationUnavailable()`, whose rendered message is the fixed token `hardware_validation_unavailable`.

Add `PrivacyLoggingTests.test_pipelineDiagnosticsSourcesNeverPassLocalizedErrors`: load `TranscriptionController.swift`, `AudioHardwareValidationRecorder.swift`, and `DebugLogger.swift`; assert none contains `error.localizedDescription`, and assert the controller does not contain `recordApplicationLoss(sessionID: sessionID, error:`. Keep the existing sentinel-value runtime test for `DebugLogMessage.rendered`.

The production file sink must call `Darwin.open(fileURL.path, O_APPEND | O_CREAT | O_WRONLY | O_NOFOLLOW, 0o600)`, validate with `fstat` that the descriptor is a current-user regular file with mode `0600`, and write through that descriptor. Create/chmod `0700` only when the recorder itself creates the parent. Reject an existing insecure or symlinked parent; never chmod a caller-supplied existing directory.

- [ ] **Step 4: Regenerate the project, run GREEN, review, and commit**

Run:

```bash
xcodegen generate
xcodebuild test -project MacTalk.xcodeproj -scheme MacTalk \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  -only-testing:MacTalkTests/AudioHardwareValidationRecorderTests \
  -only-testing:MacTalkTests/PipelineObservabilityTests \
  -only-testing:MacTalkTests/TranscriptionControllerTests
./build.sh run
git diff --check
```

Obtain a fresh security review for callback blocking, queue bounds, ownership, symlinks, permissions, and raw-error exclusion. Fix Critical/Important findings, rerun, then commit:

```bash
git add MacTalk/MacTalk/Audio/AudioHardwareValidationRecorder.swift \
  MacTalk/MacTalk/TranscriptionController.swift \
  MacTalk/MacTalk/DebugLogger.swift \
  MacTalk/MacTalkTests/AudioHardwareValidationRecorderTests.swift \
  MacTalk/MacTalkTests/PrivacyLoggingTests.swift \
  MacTalk.xcodeproj/project.pbxproj
git commit -m "Make hardware diagnostics nonblocking"
```

Close `TODO-9430824e` only after Tasks 1 and 2 have independent approval.

### Task 3: Expose a local Copy Performance Report action

**Files:**
- Modify: `MacTalk/MacTalk/StatusBar/StatusBarSystemClients.swift`
- Modify: `MacTalk/MacTalk/StatusBar/StatusMenuPresenter.swift`
- Modify: `MacTalk/MacTalk/StatusBarController.swift`
- Modify: `MacTalk/MacTalkTests/StatusMenuPresenterTests.swift`
- Modify: `MacTalk/MacTalkTests/StatusBarControllerTests.swift`

- [ ] **Step 1: Add failing dependency, menu, and action tests**

Require:

```swift
XCTAssertEqual(
    presenter.menu.item(withIdentifier: .init("application.performanceReport"))?.title,
    "Copy Performance Report"
)
XCTAssertEqual(
    presenter.menu.item(withIdentifier: .init("application.performanceReport"))?.action,
    #selector(StatusBarController.copyPerformanceReport)
)
```

Create a complete `StatusBarDependencies` fixture and fake:

```swift
@MainActor
final class PipelineDiagnosticsClientFake: PipelineDiagnosticsClient {
    private(set) var copyCount = 0
    var result = true
    func copyPerformanceReport() async -> Bool {
        copyCount += 1
        return result
    }
}
```

Invoke `controller.copyPerformanceReport()`, await one main-actor turn, and assert one invocation. Assert the output coordinator and auto-paste fakes receive zero calls.

- [ ] **Step 2: Run RED and signed build/restart**

Run status menu/controller tests. Expected: compile failures for the missing protocol, dependency, item ID, and selector. Then run `./build.sh run`.

- [ ] **Step 3: Implement the injected client and action**

Add:

```swift
@MainActor
protocol PipelineDiagnosticsClient: AnyObject {
    func copyPerformanceReport() async -> Bool
}

@MainActor
final class SystemPipelineDiagnosticsClient: PipelineDiagnosticsClient {
    private let store: any PipelineMetricsStoring
    private let clipboard: any ClipboardWriting

    init(
        store: any PipelineMetricsStoring = PipelineMetricsStore.shared,
        clipboard: any ClipboardWriting = SystemClipboardWriter()
    ) {
        self.store = store
        self.clipboard = clipboard
    }

    func copyPerformanceReport() async -> Bool {
        clipboard.write(await store.formattedReport(limit: 20))
    }
}
```

Add `pipelineDiagnostics` to `StatusBarDependencies` and `.live`. Add:

```swift
enum ItemID {
    static let performanceReport = "application.performanceReport"
}
```

Place `Copy Performance Report` immediately before Settings/Permissions. Route only through the diagnostics client:

```swift
@objc func copyPerformanceReport() {
    Task { @MainActor [weak self] in
        guard let self else { return }
        if !(await dependencies.pipelineDiagnostics.copyPerformanceReport()) {
            NSSound.beep()
        }
    }
}
```

- [ ] **Step 4: Run GREEN, review, and commit**

Run focused tests, `./build.sh run`, and `git diff --check`. Review for accidental auto-paste, transcript-output routing, or remote transmission. Then commit:

```bash
git add MacTalk/MacTalk/StatusBar/StatusBarSystemClients.swift \
  MacTalk/MacTalk/StatusBar/StatusMenuPresenter.swift \
  MacTalk/MacTalk/StatusBarController.swift \
  MacTalk/MacTalkTests/StatusMenuPresenterTests.swift \
  MacTalk/MacTalkTests/StatusBarControllerTests.swift
git commit -m "Expose local pipeline performance reports"
```

Close `TODO-a4c9288e` after review approval.

### Task 4: Correct docs and enforce test-lane coverage

**Files:**
- Modify: `docs/troubleshooting/PROFILING.md`
- Modify: `docs/development/ARCHITECTURE.md`
- Modify: `docs/testing/TESTING.md`
- Modify: `docs/testing/CI.md`
- Modify: `scripts/deterministic-test-selection.sh`
- Modify: `scripts/ci-docs-checks.sh`
- Modify: `scripts/tests/test_deterministic_test_selection.sh`
- Modify: `scripts/tests/test_ci_docs_checks.sh`

- [ ] **Step 1: Add failing lane-selection assertions**

In `test_deterministic_test_selection.sh`, require these classes in both arrays:

```bash
required_observability_classes=(
  MacTalkTests/AudioHardwareValidationRecorderTests
  MacTalkTests/PipelineObservabilityTests
  MacTalkTests/ScreenAudioCaptureTests
)

for required in "${required_observability_classes[@]}"; do
  [[ " ${DETERMINISTIC_TEST_CLASSES[*]} " == *" $required "* ]]
  [[ " ${TSAN_SUPPORTED_TEST_CLASSES[*]} " == *" $required "* ]]
done
```

Run the fixture. Expected: failure because the classes are currently absent.

- [ ] **Step 2: Add failing documentation contracts**

Require the docs checks to find all of these exact contracts:

```text
~/Library/Logs/MacTalk/pipeline-metrics.jsonl
Copy Performance Report
no transcript text, audio samples, target application identity, or raw errors
monotonic
real-time factor
com.mactalk.app
pipeline
bounded asynchronous hardware validation
hosted Thread Sanitizer
```

Run `bash scripts/tests/test_ci_docs_checks.sh`. Expected: failure against the current stale profiling guide.

Run `./build.sh run` after each script/test edit.

- [ ] **Step 3: Update the explicit test arrays**

Add the three deterministic classes to `DETERMINISTIC_TEST_CLASSES` and `TSAN_SUPPORTED_TEST_CLASSES`. These tests use injected drivers/sinks and must not access TCC, windows, hardware, models, or the network.

- [ ] **Step 4: Rewrite profiling and architecture documentation**

Document:

- per-session dimensions and typed terminal outcomes;
- first accepted capture versus first composed audio;
- prepare, queue, incremental/final inference, partial, stop-to-final, and output-handoff boundaries;
- RTF denominator of 16,000 samples per second;
- local JSONL location and 100-record/512-KiB bounds;
- privacy exclusions;
- `Copy Performance Report` behavior;
- Console command:

```bash
log stream --predicate 'subsystem == "com.mactalk.app" AND category == "pipeline"' --level info
```

- Instruments signposts `TranscriptionSession`, `Inference`, `FirstAudio`, `FirstComposedAudio`, and `FirstPartial`;
- CPU/GPU figures are Instruments measurements, not continuously collected runtime metrics;
- hardware validation is opt-in, bounded, asynchronous, and metadata-only;
- no flaky absolute hosted performance threshold is enforced.

Delete stale references to nonexistent `measureAsync` and do not claim CPU/memory monitoring that production does not call.

- [ ] **Step 5: Run GREEN, signed build/restart, and commit**

Run:

```bash
bash scripts/tests/test_deterministic_test_selection.sh
bash scripts/tests/test_ci_docs_checks.sh
bash scripts/ci-docs-checks.sh
bash -n scripts/*.sh scripts/tests/*.sh
./build.sh run
git diff --check
```

Commit:

```bash
git add docs/troubleshooting/PROFILING.md \
  docs/development/ARCHITECTURE.md \
  docs/testing/TESTING.md \
  docs/testing/CI.md \
  scripts/deterministic-test-selection.sh \
  scripts/ci-docs-checks.sh \
  scripts/tests/test_deterministic_test_selection.sh \
  scripts/tests/test_ci_docs_checks.sh
git commit -m "Document and validate pipeline observability"
```

### Task 5: Complete local validation and review

**Files:**
- Modify only if a failing test or reviewer finding requires a RED/GREEN fix.

- [ ] **Step 1: Run the complete deterministic and AppKit lanes**

```bash
scripts/test-lanes.sh unit
scripts/test-lanes.sh appkit
bash scripts/tests/test_ci_workflow_semantics.sh
bash scripts/ci-static-checks.sh
bash scripts/ci-security-checks.sh
bash scripts/ci-docs-checks.sh
bash -n scripts/*.sh scripts/tests/*.sh
git diff --check
./build.sh run
```

Expected: every command exits zero and the signed app relaunches.

- [ ] **Step 2: Run focused repetitions for lifecycle races**

Run `ScreenAudioCaptureTests`, `TranscriptionControllerTests`, `RecordingSessionCoordinatorTests`, and `ConcurrencyStressTests` in three fresh XCTest processes. Expected: all repetitions pass with nonzero test counts.

Do not run local TSan.

- [ ] **Step 3: Obtain independent closure reviews**

Dispatch fresh read-only reviewers for:

1. spec compliance;
2. security/privacy and filesystem trust boundaries;
3. concurrency/task/capture lifecycle correctness;
4. test quality and lane coverage.

Approval requires no Critical or Important findings. Every accepted fix must begin with a failing focused test and be followed by `./build.sh run`.

- [ ] **Step 4: Record evidence and close implementation todos**

Update:

- `TODO-9430824e` with focused/full test counts, build evidence, commit SHAs, and review approvals;
- `TODO-a4c9288e` with menu/action tests and privacy review;
- `TODO-9fc4d4df` with docs/static/security/lane results.

Do not close the epic yet.

### Task 6: Push, validate hosted TSan, and merge

**Files:**
- Create temporarily: `/tmp/mactalk-pipeline-observability-pr.md`
- Do not modify release tags or published release assets.

- [ ] **Step 1: Verify branch state before push**

```bash
git status --short --branch
git log --oneline origin/main..HEAD
git diff origin/main...HEAD --check
```

Expected: only intentional `?? .pi-subagents/` is untracked; no tracked changes remain.

- [ ] **Step 2: Push normally and open the PR**

```bash
git push -u origin feat/pipeline-observability
gh pr create \
  --base main \
  --head feat/pipeline-observability \
  --title "Add end-to-end pipeline observability" \
  --body-file /tmp/mactalk-pipeline-observability-pr.md
```

The PR body must list privacy guarantees, architecture changes, exact local commands/results, signed-build evidence, and the fact that local TSan was intentionally not run on the incompatible macOS 26 runtime.

- [ ] **Step 3: Wait for blocking CI and run hosted TSan**

Use `watch_pr` with `waitFor='ci'` for PR checks. Dispatch the scheduled/manual TSan job on the exact feature ref and capture its run ID:

```bash
EXPECTED_SHA="$(git rev-parse HEAD)"
BEFORE_IDS="$(gh run list \
  --workflow "MacTalk CI" \
  --branch feat/pipeline-observability \
  --event workflow_dispatch \
  --limit 20 \
  --json databaseId \
  --jq 'map(.databaseId | tostring) | join(" ")')"

gh workflow run "MacTalk CI" \
  --ref feat/pipeline-observability \
  -f run_appkit=false

RUN_ID=""
for attempt in {1..30}; do
  RUN_ID="$(gh run list \
    --workflow "MacTalk CI" \
    --branch feat/pipeline-observability \
    --event workflow_dispatch \
    --limit 20 \
    --json databaseId,headSha \
    --jq ".[] | select(.headSha == \"$EXPECTED_SHA\") | .databaseId" \
    | while read -r candidate; do
        case " $BEFORE_IDS " in
          *" $candidate "*) ;;
          *) printf '%s\n' "$candidate"; break ;;
        esac
      done)"
  test -n "$RUN_ID" && break
  sleep 2
done

test -n "$RUN_ID"
RUN_JSON="$(gh run view "$RUN_ID" --json databaseId,event,headBranch,headSha,url,status,conclusion)"
test "$(jq -r '.event' <<<"$RUN_JSON")" = "workflow_dispatch"
test "$(jq -r '.headBranch' <<<"$RUN_JSON")" = "feat/pipeline-observability"
test "$(jq -r '.headSha' <<<"$RUN_JSON")" = "$EXPECTED_SHA"
RUN_URL="$(jq -r '.url' <<<"$RUN_JSON")"
gh run watch "$RUN_ID" --exit-status

TSAN_JOB_ID="$(gh run view "$RUN_ID" --json jobs \
  --jq '.jobs[] | select(.name | contains("ThreadSanitizer")) | .databaseId')"
test -n "$TSAN_JOB_ID"
```

Download and inspect the exact artifact:

```bash
TSAN_DIR="$(mktemp -d /tmp/mactalk-observability-tsan.XXXXXX)"
ARTIFACT_ID="$(gh api "repos/{owner}/{repo}/actions/runs/$RUN_ID/artifacts" \
  --jq '.artifacts[] | select(.name == "mactalk-tsan-log") | .id')"
test -n "$ARTIFACT_ID"
gh run download "$RUN_ID" --name mactalk-tsan-log --dir "$TSAN_DIR"
test -s "$TSAN_DIR/tsan.log"
printf 'run=%s\nurl=%s\njob=%s\nartifact=%s\nsha=%s\n' \
  "$RUN_ID" "$RUN_URL" "$TSAN_JOB_ID" "$ARTIFACT_ID" "$EXPECTED_SHA"

if rg -n 'WARNING: ThreadSanitizer|ThreadSanitizer: data race|TSAN/FAIL' "$TSAN_DIR/tsan.log"; then
  echo "Hosted TSan evidence contains a failure marker" >&2
  exit 1
fi

for required_class in \
  PipelineObservabilityTests \
  AudioHardwareValidationRecorderTests \
  ScreenAudioCaptureTests
do
  rg -F -n "$required_class" "$TSAN_DIR/tsan.log" >/dev/null || {
    echo "Hosted TSan log omitted $required_class" >&2
    exit 1
  }
done
shasum -a 256 "$TSAN_DIR/tsan.log"
```

Acceptance requires exact pinned Xcode/runtime checks, all three observability classes present in the log, zero test failures, zero sanitizer warning/data-race markers, and a recorded run URL, job ID, artifact ID, and SHA-256. Do not suppress races or reduce repetitions to manufacture a pass.

- [ ] **Step 4: Address review/CI findings through RED/GREEN commits**

For every concrete defect: reproduce with a failing test, apply the minimal fix, run signed `./build.sh run`, rerun affected/full lanes, commit, and push normally. Never force-push.

- [ ] **Step 5: Merge and verify**

After all checks and review are green, merge normally. Verify:

```bash
gh pr view --json state,mergeCommit,statusCheckRollup
git fetch origin
git rev-parse origin/main
```

Confirm the merged tree contains the reviewed branch tree. Do not create, move, delete, or recreate any release tag.

- [ ] **Step 6: Close the epic**

Close `TODO-1a00ec31` with:

- merged PR URL and merge commit;
- local deterministic/AppKit/static/security/docs evidence;
- hosted TSan run/job/artifact evidence;
- final privacy and concurrency review approvals;
- any explicitly documented residual limitations.

## Self-review

- **Spec coverage:** Tasks cover WIP recovery, protected-stream retirement, durable cleanup, callback-safe hardware diagnostics, user report access, dimensions/signposts, privacy, documentation, deterministic/hosted TSan selection, PR validation, and merge.
- **Scope control:** Remote telemetry, transcript/audio persistence, continuous CPU/GPU sampling, guessed speech onset, and flaky absolute hosted benchmark gates remain excluded.
- **Type consistency:** `PipelineSessionReport` remains the sole persisted record; `PipelineMetricsStoring` feeds `PipelineDiagnosticsClient`; hardware-validation metadata uses a separate bounded typed record.
- **TDD:** Every new behavior has an explicit failing test and RED command before implementation.
- **Safety:** The plan preserves the current WIP, avoids destructive git operations and local TSan, and requires signed build/restart after each edit.
