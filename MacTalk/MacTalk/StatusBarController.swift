import AppKit

/// AppKit composition root for the status bar. Business state and system side
/// effects belong to the injected coordinators; this type only routes intents,
/// owns windows, and renders coordinator events.
@MainActor
final class StatusBarController {
    private var statusItem: NSStatusItem?
    private var menuPresenter: StatusMenuPresenter?
    private var hudController: HUDWindowController?
    private var settingsController: SettingsWindowController?
    private var appPickerController: AppPickerWindowController?
    private let dependencies: StatusBarDependencies
    private lazy var recording: RecordingSessionCoordinator = {
        let settingsReader = self.dependencies.settings
        let coordinator = RecordingSessionCoordinator(
            permission: dependencies.permissionFlow,
            engine: dependencies.engine,
            download: dependencies.download,
            sessions: dependencies.sessions,
            output: dependencies.output,
            settingsSnapshot: { settingsReader.snapshot },
            audioSources: dependencies.appAudioSource
        )
        coordinator.onEvent = { [weak self] event in self?.handle(event) }
        return coordinator
    }()
    private nonisolated(unsafe) var notificationTokens: [NSObjectProtocol] = []
    private var lastSettingsSnapshot: SettingsSnapshot?
    private var isShown = false

    init(
        notificationManager: NotificationManager = .shared,
        dependencies: StatusBarDependencies? = nil
    ) {
        self.dependencies = dependencies ?? .live(notificationManager: notificationManager)
        self.dependencies.engine.onEffect = { [weak self] effect in self?.handle(effect) }
        installObservers()
        self.dependencies.shortcut.onIntent = { [weak self] intent in self?.handle(intent) }
    }

    deinit {
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
    }

    func show() {
        guard !isShown else { return }
        isShown = true
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        item.isVisible = true
        if let button = item.button {
            StatusBarIconPresenter.installDefault(on: button)
            button.toolTip = "MacTalk - Voice Transcription"
            button.action = #selector(statusBarButtonClicked)
            button.target = self
        }
        let presenter = StatusMenuPresenter(target: self)
        menuPresenter = presenter
        item.menu = presenter.menu
        hudController = HUDWindowController()
        hudController?.onStop = { [weak self] in self?.handle(.stop) }
        dependencies.shortcut.reload()
        dependencies.download.onStateChanged = { [weak self] _ in self?.render() }
        render()
    }

    func cleanup() {
        recording.cleanup()
        dependencies.appAudioSource.cleanup()
        dependencies.shortcut.cleanup()
        dependencies.shortcut.onIntent = nil
        dependencies.download.onStateChanged = nil
        dependencies.engine.onEffect = nil
        dependencies.engine.clear()
        dependencies.output.cancel()
        appPickerController?.close()
        appPickerController = nil
        hudController?.close()
        hudController = nil
        settingsController?.close()
        settingsController = nil
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
        notificationTokens.removeAll()
        statusItem?.menu = nil
        statusItem = nil
        menuPresenter = nil
        isShown = false
    }

    @objc func statusBarButtonClicked() {
        guard recording.state.phase == .recording else { return }
        hudController?.showWindow(nil)
    }

    @objc func startMicOnly() { handle(.startMicOnly) }
    @objc func startMicPlusApp() { handle(.startMicPlusAppAudio) }
    @objc func stopRecording() { handle(.stop) }

    @objc func toggleAutoPaste() {
        let currentlyEnabled = dependencies.permissionFlow.effectiveAutoPaste
        guard !currentlyEnabled else {
            dependencies.settings.setAutoPaste(false)
            render()
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await dependencies.permissionFlow.requestEnableAutoPaste()
            if result == .enabled {
                dependencies.settings.setAutoPaste(true)
            }
            render()
        }
    }

