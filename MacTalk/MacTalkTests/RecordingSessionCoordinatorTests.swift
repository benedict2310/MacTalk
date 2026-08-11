import XCTest
@testable import MacTalk
@preconcurrency import AVFoundation

@MainActor
final class RecordingSessionCoordinatorTests: XCTestCase {
    func test_toggleStartsRequestedMicOnlyModeWhenIdle() async throws {
        let harness = RecordingHarness()

        harness.coordinator.toggle(mode: .micOnly)

        await harness.waitFor { harness.coordinator.state.phase == .recording }
        XCTAssertEqual(harness.coordinator.state.mode, .micOnly)
        XCTAssertEqual(harness.session.starts.count, 1)
    }

    func test_toggleStopsActiveRecording() async throws {
        let harness = RecordingHarness()
        harness.coordinator.toggle(mode: .micOnly)
        await harness.waitFor { harness.coordinator.state.phase == .recording }

        harness.coordinator.toggle(mode: .micOnly)

        XCTAssertEqual(harness.coordinator.state.phase, .finalizing)
        XCTAssertEqual(harness.session.stopCount, 1)
    }

    func test_toggleCancelsStartInProgress() async throws {
        let harness = RecordingHarness()
        harness.session.startSuspended = true
        harness.coordinator.toggle(mode: .micOnly)
        await harness.waitFor { harness.coordinator.state.phase == .starting }

        harness.coordinator.toggle(mode: .micOnly)

        XCTAssertEqual(harness.coordinator.state.phase, .idle)
        XCTAssertEqual(harness.session.cancelStarts, 1)
        harness.session.releaseStart()
        await Task.yield()
        XCTAssertEqual(harness.coordinator.state.phase, .idle)
    }

    func test_cancelledOriginalStartBlocksReplacementUntilStartExitsAndPersistsOnce() async throws {
        let harness = RecordingHarness()
        harness.session.startSuspended = true
        harness.session.cancelSuspended = true
        harness.session.persistsMetrics = true
        harness.coordinator.requestStart(mode: .micOnly)
        await harness.waitFor { harness.coordinator.state.phase == .starting }

        harness.permission.resetAuthorizeCount()
        harness.coordinator.stop()
        harness.coordinator.requestStart(mode: .micOnly)
        await Task.yield()
        XCTAssertEqual(harness.permission.authorizeCount, 0)
        let initialRecordCount = await harness.session.metricsStore.recordCount
        XCTAssertEqual(initialRecordCount, 0)

        harness.session.releaseCancel()
        await Task.yield()
        XCTAssertEqual(harness.permission.authorizeCount, 0)
        harness.session.releaseStart()
        await harness.session.metricsStore.waitForRecordStart()
        XCTAssertEqual(harness.permission.authorizeCount, 0)
        await harness.session.metricsStore.releaseRecord()
        harness.session.startSuspended = false
        await harness.waitFor { harness.permission.authorizeCount == 1 }
        await harness.waitFor { harness.coordinator.state.phase == .recording }
        let completedRecordCount = await harness.session.metricsStore.recordCount
        XCTAssertEqual(completedRecordCount, 1)
        XCTAssertEqual(harness.session.releasedSessions, 1)
    }

    func test_delayedCancellationPermissionBarrierRejectsStartStopBeforeAuthorize() async throws {
        let harness = RecordingHarness()
        harness.session.startSuspended = true
        harness.session.cancelSuspended = true
        harness.coordinator.requestStart(mode: .micOnly)
        await harness.waitFor { harness.coordinator.state.phase == .starting }
        harness.permission.resetAuthorizeCount()
        harness.coordinator.stop()

        harness.coordinator.requestStart(mode: .micOnly)
        harness.coordinator.stop()
        XCTAssertEqual(harness.permission.authorizeCount, 0)

        harness.session.releaseCancel()
        harness.session.releaseStart()
        await Task.yield()
        XCTAssertEqual(harness.permission.authorizeCount, 0)
        XCTAssertEqual(harness.coordinator.state.phase, .idle)
    }

