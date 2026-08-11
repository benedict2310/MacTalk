import XCTest
@testable import MacTalk

@MainActor
final class StatusBarControllerTests: XCTestCase {
    @MainActor
    final class PipelineDiagnosticsClientFake: PipelineDiagnosticsClient {
        private(set) var copyCount = 0
        var result = true

        func copyPerformanceReport() async -> Bool {
            copyCount += 1
            return result
        }
    }

    func test_copyPerformanceReportUsesDiagnosticsClientOnly() async {
        let diagnostics = PipelineDiagnosticsClientFake()
        let output = OutputFake()
        let settings = SettingsFake()
        let permissionFlow = PermissionFlowFake()
        let controller = StatusBarController(dependencies: StatusBarDependencies(
            settings: settings, permissionFlow: permissionFlow, output: output,
            appAudioSource: AppAudioFake(), shortcut: ShortcutFake(), engine: EngineFake(),
            download: DownloadFake(), sessions: SessionsFake(), permissionClient: PermissionClientFake(),
            pipelineDiagnostics: diagnostics
        ))
        controller.copyPerformanceReport()
        await Task.yield()
        XCTAssertEqual(diagnostics.copyCount, 1)
        XCTAssertEqual(output.callCount, 0)
        XCTAssertEqual(settings.autoPasteSetCount, 0)
        XCTAssertEqual(permissionFlow.autoPasteCallCount, 0)
    }

    func test_finalizingKeepsStopEnabledForExplicitRetirementRetry() {
        let state = StatusBarViewStateReducer.reduce(
            recording: RecordingSessionState(phase: .finalizing, requestID: UUID(), mode: .micOnly, selection: nil),
            settings: SettingsSnapshot(provider: .whisper, whisperModelID: "model", language: "en", captureMode: .micOnly, showNotifications: false, autoPaste: false),
            permission: PermissionViewState(microphone: .granted, screenRecordingGranted: true, accessibilityTrusted: true, effectiveAutoPaste: false),
            download: .idle,
            shortcuts: .empty
        )
        XCTAssertTrue(state.stopEnabled)
    }

    func test_statusBarIntentsAreStableTypedValues() {
        XCTAssertEqual(StatusBarIntent.startMicOnly, .startMicOnly)
        XCTAssertNotEqual(StatusBarIntent.startMicOnly, .startMicPlusAppAudio)
        XCTAssertEqual(StatusBarIntent.stop, .stop)
        XCTAssertNotEqual(StatusBarIntent.startMicOnly, .toggleMicOnly)
        XCTAssertNotEqual(StatusBarIntent.startMicPlusAppAudio, .toggleMicPlusAppAudio)
    }

    func test_applicationIdentityDoesNotRetainWorkspaceObjects() {
        let identity = ApplicationIdentity(processIdentifier: 42, bundleIdentifier: "com.example.Editor", displayName: "Editor")
        XCTAssertEqual(identity.processIdentifier, 42)
        XCTAssertEqual(identity.bundleIdentifier, "com.example.Editor")
        XCTAssertEqual(identity.displayName, "Editor")
    }

    func test_viewStateCapturesEffectiveAutoPasteSeparatelyFromStoredPreference() {
        let state = StatusBarViewState(recordingPhase: .idle, startEnabled: true, stopEnabled: false,
            recordingIcon: false, provider: .whisper, whisperModelID: "model", effectiveAutoPaste: false)
        XCTAssertTrue(state.startEnabled)
        XCTAssertFalse(state.effectiveAutoPaste)
    }
}

@MainActor
private final class SettingsFake: StatusBarSettingsReading {
    var snapshot = SettingsSnapshot(provider: .whisper, whisperModelID: "model", language: "en", captureMode: .micOnly, showNotifications: false, autoPaste: false)
    private(set) var autoPasteSetCount = 0
    func setAutoPaste(_ enabled: Bool) { autoPasteSetCount += 1; snapshot.autoPaste = enabled }
    func setWhisperModelID(_ id: String) { snapshot.whisperModelID = id }
    func setProvider(_ provider: ASRProvider) { snapshot.provider = provider }
}

@MainActor
private final class PermissionClientFake: PermissionClient {
    var microphoneState: MicrophonePermissionState = .granted
    var screenRecordingGranted = true
    var accessibilityTrusted = true
    var accessibilityDiagnostics = PermissionDiagnostics(bundleIdentifier: "com.example", teamIdentifier: "TEAM", isAdHocSigned: false, isRunningFromXcode: false, executablePath: "/tmp/test", isAccessibilityTrusted: true)
    func requestMicrophone() async -> Bool { true }
    func requestAccessibilitySystemPrompt() async -> Bool { true }
    func resetAccessibilityApproval(reason: String) -> Bool { true }
    func openMicrophoneSettings() {}
    func openScreenRecordingSettings() {}
    func openAccessibilitySettings() {}
}

