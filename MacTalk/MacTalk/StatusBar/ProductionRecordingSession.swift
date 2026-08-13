import Foundation

@MainActor
final class ProductionTranscriptionSession: StructuredTranscriptionSession {
    private let controller: TranscriptionController

    init(controller: TranscriptionController) {
        self.controller = controller
    }

    var provider: ASRProvider { controller.provider }
    var onPartial: (@Sendable @MainActor (String) -> Void)? {
        get { controller.onPartial }
        set { controller.onPartial = newValue }
    }
    var onFinal: (@Sendable @MainActor (String) -> OutputResult?)? {
        get { controller.onFinal }
        set { controller.onFinal = newValue }
    }
    var onTerminalResult: (@Sendable @MainActor (TerminalTranscription) async -> TerminalDeliveryResult?)? {
        get { controller.onTerminalResult }
        set { controller.onTerminalResult = newValue }
    }
    var onMicLevel: (@Sendable @MainActor (AudioLevelMonitor.LevelData) -> Void)? {
        get { controller.onMicLevel }
        set { controller.onMicLevel = newValue }
    }
    var onAppLevel: (@Sendable @MainActor (AudioLevelMonitor.LevelData) -> Void)? {
        get { controller.onAppLevel }
        set { controller.onAppLevel = newValue }
    }
    var onAppAudioLost: (@Sendable @MainActor () -> Void)? {
        get { controller.onAppAudioLost }
        set { controller.onAppAudioLost = newValue }
    }
    var onFallbackToMicOnly: (@Sendable @MainActor () -> Void)? {
        get { controller.onFallbackToMicOnly }
        set { controller.onFallbackToMicOnly = newValue }
    }
    var onFinalizationComplete: (@Sendable @MainActor () -> Void)? {
        get { controller.onFinalizationComplete }
        set { controller.onFinalizationComplete = newValue }
    }

    func start(
        mode: TranscriptionController.Mode,
        audioSource: AppPickerWindowController.AudioSource?,
        settingsSnapshot: SettingsSnapshot
    ) async throws {
        try await controller.start(mode: mode, audioSource: audioSource, settingsSnapshot: settingsSnapshot)
    }

    func stop() { controller.stop() }
    func stopAndWait() async throws { try await controller.stopAndWait() }
    func requestCancelStart() -> SessionCleanup {
        controller.requestCancelStart()
    }
    func configure(requestContext: ASRRequestContext) {
        controller.configure(requestContext: requestContext)
    }
}

@MainActor
final class ProductionTranscriptionSessionFactory: TranscriptionSessionFactory {
    func make(engine: any ASREngine) -> any TranscriptionSession {
        let batteryMode = PerformanceMonitor.currentBatteryMode
        return ProductionTranscriptionSession(
            controller: TranscriptionController(engine: engine, batteryModeSnapshot: batteryMode)
        )
    }
}