    func test_toggleCancelsStartQueuedBehindPendingRetirement() async throws {
        let harness = RecordingHarness()
        harness.session.startSuspended = true
        harness.session.cancelSuspended = true
        harness.coordinator.requestStart(mode: .micOnly)
        await harness.waitFor { harness.coordinator.state.phase == .starting }
        harness.permission.resetAuthorizeCount()
        harness.coordinator.stop()

        harness.coordinator.requestStart(mode: .micOnly)
        XCTAssertEqual(harness.coordinator.state.phase, .idle)
        harness.coordinator.toggle(mode: .micOnly)
        await harness.session.waitForCancelStart()
        harness.session.releaseCancel()
        harness.session.releaseStart()
        await harness.waitFor { harness.session.releasedSessions == 1 }
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(harness.permission.authorizeCount, 0)
        XCTAssertEqual(harness.coordinator.state.phase, .idle)
        XCTAssertNil(harness.coordinator.state.requestID)
    }

    func test_toggleStartsBothShortcutModesUsingRequestedMode() async throws {
        let micHarness = RecordingHarness()
        micHarness.coordinator.toggle(mode: .micOnly)
        await micHarness.waitFor { micHarness.coordinator.state.phase == .recording }
        XCTAssertEqual(micHarness.coordinator.state.mode, .micOnly)

        let appHarness = RecordingHarness()
        appHarness.coordinator.toggle(mode: .micPlusAppAudio)
        await appHarness.waitFor { appHarness.coordinator.state.phase == .selectingAudioSource }
        let requestID = try XCTUnwrap(appHarness.coordinator.state.requestID)
        XCTAssertEqual(appHarness.coordinator.state.mode, .micPlusAppAudio)
        appHarness.coordinator.provideAudioSource(
            requestID: requestID,
            source: AppPickerWindowController.AudioSource(app: nil, display: nil, name: "System", icon: nil)
        )
        await appHarness.waitFor { appHarness.coordinator.state.phase == .recording }
        XCTAssertEqual(appHarness.session.starts.first?.source?.name, "System")
    }

    func test_toggleDuringFinalizationLeavesFinalizationToOwnIdleTransition() async throws {
        let harness = RecordingHarness()
        harness.coordinator.toggle(mode: .micOnly)
        await harness.waitFor { harness.coordinator.state.phase == .recording }
        harness.coordinator.stop()

        harness.coordinator.toggle(mode: .micOnly)

        XCTAssertEqual(harness.coordinator.state.phase, .finalizing)
        XCTAssertEqual(harness.session.stopCount, 1)
    }

    func test_cleanupAwaitsCancelledStartBeforeReleasingSession() async throws {
        let harness = RecordingHarness()
        harness.session.startSuspended = true
        harness.session.cancelSuspended = true
        harness.session.persistsMetrics = true
        harness.coordinator.toggle(mode: .micOnly)
        await harness.waitFor { harness.coordinator.state.phase == .starting }

        let cleanup = Task { @MainActor in try await harness.coordinator.cleanup() }
        await harness.session.waitForCancelStart()
        harness.session.releaseCancel()
        await harness.session.metricsStore.waitForRecordStart()
        XCTAssertFalse(cleanup.isCancelled)
        XCTAssertNotNil(harness.coordinator.state.requestID)
        XCTAssertEqual(harness.session.asyncCancelStarts, 1)
        let pendingCount = await harness.session.metricsStore.recordCount
        XCTAssertEqual(pendingCount, 0)

        await harness.session.metricsStore.releaseRecord()
        harness.session.releaseStart()
        try await cleanup.value
        XCTAssertEqual(harness.coordinator.state.phase, .idle)
        XCTAssertEqual(harness.session.releasedSessions, 1)
        let completedCount = await harness.session.metricsStore.recordCount
        XCTAssertEqual(completedCount, 1)
        XCTAssertEqual(harness.session.stopAndWaitCount, 0)
    }

