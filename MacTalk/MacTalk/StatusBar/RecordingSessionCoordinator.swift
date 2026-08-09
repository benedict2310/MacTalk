import Foundation

@MainActor
protocol TranscriptionSession: AnyObject {
    var provider: ASRProvider { get }
    var onPartial: (@Sendable @MainActor (String) -> Void)? { get set }
    var onFinal: (@Sendable @MainActor (String) -> OutputResult?)? { get set }
    var onMicLevel: (@Sendable @MainActor (AudioLevelMonitor.LevelData) -> Void)? { get set }
    var onAppLevel: (@Sendable @MainActor (AudioLevelMonitor.LevelData) -> Void)? { get set }
    var onAppAudioLost: (@Sendable @MainActor () -> Void)? { get set }
    var onFallbackToMicOnly: (@Sendable @MainActor () -> Void)? { get set }
    var onFinalizationComplete: (@Sendable @MainActor () -> Void)? { get set }

    func start(
        mode: TranscriptionController.Mode,
        audioSource: AppPickerWindowController.AudioSource?,
        settingsSnapshot: SettingsSnapshot
    ) async throws
    func stop()
    func stopAndWait() async
    /// Cancels start without making a synchronous caller wait for persistence.
    func requestCancelStart()
    /// Awaits cancellation and its terminal metrics persistence.
    func cancelStart() async
}

@MainActor
protocol TranscriptionSessionFactory: AnyObject {
    func make(engine: any ASREngine) -> any TranscriptionSession
}

@MainActor
protocol RecordingSessionCoordinating: AnyObject {
    var state: RecordingSessionState { get }
    var onEvent: ((RecordingSessionEvent) -> Void)? { get set }

    func requestStart(mode: TranscriptionController.Mode)
    func toggle(mode: TranscriptionController.Mode)
    func provideAudioSource(requestID: UUID, source: AppPickerWindowController.AudioSource?)
    func respondToDownloadPrompt(requestID: UUID, approved: Bool)
    func stop()
    func cleanup() async
}

/// Owns the complete lifecycle of one recording request. Every asynchronous
/// operation is tagged with the request UUID; cancellation is only an
/// optimization and never the stale-result check.
@MainActor
final class RecordingSessionCoordinator: RecordingSessionCoordinating {
    private struct RequestContext {
        let id: UUID
        let mode: TranscriptionController.Mode
        let settings: SettingsSnapshot
        let target: ApplicationIdentity?
        var source: AppPickerWindowController.AudioSource?
        var selection: EngineSelection?
        var session: (any TranscriptionSession)?
        var didStopSession = false
        var didOutputFinal = false
    }

    private let permission: any RecordingPermissionAuthorizing
    private let engine: any EngineResolving
    private let download: any ModelRequirementDownloading
    private let sessions: any TranscriptionSessionFactory
    private let output: any OutputCoordinating
    private let audioSources: (any AppAudioSourceCoordinating)?
    private let settingsSnapshot: @MainActor () -> SettingsSnapshot
    private var request: RequestContext?
    private var work: Task<Void, Never>?
    private var engineActivityActive = false
    private(set) var state: RecordingSessionState = .idle
    var onEvent: ((RecordingSessionEvent) -> Void)?

    init(
        permission: any RecordingPermissionAuthorizing,
        engine: any EngineResolving,
        download: any ModelRequirementDownloading,
        sessions: any TranscriptionSessionFactory,
        output: any OutputCoordinating,
        settingsSnapshot: @escaping @MainActor () -> SettingsSnapshot,
        audioSources: (any AppAudioSourceCoordinating)? = nil
    ) {
        self.permission = permission
        self.engine = engine
        self.download = download
        self.sessions = sessions
        self.output = output
        self.audioSources = audioSources
        self.settingsSnapshot = settingsSnapshot
    }