    @objc func selectModelSpec(_ sender: NSMenuItem) {
        guard let spec = sender.representedObject as? ModelSpec else { return }
        dependencies.settings.setWhisperModelID(spec.id)
        dependencies.settings.setProvider(.whisper)
        dependencies.engine.settingsChanged(to: dependencies.settings.snapshot, recordingActive: recording.state.phase != .idle)
        render()
    }

    @objc func selectParakeet() {
        dependencies.settings.setProvider(.parakeet)
        dependencies.engine.settingsChanged(to: dependencies.settings.snapshot, recordingActive: recording.state.phase != .idle)
        render()
    }

    @objc func checkPermissions() {
        StatusBarAlertPresenter.showPermissions(dependencies.permissionFlow.statusReport())
    }

    @objc func showSettings() {
        if settingsController == nil { settingsController = SettingsWindowController() }
        settingsController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showAbout() { StatusBarAlertPresenter.showAbout() }

    @objc func quit() { NSApp.terminate(nil) }

    private func handle(_ intent: StatusBarIntent) {
        switch intent {
        case .startMicOnly:
            recording.requestStart(mode: .micOnly)
        case .startMicPlusAppAudio:
            recording.requestStart(mode: .micPlusAppAudio)
        case .toggleMicOnly:
            recording.toggle(mode: .micOnly)
        case .toggleMicPlusAppAudio:
            recording.toggle(mode: .micPlusAppAudio)
        case .stop:
            recording.stop()
        case .toggleAutoPaste:
            toggleAutoPaste()
        case let .selectModel(spec):
            dependencies.settings.setWhisperModelID(spec.id)
            dependencies.settings.setProvider(.whisper)
        case .selectParakeet:
            dependencies.settings.setProvider(.parakeet)
        case .checkPermissions:
            checkPermissions()
        case .showSettings:
            showSettings()
        case .showAbout:
            showAbout()
        case .quit:
            quit()
        }
        render()
    }

    private func handle(_ event: RecordingSessionEvent) {
        switch event {
        case let .stateChanged(state):
            let recordingNow = state.phase == .recording
            if recordingNow {
                hudController?.setAppMeterVisible(state.mode == .micPlusAppAudio)
                hudController?.showWindow(nil)
            } else if state.phase == .idle || state.phase == .finalizing {
                hudController?.close()
                if state.phase == .idle {
                    appPickerController?.close()
                    appPickerController = nil
                }
            }
            updateIcon(recording: recordingNow)
            render()
        case let .effect(effect):
            handle(effect)
        case let .requestAudioSource(requestID, sources):
            showAppPicker(requestID: requestID, sources: sources)
        case let .confirmDownload(requestID, requirement):
            showDownloadConfirmation(requirement: requirement) { [weak self] approved in
                self?.recording.respondToDownloadPrompt(requestID: requestID, approved: approved)
            }
        case let .partial(text): hudController?.updatePartial(text: text)
        case let .finalText(text): hudController?.updateFinal(text: text)
        case let .finalOutput(output):
            if let effect = output.permissionEffect { handle(effect) }
        case let .micLevel(level):
            hudController?.updateMicLevel(rms: level.rms, peak: level.peak, peakHold: level.peakHold)
        case let .appLevel(level):
            hudController?.updateAppLevel(rms: level.rms, peak: level.peak, peakHold: level.peakHold)
        case .appAudioLost:
            dependencies.output.handleAppAudioLost(showNotification: dependencies.settings.snapshot.showNotifications)
        case .fallbackToMicOnly:
            dependencies.output.handleFallbackToMicOnly(showNotification: dependencies.settings.snapshot.showNotifications)
            hudController?.setAppMeterVisible(false)
        case let .error(error): showError(error.message)
        }
    }

    private func handle(_ effect: StatusBarEffect) {
        switch effect {
        case .showMicrophoneGuidance:
            StatusBarAlertPresenter.showMicrophoneGuidance()
        case .showScreenRecordingGuidance:
            StatusBarAlertPresenter.showScreenRecordingGuidance()
        case let .confirmDownload(requirement):
            showDownloadConfirmation(requirement: requirement) { [weak self] approved in
                guard approved, let self else { return }
                let requestID = UUID()
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        try await self.dependencies.download.download(requirement, requestID: requestID)
                        self.dependencies.engine.prewarm(self.selection(for: requirement))
                    } catch is CancellationError {
                        return
                    } catch {
                        self.showError(error.localizedDescription)
                    }
                }
            }
        case let .permission(permissionEffect):
            handle(permissionEffect)
        }
    }

    private func handle(_ effect: PermissionEffect) {
        switch effect {
        case .requestAccessibility:
            Task { @MainActor in _ = await dependencies.permissionClient.requestAccessibilitySystemPrompt() }
        case .openAccessibilitySettings:
            dependencies.permissionClient.openAccessibilitySettings()
        case .resetStaleAccessibilityApproval:
            _ = dependencies.permissionClient.resetAccessibilityApproval(reason: "stale local Accessibility approval")
        }
    }

    private func render() {
        guard let presenter = menuPresenter else { return }
        let settings = dependencies.settings.snapshot
        let permission = dependencies.permissionFlow.refresh(storedAutoPaste: settings.autoPaste)
        let state = StatusBarViewStateReducer.reduce(
            recording: recording.state,
            settings: settings,
            permission: permission,
            download: dependencies.download.state,
            shortcuts: dependencies.shortcut.configuration
        )
        presenter.render(state)
        updateIcon(recording: state.recordingIcon)
        lastSettingsSnapshot = settings
    }

    private func installObservers() {
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(forName: .settingsDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.settingsChanged() }
        })
        notificationTokens.append(center.addObserver(forName: .providerDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.settingsChanged() }
        })
        notificationTokens.append(center.addObserver(forName: .permissionsDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.render() }
        })
        notificationTokens.append(center.addObserver(forName: .shortcutsDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.dependencies.shortcut.reload()
                self?.render()
            }
        })
    }

    private func settingsChanged() {
        let settings = dependencies.settings.snapshot
        guard settings != lastSettingsSnapshot else {
            render()
            return
        }
        dependencies.engine.settingsChanged(to: settings, recordingActive: recording.state.phase != .idle)
        render()
    }

    private func showAppPicker(requestID: UUID, sources: [AppPickerWindowController.AudioSource]) {
        guard recording.state.requestID == requestID, recording.state.phase == .selectingAudioSource else { return }
        guard !sources.isEmpty else {
            recording.provideAudioSource(requestID: requestID, source: nil)
            showError("No audio sources found.\n\nMake sure Screen Recording permission is granted.")
            return
        }
        let picker = AppPickerWindowController(sources: sources)
        appPickerController = picker
        picker.onSelection = { [weak self] source in
            guard let self, self.recording.state.requestID == requestID else { return }
            self.appPickerController = nil
            self.recording.provideAudioSource(requestID: requestID, source: source)
        }
        picker.onCancel = { [weak self] in
            guard let self else { return }
            self.appPickerController = nil
            self.recording.provideAudioSource(requestID: requestID, source: nil)
        }
        _ = picker.window
        picker.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showDownloadConfirmation(requirement: ModelRequirement, completion: @escaping (Bool) -> Void) {
        completion(StatusBarAlertPresenter.confirmDownload(requirement))
    }

    private func showError(_ message: String) { StatusBarAlertPresenter.showError(message) }

    private func selection(for requirement: ModelRequirement) -> EngineSelection {
        switch requirement {
        case let .whisper(spec): return .whisper(spec)
        case let .parakeet(modelID, revision): return EngineSelection(provider: .parakeet, modelID: modelID, revision: revision)
        }
    }

    private func updateIcon(recording: Bool) {
        guard let button = statusItem?.button else { return }
        StatusBarIconPresenter.render(recording: recording, on: button)
    }
}