    func test_cancelledStartCleanupPropagatesRetirementFailureAndRetriesBeforeReplacement() async throws {
        let harness = RecordingHarness()
        harness.session.startSuspended = true
        harness.session.persistsMetrics = true
        harness.session.cancelStartFailuresRemaining = 2
        harness.coordinator.requestStart(mode: .micOnly)
        await harness.waitFor { harness.coordinator.state.phase == .starting }
        await harness.session.waitForStart()
        harness.permission.resetAuthorizeCount()

        harness.coordinator.stop()
        let firstCleanup = Task { @MainActor in
            try await harness.coordinator.cleanup()
        }
        harness.session.releaseStart()
        await harness.session.waitForCancelStart()
        do {
            try await firstCleanup.value
            XCTFail("cleanup should propagate capture retirement failure")
        } catch is ScreenCaptureLifecycleError {
            // Expected: failed retirement remains pending and retryable.
        }
        XCTAssertEqual(harness.permission.authorizeCount, 0)
        let firstRecordCount = await harness.session.metricsStore.recordCount
        XCTAssertEqual(firstRecordCount, 0)

        harness.coordinator.requestStart(mode: .micOnly)
        await harness.waitFor { harness.session.asyncCancelStarts == 2 }
        await Task.yield()
        XCTAssertEqual(harness.coordinator.state.phase, .idle)
        XCTAssertNil(harness.coordinator.state.requestID)
        XCTAssertEqual(harness.permission.authorizeCount, 0)

        let retryCleanup = Task { @MainActor in
            try await harness.coordinator.cleanup()
        }
        await harness.session.metricsStore.waitForRecordStart()
        XCTAssertEqual(harness.permission.authorizeCount, 0)
        await harness.session.metricsStore.releaseRecord()
        try await retryCleanup.value
        let completedRecordCount = await harness.session.metricsStore.recordCount
        XCTAssertEqual(completedRecordCount, 1)

        harness.session.startSuspended = false
        harness.coordinator.requestStart(mode: .micOnly)
        await harness.waitFor { harness.permission.authorizeCount == 1 }
        await harness.waitFor { harness.coordinator.state.phase == .recording }
    }

    func test_concurrentPendingCancellationWaitersCannotReplaceOrPruneNewerGeneration() async throws {
        let harness = RecordingHarness()
        harness.session.startSuspended = true
        harness.session.cancelStartFailuresRemaining = 1
        harness.coordinator.requestStart(mode: .micOnly)
        await harness.waitFor { harness.coordinator.state.phase == .starting }
        await harness.session.waitForStart()

        harness.coordinator.stop()
        harness.session.releaseStart()
        await harness.waitFor { harness.session.asyncCancelStarts == 1 }
        harness.session.cancelSuspended = true

        let first = Task { @MainActor in try await harness.coordinator.cleanup() }
        let second = Task { @MainActor in try await harness.coordinator.cleanup() }
        for waiter in [first, second] {
            do {
                try await waiter.value
                XCTFail("both waiters should observe the failed generation")
            } catch is ScreenCaptureLifecycleError {
                // Expected.
            }
        }
        await harness.waitFor { harness.session.asyncCancelStarts >= 2 }
        XCTAssertEqual(harness.session.asyncCancelStarts, 2)

        harness.session.releaseAllCancels()
        await harness.waitFor { harness.session.releasedSessions >= 1 }
        XCTAssertEqual(harness.session.releasedSessions, 1)
        try await harness.coordinator.cleanup()

        harness.session.startSuspended = false
        harness.permission.resetAuthorizeCount()
        harness.coordinator.requestStart(mode: .micOnly)
        await harness.waitFor { harness.permission.authorizeCount == 1 }
        await harness.waitFor { harness.coordinator.state.phase == .recording }
    }

