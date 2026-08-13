import AppKit
import AVFoundation
import Foundation
@preconcurrency import ScreenCaptureKit

@MainActor
protocol PermissionClient: AnyObject {
    var microphoneState: MicrophonePermissionState { get }
    var screenRecordingGranted: Bool { get }
    var accessibilityTrusted: Bool { get }
    var accessibilityDiagnostics: PermissionDiagnostics { get }

    func requestMicrophone() async -> Bool
    func requestAccessibilitySystemPrompt() async -> Bool
    func resetAccessibilityApproval(reason: String) -> Bool
    func openMicrophoneSettings()
    func openScreenRecordingSettings()
    func openAccessibilitySettings()
}

@MainActor
protocol ClipboardWriting: AnyObject {
    @discardableResult
    func write(_ text: String) -> Bool
}

@MainActor
protocol TextInserting: AnyObject {
    func insert(_ text: String) -> AutoInsertResult
}

@MainActor
protocol WorkspaceReading: AnyObject {
    var frontmostApplication: ApplicationIdentity? { get }
    var activeApplications: [ApplicationIdentity] { get }
}

@MainActor
protocol NotificationSubmitting: AnyObject {
    func submit(_ event: AppNotificationEvent, enabled: Bool)
}

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

@MainActor
protocol StatusBarSettingsReading: AnyObject {
    var snapshot: SettingsSnapshot { get }
    func setAutoPaste(_ enabled: Bool)
    func setWhisperModelID(_ id: String)
    func setProvider(_ provider: ASRProvider)
}

@MainActor
final class SystemPermissionClient: PermissionClient {
    typealias AccessibilityPromptRequester = @MainActor (
        @escaping @MainActor @Sendable (Bool) -> Void
    ) -> Void

    private let accessibilityTimeout: TimeInterval
    private let accessibilityPromptRequester: AccessibilityPromptRequester

    init(
        accessibilityTimeout: TimeInterval = 60,
        accessibilityPromptRequester: @escaping AccessibilityPromptRequester = { completion in
            Permissions.requestAccessibilityPermission(completion: completion)
        }
    ) {
        self.accessibilityTimeout = accessibilityTimeout
        self.accessibilityPromptRequester = accessibilityPromptRequester
    }

    var microphoneState: MicrophonePermissionState { Permissions.microphonePermissionState() }
    var screenRecordingGranted: Bool { Permissions.checkScreenRecordingPermission() }
    var accessibilityTrusted: Bool { Permissions.isAccessibilityTrusted() }
    var accessibilityDiagnostics: PermissionDiagnostics { Permissions.getAccessibilityDiagnostics() }

    func requestMicrophone() async -> Bool {
        await withCheckedContinuation { continuation in
            Permissions.ensureMic { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    func requestAccessibilitySystemPrompt() async -> Bool {
        let pending = AccessibilityPromptCompletion()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                pending.start(
                    continuation: continuation,
                    timeout: accessibilityTimeout,
                    requester: accessibilityPromptRequester
                )
            }
        }, onCancel: {
            Task { @MainActor in pending.finish(false) }
        })
    }

    func resetAccessibilityApproval(reason: String) -> Bool {
        Permissions.resetAccessibilityApproval(reason: reason)
    }

    func openMicrophoneSettings() { Permissions.openMicrophoneSettings() }
    func openScreenRecordingSettings() { Permissions.openScreenRecordingSettings() }
    func openAccessibilitySettings() { Permissions.openAccessibilitySettings() }
}

/// Owns one checked continuation and its timeout. Completion is idempotent so
/// grant/denial callbacks racing a timeout cannot resume twice.
@MainActor
private final class AccessibilityPromptCompletion {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var timeoutTask: Task<Void, Never>?

    func start(
        continuation: CheckedContinuation<Bool, Never>,
        timeout: TimeInterval,
        requester: SystemPermissionClient.AccessibilityPromptRequester
    ) {
        self.continuation = continuation
        timeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(max(timeout, 0) * 1_000_000_000))
            } catch {
                return
            }
            self?.finish(false)
        }
        requester { [weak self] granted in
            self?.finish(granted)
        }
    }

    func finish(_ granted: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        continuation.resume(returning: granted)
    }
}

@MainActor
final class SystemClipboardWriter: ClipboardWriting {
    func write(_ text: String) -> Bool {
        ClipboardManager.setClipboard(text)
        return true
    }
}

@MainActor
final class SystemTextInserter: TextInserting {
    private let insertClipboardText: @MainActor (String) -> AutoInsertResult

    init(insertClipboardText: @escaping @MainActor (String) -> AutoInsertResult = { text in
        AutoInsertManager.insertClipboardText(text)
    }) {
        self.insertClipboardText = insertClipboardText
    }

    func insert(_ text: String) -> AutoInsertResult {
        insertClipboardText(text)
    }
}

@MainActor
final class SystemWorkspaceReader: WorkspaceReading {
    private let workspace: NSWorkspace
    private let processIdentifier: pid_t

    init(workspace: NSWorkspace = .shared, processIdentifier: pid_t = ProcessInfo.processInfo.processIdentifier) {
        self.workspace = workspace
        self.processIdentifier = processIdentifier
    }

    var frontmostApplication: ApplicationIdentity? {
        workspace.frontmostApplication.map(ApplicationIdentity.init)
    }

    var activeApplications: [ApplicationIdentity] {
        workspace.runningApplications
            .filter { $0.isActive && $0.processIdentifier != processIdentifier }
            .map(ApplicationIdentity.init)
    }
}