    func requestStart(mode: TranscriptionController.Mode) {
        guard state.phase == .idle else { return }
        let snapshot = settingsSnapshot().withCaptureMode(
            mode == .micPlusAppAudio ? .micPlusAppAudio : .micOnly
        )
        let id = UUID()
        request = RequestContext(
            id: id,
            mode: mode,
            settings: snapshot,
            target: output.captureTarget()
        )
        transition(.authorizing)
        work = Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await permission.authorizeStart(mode: mode)
            guard self.owns(id), case .authorizing = self.state.phase else { return }
            switch result {
            case .granted:
                if mode == .micPlusAppAudio {
                    self.transition(.selectingAudioSource)
                    self.loadAudioSources(id)
                } else {
                    self.resolve(id)
                }
            case .deniedMicrophoneAfterRequest, .deniedMicrophoneAlreadyDenied:
                self.emit(.effect(.showMicrophoneGuidance))
                self.abort(id)
            case .deniedScreenRecording:
                self.emit(.effect(.showScreenRecordingGuidance))
                self.abort(id)
            }
        }
    }

    func toggle(mode: TranscriptionController.Mode) {
        switch state.phase {
        case .idle:
            requestStart(mode: mode)
        case .authorizing, .selectingAudioSource, .awaitingDownloadApproval,
             .downloadingModel, .resolvingEngine, .starting, .recording:
            stop()
        case .finalizing:
            // Finalization owns the transition back to idle; a second toggle
            // cannot legally stop or start another request in this phase.
            return
        }
    }

    private func loadAudioSources(_ id: UUID) {
        guard owns(id), case .selectingAudioSource = state.phase else { return }
        guard let audioSources else {
            emit(.requestAudioSource(requestID: id, sources: []))
            return
        }
        let loader = audioSources
        work = Task { @MainActor [weak self] in
            do {
                let sources = try await loader.loadSources()
                guard let self, self.owns(id), case .selectingAudioSource = self.state.phase else { return }
                self.emit(.requestAudioSource(requestID: id, sources: sources))
            } catch is CancellationError {
                self?.abort(id)
            } catch {
                guard let self, self.owns(id) else { return }
                self.fail(id, message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    func provideAudioSource(requestID: UUID, source: AppPickerWindowController.AudioSource?) {
        guard owns(requestID), case .selectingAudioSource = state.phase else { return }
        guard let source else {
            abort(requestID)
            return
        }
        request?.source = source
        resolve(requestID)
    }

    func respondToDownloadPrompt(requestID: UUID, approved: Bool) {
        guard owns(requestID), case let .awaitingDownloadApproval(requirement) = state.phase else { return }
        guard approved else {
            abort(requestID)
            return
        }
        transition(.downloadingModel(requirement))
        let download = self.download
        work = Task { @MainActor [weak self] in
            do {
                try await download.download(requirement, requestID: requestID)
                guard let self, self.owns(requestID), case .downloadingModel = self.state.phase else { return }
                self.resolve(requestID)
            } catch is CancellationError {
                self?.abort(requestID)
            } catch {
                guard let self, self.owns(requestID) else { return }
                self.fail(requestID, message: error.localizedDescription)
            }
        }
    }

    func stop() {
        guard let request else { return }
        switch state.phase {
        case .idle, .finalizing:
            return
        case .recording:
            work?.cancel()
            work = nil
            if !request.didStopSession {
                self.request?.didStopSession = true
                transition(.finalizing)
                request.session?.stop()
            }
        case .authorizing, .selectingAudioSource, .awaitingDownloadApproval,
             .downloadingModel, .resolvingEngine, .starting:
            abort(request.id)
        }
    }

    func cleanup() async {
        guard let request else {
            work?.cancel()
            work = nil
            engine.recordingActivityChanged(false)
            engineActivityActive = false
            state = .idle
            return
        }

        // Keep the request/session retained until the session has completed its
        // terminal metrics write. Cleanup is an explicit async durability
        // boundary; deinit remains best effort in TranscriptionController.
        let session = request.session
        switch state.phase {
        case .recording, .finalizing:
            cancelOwnedWork(request.id)
            await session?.stopAndWait()
        default:
            // Let the session invalidate its own start operation first. This
            // avoids dropping a suspended start task before it can persist its
            // terminal report.
            await session?.cancelStart()
            // Invalidate coordinator callbacks before cancelling the start
            // task; retain the request until all cleanup side effects finish.
            transition(.idle, requestID: nil, mode: nil, selection: nil)
            cancelOwnedWork(request.id)
        }
        output.cancel()
        self.request = nil
        transition(.idle, requestID: nil, mode: nil, selection: nil)
    }

    private func resolve(_ id: UUID) {
        guard owns(id), let selection = selection(for: request!.settings) else {
            fail(id, message: "The selected engine is unavailable.")
            return
        }
        request?.selection = selection
        transition(.resolvingEngine(selection), selection: selection)
        let engine = self.engine
        work = Task { @MainActor [weak self] in
            let result = await engine.resolve(selection, requestID: id)
            guard let self, self.owns(id), case .resolvingEngine = self.state.phase else { return }
            switch result {
            case let .ready(asr):
                guard asr.provider == selection.provider else {
                    self.fail(id, message: "The loaded engine does not match the selected provider.")
                    return
                }
                self.start(id, engine: asr, selection: selection)
            case let .requiresDownload(requirement):
                self.transition(.awaitingDownloadApproval(requirement), selection: selection)
                self.emit(.confirmDownload(requestID: id, requirement: requirement))
            case let .failed(message): self.fail(id, message: message)
            case .stale, .cancelled: self.abort(id)
            }
        }
    }

    private func start(_ id: UUID, engine: any ASREngine, selection: EngineSelection) {
        guard owns(id), let context = request else { return }
        guard engine.provider == context.settings.provider,
              engine.provider == selection.provider else {
            fail(id, message: "The loaded engine does not match the selected provider.")
            return
        }
        let session = sessions.make(engine: engine)
        guard session.provider == selection.provider else {
            fail(id, message: "The transcription session does not match the selected provider.")
            return
        }
        request?.session = session
        wire(session: session, requestID: id)
        transition(.starting, selection: selection)
        work = Task { @MainActor [weak self, weak session] in
            do {
                try await session?.start(
                    mode: context.mode,
                    audioSource: context.source,
                    settingsSnapshot: context.settings
                )
                guard let self, self.owns(id), case .starting = self.state.phase else {
                    return
                }
                self.transition(.recording, selection: selection)
            } catch is CancellationError {
                self?.abort(id)
            } catch {
                self?.fail(id, message: error.localizedDescription)
            }
        }
    }

    private func wire(session: any TranscriptionSession, requestID: UUID) {
        session.onPartial = { [weak self] text in
            guard let self, self.owns(requestID), self.state.phase == .recording else { return }
            self.emit(.partial(text))
        }
        session.onFinal = { [weak self] text in
            self?.receiveFinal(text, requestID: requestID)
        }
        session.onMicLevel = { [weak self] level in
            guard let self, self.owns(requestID) else { return }
            self.emit(.micLevel(level))
        }
        session.onAppLevel = { [weak self] level in
            guard let self, self.owns(requestID) else { return }
            self.emit(.appLevel(level))
        }
        session.onAppAudioLost = { [weak self] in
            guard let self, self.owns(requestID) else { return }
            self.emit(.appAudioLost)
        }
        session.onFallbackToMicOnly = { [weak self] in
            guard let self, self.owns(requestID) else { return }
            self.emit(.fallbackToMicOnly)
        }
        session.onFinalizationComplete = { [weak self] in
            guard let self, self.owns(requestID), self.state.phase == .finalizing else { return }
            self.work = nil
            self.request = nil
            self.transition(.idle, requestID: nil, mode: nil, selection: nil)
        }
    }

    @discardableResult
    private func receiveFinal(_ text: String, requestID: UUID) -> OutputResult? {
        guard owns(requestID), state.phase == .finalizing,
              request?.didOutputFinal == false,
              let context = request else { return nil }
        request?.didOutputFinal = true
        emit(.finalText(text))
        let result = output.handleFinal(
            text: text,
            context: OutputContext(
                target: context.target,
                autoPastePreference: context.settings.autoPaste,
                showNotifications: context.settings.showNotifications
            )
        )
        emit(.finalOutput(result))
        return result
    }

    private func fail(_ id: UUID, message: String) {
        guard owns(id) else { return }
        emit(.error(.message(message)))
        abort(id)
    }

    private func abort(_ id: UUID) {
        guard owns(id) else { return }
        cancelOwnedWork(id)
        let session = request?.session
        request?.session = nil
        session?.requestCancelStart()
        output.cancel()
        request = nil
        transition(.idle, requestID: nil, mode: nil, selection: nil)
    }

    private func cancelOwnedWork(_ id: UUID) {
        work?.cancel()
        work = nil
        engine.cancel(requestID: id)
        download.cancel(requestID: id)
        audioSources?.cleanup()
    }

    private func owns(_ id: UUID) -> Bool { request?.id == id }

    private func selection(for settings: SettingsSnapshot) -> EngineSelection? {
        switch settings.provider {
        case .whisper: return settings.whisperModel.map(EngineSelection.whisper)
        case .parakeet: return .parakeet
        }
    }

    private func transition(
        _ phase: RecordingPhase,
        requestID: UUID? = nil,
        mode: TranscriptionController.Mode? = nil,
        selection: EngineSelection? = nil
    ) {
        let nextEngineActivity = phase != .idle
        if nextEngineActivity != engineActivityActive {
            engine.recordingActivityChanged(nextEngineActivity)
            engineActivityActive = nextEngineActivity
        }
        if phase == .idle {
            state = .idle
            emit(.stateChanged(state))
            return
        }
        let id = requestID ?? request?.id
        let actualMode = mode ?? request?.mode
        let actualSelection = selection ?? request?.selection
        state = RecordingSessionState(phase: phase, requestID: id, mode: actualMode, selection: actualSelection)
        emit(.stateChanged(state))
    }

    private func emit(_ event: RecordingSessionEvent) { onEvent?(event) }
}