    func test_cleanupAwaitsRecordingStopAndDoesNotFinalizeTwice() async throws {
        let harness = RecordingHarness()
        harness.coordinator.toggle(mode: .micOnly)
        await harness.waitFor { harness.coordinator.state.phase == .recording }
        harness.session.stopSuspended = true
        harness.session.persistsMetrics = true

        let cleanup = Task { @MainActor in try await harness.coordinator.cleanup() }
        await harness.waitFor { harness.session.stopAndWaitStarted }
        harness.session.releaseStopAndWait()
        await harness.session.metricsStore.waitForRecordStart()
        XCTAssertNotNil(harness.coordinator.state.requestID)
        XCTAssertEqual(harness.session.stopAndWaitCount, 1)
        XCTAssertEqual(harness.session.cancelStarts, 0)
        let pendingCount = await harness.session.metricsStore.recordCount
        XCTAssertEqual(pendingCount, 0)

        await harness.session.metricsStore.releaseRecord()
        try await cleanup.value
        try await harness.coordinator.cleanup()
        XCTAssertEqual(harness.coordinator.state.phase, .idle)
        XCTAssertEqual(harness.session.releasedSessions, 1)
        XCTAssertEqual(harness.session.stopAndWaitCount, 1)
        let completedCount = await harness.session.metricsStore.recordCount
        XCTAssertEqual(completedCount, 1)
        XCTAssertEqual(harness.session.cancelStarts, 0)
    }

    func test_micOnlyReachesRecordingWithOneImmutableSnapshot() async throws {
        let harness = RecordingHarness()
        let coordinator = harness.coordinator
        harness.engine.result = .ready(harness.engine.engine)
        coordinator.requestStart(mode: .micOnly)
        let requestID = try XCTUnwrap(coordinator.state.requestID)
        await harness.waitFor { coordinator.state.phase == .recording }
        XCTAssertEqual(harness.session.starts.count, 1)
        XCTAssertEqual(harness.session.starts[0].snapshot, harness.snapshot)
        XCTAssertEqual(coordinator.state.requestID, requestID)
    }

    func test_micPlusAppRequestsSourceBeforeResolving() async throws {
        let harness = RecordingHarness()
        harness.permission.result = .granted
        harness.snapshot = harness.snapshot.withCaptureMode(.micPlusAppAudio)
        harness.coordinator.requestStart(mode: .micPlusAppAudio)
        await harness.waitFor { harness.coordinator.state.phase == .selectingAudioSource }
        let requestID = try XCTUnwrap(harness.coordinator.state.requestID)
        XCTAssertTrue(harness.engine.selections.isEmpty)
        harness.coordinator.provideAudioSource(requestID: requestID, source: AppPickerWindowController.AudioSource(app: nil, display: nil, name: "System", icon: nil))
        await harness.waitFor { harness.coordinator.state.phase == .recording }
        XCTAssertEqual(harness.session.starts.first?.source?.name, "System")
    }

    func test_missingModelApprovalRetryKeepsRequestAndSnapshot() async throws {
        let harness = RecordingHarness()
        harness.engine.result = .requiresDownload(.parakeet(modelID: "p", revision: "r"))
        harness.engine.engine = TestRecordingEngine(provider: .parakeet)
        harness.snapshot = SettingsSnapshot(provider: .parakeet, whisperModelID: "whisper-large-v3-turbo-q5_0", language: "en", captureMode: .micOnly, showNotifications: true, autoPaste: false)
        harness.coordinator.requestStart(mode: .micOnly)
        await harness.waitFor { if case .awaitingDownloadApproval = harness.coordinator.state.phase { return true }; return false }
        let id = try XCTUnwrap(harness.coordinator.state.requestID)
        harness.engine.result = .ready(harness.engine.engine)
        harness.coordinator.respondToDownloadPrompt(requestID: id, approved: true)
        await harness.waitFor { harness.coordinator.state.phase == .recording }
        XCTAssertEqual(harness.coordinator.state.requestID, id)
        XCTAssertEqual(harness.download.requirements, [.parakeet(modelID: "p", revision: "r")])
    }