@MainActor
final class SystemNotificationSubmitter: NotificationSubmitting {
    private let manager: NotificationManager

    init(manager: NotificationManager) {
        self.manager = manager
    }

    func submit(_ event: AppNotificationEvent, enabled: Bool) {
        manager.submit(event, enabled: enabled)
    }
}

@MainActor
final class SystemStatusBarSettings: StatusBarSettingsReading {
    private let settings: AppSettings

    init(settings: AppSettings = .shared) {
        self.settings = settings
    }

    var snapshot: SettingsSnapshot { settings.snapshot }
    func setAutoPaste(_ enabled: Bool) { settings.setAutoPaste(enabled) }
    func setWhisperModelID(_ id: String) { settings.setWhisperModelID(id) }
    func setProvider(_ provider: ASRProvider) { settings.provider = provider }
}

@MainActor
struct StatusBarDependencies {
    let settings: any StatusBarSettingsReading
    let permissionFlow: any (PermissionFlowCoordinating & RecordingPermissionAuthorizing)
    let output: any OutputCoordinating
    let appAudioSource: any AppAudioSourceCoordinating
    let shortcut: any ShortcutCoordinating
    let engine: any EngineLifecycleCoordinating
    let download: any (ModelDownloadCoordinating & ModelRequirementDownloading)
    let sessions: any TranscriptionSessionFactory
    let permissionClient: any PermissionClient
    let macTeach: MacTeachCoordinator?
    let pipelineDiagnostics: any PipelineDiagnosticsClient

    init(
        settings: any StatusBarSettingsReading,
        permissionFlow: any (PermissionFlowCoordinating & RecordingPermissionAuthorizing),
        output: any OutputCoordinating,
        appAudioSource: any AppAudioSourceCoordinating,
        shortcut: any ShortcutCoordinating,
        engine: any EngineLifecycleCoordinating,
        download: any (ModelDownloadCoordinating & ModelRequirementDownloading),
        sessions: any TranscriptionSessionFactory,
        permissionClient: any PermissionClient,
        macTeach: MacTeachCoordinator? = nil,
        pipelineDiagnostics: any PipelineDiagnosticsClient
    ) {
        self.settings = settings
        self.permissionFlow = permissionFlow
        self.output = output
        self.appAudioSource = appAudioSource
        self.shortcut = shortcut
        self.engine = engine
        self.download = download
        self.sessions = sessions
        self.permissionClient = permissionClient
        self.macTeach = macTeach
        self.pipelineDiagnostics = pipelineDiagnostics
    }

    static func live(notificationManager: NotificationManager) -> StatusBarDependencies {
        let settings = SystemStatusBarSettings()
        let permissionClient = SystemPermissionClient()
        let permissionFlow = PermissionFlowCoordinator(
            client: permissionClient,
            storedAutoPaste: settings.snapshot.autoPaste
        )
        let output = OutputCoordinator(
            clipboardWriter: SystemClipboardWriter(),
            textInserter: SystemTextInserter(),
            workspaceReader: SystemWorkspaceReader(),
            notifications: SystemNotificationSubmitter(manager: notificationManager),
            permissionFlow: permissionFlow
        )
        let engine = EngineLifecycleCoordinator(
            loader: DefaultEngineSelectionLoader(),
            availability: { selection in
                switch selection.provider {
                case .whisper:
                    guard let spec = ModelCatalog.findById(selection.modelID), spec.sha256 == selection.revision else { return false }
                    return (try? ModelIntegrityVerifier.validate(source: ModelStore.path(for: spec), spec: spec)) != nil
                case .parakeet:
                    return ParakeetBootstrap.shared.modelsAvailable()
                }
            }
        )
        return StatusBarDependencies(
            settings: settings,
            permissionFlow: permissionFlow,
            output: output,
            appAudioSource: AppAudioSourceCoordinator(client: SystemShareableContentClient()),
            shortcut: ShortcutCoordinator(registrar: SystemHotkeyRegistrar(), reader: UserDefaultsShortcutConfigurationReader()),
            engine: engine,
            download: ModelDownloadCoordinator(client: ProductionModelDownloadClient()),
            sessions: ProductionTranscriptionSessionFactory(),
            permissionClient: permissionClient,
            macTeach: try? MacTeachCoordinator.makeDefault(),
            pipelineDiagnostics: SystemPipelineDiagnosticsClient()
        )
    }
}

@MainActor
final class SystemShareableContentClient: ShareableContentClient {
    init() {}

    func loadShareableContent(timeout: TimeInterval) async throws -> ShareableContentSnapshot {
        let content: SCShareableContent
        do {
            content = try await withTimeout(seconds: timeout) {
                try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            }
        } catch is TimeoutError {
            throw ScreenCaptureError.timeout
        }

        let windowOwners = Set(content.windows.compactMap { $0.owningApplication?.bundleIdentifier })
        var candidates: [ShareableContentSource] = []
        if let display = content.displays.first {
            candidates.append(ShareableContentSource(
                identity: "system",
                source: .systemAudio(display: display),
                ownsWindow: true,
                isSystemAudio: true
            ))
        }
        candidates += content.applications.map { app in
            ShareableContentSource(
                identity: app.bundleIdentifier,
                source: .fromApp(app),
                ownsWindow: windowOwners.contains(app.bundleIdentifier),
                isSystemAudio: false
            )
        }
        return ShareableContentSnapshot(sources: candidates)
    }
}