@MainActor
private final class PermissionFlowFake: PermissionFlowCoordinating, RecordingPermissionAuthorizing {
    var effectiveAutoPaste = false
    private(set) var autoPasteCallCount = 0
    func refresh(storedAutoPaste: Bool) -> PermissionViewState { PermissionViewState(microphone: .granted, screenRecordingGranted: true, accessibilityTrusted: true, effectiveAutoPaste: storedAutoPaste) }
    func requestEnableAutoPaste() async -> AutoPasteEnableResult { autoPasteCallCount += 1; return .enabled }
    func permissionDeniedByInsert(at now: Date) -> AccessibilityPromptDecision { fatalError() }
    func recordSuccessfulInsert() {}
    func statusReport() -> PermissionStatusReport { fatalError() }
    func authorizeStart(mode: TranscriptionController.Mode) async -> StartPermissionResult { fatalError() }
}

@MainActor
private final class OutputFake: OutputCoordinating {
    private(set) var callCount = 0
    func captureTarget() -> ApplicationIdentity? { nil }
    func setTarget(_ target: ApplicationIdentity?) {}
    func clearTarget() {}
    func handleFinal(text: String, context: OutputContext) -> OutputResult { callCount += 1; return OutputResult(clipboardWritten: false, insertOutcome: .notAttempted, userMessage: "", permissionEffect: nil) }
    func cancel() { callCount += 1 }
    func handleAppAudioLost(showNotification: Bool) { callCount += 1 }
    func handleFallbackToMicOnly(showNotification: Bool) { callCount += 1 }
}

@MainActor private final class AppAudioFake: AppAudioSourceCoordinating {
    func loadSources() async throws -> [AppPickerWindowController.AudioSource] { [] }
    func cleanup() {}
}
@MainActor private final class ShortcutFake: ShortcutCoordinating {
    var onIntent: ((StatusBarIntent) -> Void)?
    var configuration = ShortcutConfiguration.empty
    func reload() {}
    func cleanup() {}
}
@MainActor private final class EngineFake: EngineLifecycleCoordinating {
    var state = EngineLifecycleState.empty
    var onEffect: ((StatusBarEffect) -> Void)?
    func resolve(_ selection: EngineSelection, requestID: UUID) async -> EngineResolution { fatalError() }
    func cancel(requestID: UUID) {}
    func recordingActivityChanged(_ active: Bool) {}
    func prewarm(_ selection: EngineSelection) {}
    func settingsChanged(to snapshot: SettingsSnapshot, recordingActive: Bool) {}
    func clear() {}
}
@MainActor private final class DownloadFake: ModelDownloadCoordinating, ModelRequirementDownloading {
    var state = ModelDownloadViewState.idle
    var onStateChanged: ((ModelDownloadViewState) -> Void)?
    func download(_ requirement: ModelRequirement, requestID: UUID) async throws {}
    func cancel(requestID: UUID) {}
}
@MainActor private final class SessionsFake: TranscriptionSessionFactory {
    func make(engine: any ASREngine) -> any TranscriptionSession { SessionFake() }
}
@MainActor private final class SessionFake: TranscriptionSession {
    let provider: ASRProvider = .whisper
    var onPartial: (@Sendable @MainActor (String) -> Void)?
    var onFinal: (@Sendable @MainActor (String) -> OutputResult?)?
    var onMicLevel: (@Sendable @MainActor (AudioLevelMonitor.LevelData) -> Void)?
    var onAppLevel: (@Sendable @MainActor (AudioLevelMonitor.LevelData) -> Void)?
    var onAppAudioLost: (@Sendable @MainActor () -> Void)?
    var onFallbackToMicOnly: (@Sendable @MainActor () -> Void)?
    var onFinalizationComplete: (@Sendable @MainActor () -> Void)?
    func start(mode: TranscriptionController.Mode, audioSource: AppPickerWindowController.AudioSource?, settingsSnapshot: SettingsSnapshot) async throws {}
    func stop() {}
    func stopAndWait() async throws {}
    func requestCancelStart() -> SessionCleanup { SessionCleanup(task: Task {}, owner: self) }
}