    func test_stopDuringStartCancelsAndIgnoresLateSuccess() async throws {
        let harness = RecordingHarness()
        harness.session.startSuspended = true
        harness.coordinator.requestStart(mode: .micOnly)
        await harness.waitFor { harness.coordinator.state.phase == .starting }
        _ = try XCTUnwrap(harness.coordinator.state.requestID)
        harness.coordinator.stop()
        XCTAssertEqual(harness.coordinator.state.phase, .idle)
        harness.session.releaseStart()
        await Task.yield()
        XCTAssertNil(harness.coordinator.state.requestID)
        XCTAssertEqual(harness.session.cancelStarts, 1)
    }

    func test_finalAndStopAreExactlyOnceAndFinalizationOwnsIdleTransition() async throws {
        let harness = RecordingHarness()
        harness.coordinator.requestStart(mode: .micOnly)
        await harness.waitFor { harness.coordinator.state.phase == .recording }
        harness.coordinator.stop()
        harness.coordinator.stop()
        XCTAssertEqual(harness.coordinator.state.phase, .finalizing)
        XCTAssertNotNil(harness.session.emitFinal("hello"))
        XCTAssertNil(harness.session.emitFinal("duplicate"))
        XCTAssertEqual(harness.output.finalTexts, ["hello"])
        XCTAssertEqual(harness.coordinator.state.phase, .finalizing)
        harness.session.emitFinalizationComplete()
        harness.session.emitFinalizationComplete()
        XCTAssertEqual(harness.coordinator.state.phase, .idle)
        XCTAssertEqual(harness.session.stopCount, 1)
        XCTAssertEqual(harness.engine.activityChanges, [true, false])
    }

    func test_providerMismatchFailsBeforeSessionCreation() async {
        let harness = RecordingHarness()
        harness.engine.result = .ready(harness.engine.engine)
        harness.engine.engine = TestRecordingEngine(provider: .parakeet)
        harness.engine.result = .ready(harness.engine.engine)
        harness.snapshot = SettingsSnapshot(provider: .whisper, whisperModelID: "whisper-large-v3-turbo-q5_0", language: nil, captureMode: .micOnly, showNotifications: true, autoPaste: false)
        harness.coordinator.requestStart(mode: .micOnly)
        await harness.waitFor { harness.coordinator.state.phase == .idle }
        XCTAssertTrue(harness.session.starts.isEmpty)
        XCTAssertEqual(harness.output.cancelCount, 1)
    }

    func test_deniedMicrophonePermissionEmitsGuidanceAndReturnsIdleWithoutEngineWork() async throws {
        let harness = RecordingHarness()
        harness.permission.result = .deniedMicrophoneAlreadyDenied
        harness.coordinator.requestStart(mode: .micOnly)
        await harness.waitFor { harness.coordinator.state.phase == .idle }
        XCTAssertTrue(harness.engine.selections.isEmpty)
        XCTAssertTrue(harness.effects.contains(.showMicrophoneGuidance))
    }

    func test_deniedMicrophoneAfterRequestEmitsGuidanceAndReturnsIdle() async throws {
        let harness = RecordingHarness()
        harness.permission.result = .deniedMicrophoneAfterRequest
        harness.coordinator.requestStart(mode: .micOnly)
        await harness.waitFor { harness.coordinator.state.phase == .idle }
        XCTAssertEqual(harness.effects, [.showMicrophoneGuidance])
    }

    func test_deniedScreenRecordingEmitsGuidanceAndReturnsIdleWithoutEngineWork() async throws {
        let harness = RecordingHarness()
        harness.permission.result = .deniedScreenRecording
        harness.coordinator.requestStart(mode: .micPlusAppAudio)
        await harness.waitFor { harness.coordinator.state.phase == .idle }
        XCTAssertTrue(harness.engine.selections.isEmpty)
        XCTAssertTrue(harness.effects.contains(.showScreenRecordingGuidance))
    }

    func test_emptyAudioSourceListCancelsTheCurrentPickerRequest() async throws {
        let harness = try await makeAudioSourceSelectionHarness()
        let requestID = try XCTUnwrap(harness.coordinator.state.requestID)

        // An empty ScreenCaptureKit result has no valid source to provide.
        harness.coordinator.provideAudioSource(requestID: requestID, source: nil)

        XCTAssertEqual(harness.coordinator.state.phase, .idle)
        XCTAssertTrue(harness.engine.selections.isEmpty)
        XCTAssertTrue(harness.session.starts.isEmpty)
    }

    func testAudioSourceLoadErrorCancelsTheCurrentPickerRequest() async throws {
        let harness = try await makeAudioSourceSelectionHarness()
        let requestID = try XCTUnwrap(harness.coordinator.state.requestID)

        // Loader failures use the same nil-source cancellation contract as an
        // empty result; they must not fall through to engine resolution.
        harness.coordinator.provideAudioSource(requestID: requestID, source: nil)

        XCTAssertEqual(harness.coordinator.state.phase, .idle)
        XCTAssertTrue(harness.engine.selections.isEmpty)
    }

    func testPermissionRevocationCancelsTheCurrentPickerRequest() async throws {
        let harness = try await makeAudioSourceSelectionHarness()
        let requestID = try XCTUnwrap(harness.coordinator.state.requestID)

        // A permission change while ScreenCaptureKit is loading is delivered as
        // a failed picker request, never as a legacy start abandonment.
        harness.coordinator.provideAudioSource(requestID: requestID, source: nil)

        XCTAssertEqual(harness.coordinator.state.phase, .idle)
        XCTAssertTrue(harness.engine.selections.isEmpty)
    }

    func test_pickerCancelReturnsIdleWithoutEngineWork() async throws {
        let harness = try await makeAudioSourceSelectionHarness()
        let requestID = try XCTUnwrap(harness.coordinator.state.requestID)
        harness.coordinator.provideAudioSource(requestID: requestID, source: nil)

        XCTAssertEqual(harness.coordinator.state.phase, .idle)
        XCTAssertTrue(harness.engine.selections.isEmpty)
    }

    func test_stopBeforeSourceLoadCompletesIgnoresLateSource() async throws {
        let harness = try await makeAudioSourceSelectionHarness()
        let requestID = try XCTUnwrap(harness.coordinator.state.requestID)
        harness.coordinator.stop()

        // This models a delayed source-load completion arriving after Stop.
        harness.coordinator.provideAudioSource(
            requestID: requestID,
            source: AppPickerWindowController.AudioSource(app: nil, display: nil, name: "Late", icon: nil)
        )
        await Task.yield()

        XCTAssertEqual(harness.coordinator.state.phase, .idle)
        XCTAssertTrue(harness.engine.selections.isEmpty)
        XCTAssertTrue(harness.session.starts.isEmpty)
    }

    func test_duplicateStartAndDownloadDeclineCannotCreateSecondSession() async throws {
        let harness = RecordingHarness()
        harness.engine.result = .requiresDownload(.whisper(try XCTUnwrap(ModelCatalog.bundled().first)))
        harness.coordinator.requestStart(mode: .micOnly)
        harness.coordinator.requestStart(mode: .micOnly)
        await harness.waitFor { if case .awaitingDownloadApproval = harness.coordinator.state.phase { return true }; return false }
        let requestID = try XCTUnwrap(harness.coordinator.state.requestID)
        harness.coordinator.respondToDownloadPrompt(requestID: requestID, approved: false)
        XCTAssertEqual(harness.coordinator.state.phase, .idle)
        XCTAssertTrue(harness.session.starts.isEmpty)
    }

    private func makeAudioSourceSelectionHarness() async throws -> RecordingHarness {
        let harness = RecordingHarness()
        harness.snapshot = harness.snapshot.withCaptureMode(.micPlusAppAudio)
        harness.coordinator.requestStart(mode: .micPlusAppAudio)
        await harness.waitFor { harness.coordinator.state.phase == .selectingAudioSource }
        return harness
    }
}

@MainActor
private final class RecordingHarness: TranscriptionSessionFactory {
    let permission = RecordingPermissionFake()
    let engine = RecordingEngineFake()
    let download = RecordingDownloadFake()
    let session = RecordingSessionFake(provider: .whisper)
    let output = RecordingOutputFake()
    var snapshot = SettingsSnapshot(provider: .whisper, whisperModelID: "whisper-large-v3-turbo-q5_0", language: "en", captureMode: .micOnly, showNotifications: true, autoPaste: false)
    var effects: [StatusBarEffect] = []
    lazy var coordinator: RecordingSessionCoordinator = {
        let coordinator = RecordingSessionCoordinator(permission: permission, engine: engine, download: download, sessions: self, output: output, settingsSnapshot: { [weak self] in self!.snapshot })
        coordinator.onEvent = { [weak self] event in
            if case let .effect(effect) = event { self?.effects.append(effect) }
        }
        return coordinator
    }()

    func make(engine: any ASREngine) -> any TranscriptionSession { session.providerValue = engine.provider; return session }

    func waitFor(_ condition: @escaping () -> Bool) async {
        for _ in 0..<1_000 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("condition did not become true")
    }
}

@MainActor
private final class RecordingPermissionFake: RecordingPermissionAuthorizing {
    var result: StartPermissionResult = .granted
    private(set) var authorizeCount = 0
    func authorizeStart(mode: TranscriptionController.Mode) async -> StartPermissionResult {
        authorizeCount += 1
        return result
    }
    func resetAuthorizeCount() { authorizeCount = 0 }
}

@MainActor
private final class RecordingEngineFake: EngineResolving {
    var engine = TestRecordingEngine(provider: .whisper)
    var result: EngineResolution = .ready(TestRecordingEngine(provider: .whisper))
    var selections: [EngineSelection] = []
    var activityChanges: [Bool] = []
    func resolve(_ selection: EngineSelection, requestID: UUID) async -> EngineResolution { selections.append(selection); return result }
    func cancel(requestID: UUID) {}
    func recordingActivityChanged(_ active: Bool) { activityChanges.append(active) }
}

@MainActor
private final class RecordingDownloadFake: ModelRequirementDownloading {
    var requirements: [ModelRequirement] = []
    func download(_ requirement: ModelRequirement, requestID: UUID) async throws { requirements.append(requirement) }
    func cancel(requestID: UUID) {}
}

@MainActor
private final class RecordingOutputFake: OutputCoordinating {
    var finalTexts: [String] = []
    var cancelCount = 0
    func captureTarget() -> ApplicationIdentity? { ApplicationIdentity(processIdentifier: 2) }
    func setTarget(_ target: ApplicationIdentity?) {}
    func clearTarget() {}
    func handleFinal(text: String, context: OutputContext) -> OutputResult { finalTexts.append(text); return OutputResult(clipboardWritten: true, insertOutcome: .notAttempted, userMessage: "", permissionEffect: nil) }
    func cancel() { cancelCount += 1 }
    func handleAppAudioLost(showNotification: Bool) {}
    func handleFallbackToMicOnly(showNotification: Bool) {}
}

@MainActor
private final class RecordingSessionFake: TranscriptionSession {
    struct Start { let snapshot: SettingsSnapshot; let source: AppPickerWindowController.AudioSource? }
    var providerValue: ASRProvider
    var provider: ASRProvider { providerValue }
    var onPartial: (@Sendable @MainActor (String) -> Void)?
    var onFinal: (@Sendable @MainActor (String) -> OutputResult?)?
    var onMicLevel: (@Sendable @MainActor (AudioLevelMonitor.LevelData) -> Void)?
    var onAppLevel: (@Sendable @MainActor (AudioLevelMonitor.LevelData) -> Void)?
    var onAppAudioLost: (@Sendable @MainActor () -> Void)?
    var onFallbackToMicOnly: (@Sendable @MainActor () -> Void)?
    var onFinalizationComplete: (@Sendable @MainActor () -> Void)?
    var starts: [Start] = []
    var startSuspended = false
    var cancelStarts = 0
    var asyncCancelStarts = 0
    var cancelStartFailuresRemaining = 0
    var stopCount = 0
    var cancelSuspended = false
    var cancelStarted = false
    var stopSuspended = false
    var stopAndWaitStarted = false
    var stopAndWaitCount = 0
    var persistsMetrics = false
    let metricsStore = DelayedCoordinatorMetricsStore()
    var releasedSessions = 0
    var lastRequestID: UUID?
    private var continuation: CheckedContinuation<Void, Error>?
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var startEntered = false
    private var cancelContinuations: [CheckedContinuation<Void, Never>] = []
    private var cancelStartWaiter: CheckedContinuation<Void, Never>?
    private var stopContinuation: CheckedContinuation<Void, Never>?
    init(provider: ASRProvider) { providerValue = provider }
    func start(mode: TranscriptionController.Mode, audioSource: AppPickerWindowController.AudioSource?, settingsSnapshot: SettingsSnapshot) async throws {
        starts.append(Start(snapshot: settingsSnapshot, source: audioSource))
        if !startEntered {
            startEntered = true
            startWaiter?.resume()
            startWaiter = nil
        }
        if startSuspended { try await withCheckedThrowingContinuation { continuation = $0 } }
    }
    func stop() { stopCount += 1 }
    func requestCancelStart() -> SessionCleanup {
        cancelStarts += 1
        return SessionCleanup(task: Task { try await self.cancelStart() }, owner: self)
    }
    func stopAndWait() async {
        stopAndWaitCount += 1
        stopAndWaitStarted = true
        if stopSuspended { await withCheckedContinuation { continuation in stopContinuation = continuation } }
        if persistsMetrics { await metricsStore.record() }
        releasedSessions += 1
    }
    func cancelStart() async throws {
        asyncCancelStarts += 1
        cancelStarted = true
        cancelStartWaiter?.resume()
        cancelStartWaiter = nil
        if cancelSuspended {
            await withCheckedContinuation { continuation in cancelContinuations.append(continuation) }
        }
        if cancelStartFailuresRemaining > 0 {
            cancelStartFailuresRemaining -= 1
            throw ScreenCaptureLifecycleError.stopFailed
        }
        if persistsMetrics { await metricsStore.record() }
        releasedSessions += 1
    }
    func releaseStart() { continuation?.resume(); continuation = nil }
    func waitForStart() async {
        if startEntered { return }
        await withCheckedContinuation { startWaiter = $0 }
    }
    func waitForCancelStart() async {
        if cancelStarted { return }
        await withCheckedContinuation { cancelStartWaiter = $0 }
    }
    func releaseCancel() { cancelContinuations.isEmpty ? () : cancelContinuations.removeFirst().resume() }
    func releaseAllCancels() {
        let continuations = cancelContinuations
        cancelContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }
    func releaseStopAndWait() { stopContinuation?.resume(); stopContinuation = nil }
    @discardableResult
    func emitFinal(_ value: String) -> OutputResult? { onFinal?(value) ?? nil }
    func emitFinalizationComplete() { onFinalizationComplete?() }
}

private actor DelayedCoordinatorMetricsStore {
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private var releaseRequested = false
    private(set) var recordCount = 0

    func record() async {
        started = true
        startWaiter?.resume()
        startWaiter = nil
        if releaseRequested {
            releaseRequested = false
        } else {
            await withCheckedContinuation { continuation in releaseWaiter = continuation }
        }
        recordCount += 1
    }

    func waitForRecordStart() async {
        if started { return }
        await withCheckedContinuation { continuation in startWaiter = continuation }
    }

    func releaseRecord() {
        if let releaseWaiter {
            releaseWaiter.resume()
            self.releaseWaiter = nil
        } else {
            releaseRequested = true
        }
    }
}

private final class TestRecordingEngine: ASREngine, @unchecked Sendable {
    let provider: ASRProvider
    init(provider: ASRProvider) { self.provider = provider }
    func prepare() async throws {}
    func reset() async {}
    func process(_ buffer: AVAudioPCMBuffer, language: String?) async throws -> ASRPartial? { nil }
    func finalize(_ buffer: AVAudioPCMBuffer, language: String?) async throws -> ASRFinalSegment? { nil }
}
