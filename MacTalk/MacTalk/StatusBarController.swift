//
//  StatusBarController.swift
//  MacTalk
//
//  Menu bar controller for MacTalk application
//

// swiftlint:disable file_length type_body_length

import AppKit
@preconcurrency import ScreenCaptureKit

/// Errors that can occur during screen capture operations
enum ScreenCaptureError: Error, LocalizedError {
    case timeout
    case permissionDenied
    case noSourcesAvailable

    var errorDescription: String? {
        switch self {
        case .timeout:
            return """
            Screen capture system is not responding.

            This is a known macOS bug. Try:
            1. Run: killall -9 replayd
            2. Log out and back in
            3. Restart your Mac

            The 'replayd' daemon handles screen recording and can become unresponsive.
            """
        case .permissionDenied:
            return "Screen Recording permission is not granted."
        case .noSourcesAvailable:
            return "No audio sources are available for capture."
        }
    }
}

@MainActor
final class StatusBarController {
    // Create status item lazily to ensure proper registration on macOS 26 (Tahoe)
    private var statusItem: NSStatusItem!
    private var engine: (any ASREngine)?
    private let engineReloadCoordinator = EngineReloadCoordinator(loader: DefaultEngineSelectionLoader())
    private var transcriber: TranscriptionController?
    private var hudController: HUDWindowController?
    private var settingsController: SettingsWindowController?

    private var provider: ASRProvider = AppSettings.shared.provider
    private var autoPaste = false
    private var showNotifications = true  // Default to true
    private let notificationManager: NotificationManager
    private let dependencies: StatusBarDependencies
    private let permissionFlowCoordinator: PermissionFlowCoordinator
    private let outputCoordinator: OutputCoordinator
    private var mode: TranscriptionController.Mode = .micOnly
    /// Explicit menu/hotkey intent survives settings edits and preparation retries.
    private var pendingStartMode: TranscriptionController.Mode?
    /// The settings captured when a start request begins. It remains stable
    /// through permission prompts, app picking, downloads, and engine retries.
    private var pendingSettingsLatch = RecordingStartSnapshotLatch()
    private var isRecording = false
    private var isFinalizing = false
    private var currentWhisperModelName = "ggml-large-v3-turbo-q5_0.bin"
    private var selectedAudioSource: AppPickerWindowController.AudioSource?
    // FIX P0: Retain app picker to keep callbacks alive
    private var appPickerController: AppPickerWindowController?

    // Auto-download feature
    private var catalog = ModelCatalog.bundled()
    private var selectedModel: ModelSpec?
    private var progressItem: NSMenuItem?
    private var parakeetMenuItem: NSMenuItem?
    private var whisperModelItems: [NSMenuItem] = []
    private var parakeetEngine: ParakeetEngine?
    private var isParakeetPreparationInFlight = false
    private var pendingParakeetStartRetry = false
    private var pendingParakeetStartGeneration: Int?
    private var isStartInFlight = false
    private var startTask: Task<Void, Never>?
    private var startGeneration = 0

    // Hotkeys
    private let hotkeyManager = HotkeyManager()
    private var registeredHotkeyIDs: [String: UInt32] = [:]

    // Menu items for shortcut display
    private var micOnlyMenuItem: NSMenuItem?
    private var micPlusAppMenuItem: NSMenuItem?
    private var autoPasteMenuItem: NSMenuItem?
    // Use nonisolated(unsafe) because deinit cannot access @MainActor-isolated properties
    private nonisolated(unsafe) var notificationTokens: [NSObjectProtocol] = []

    init(
        notificationManager: NotificationManager = .shared,
        dependencies: StatusBarDependencies? = nil
    ) {
        self.notificationManager = notificationManager
        let resolvedDependencies = dependencies ?? StatusBarDependencies.live(notificationManager: notificationManager)
        self.dependencies = resolvedDependencies
        let permissionCoordinator = PermissionFlowCoordinator(
            client: resolvedDependencies.permissionClient,
            storedAutoPaste: AppSettings.shared.snapshot.autoPaste,
            clock: resolvedDependencies.clock
        )
        self.permissionFlowCoordinator = permissionCoordinator
        self.outputCoordinator = OutputCoordinator(
            clipboardWriter: resolvedDependencies.clipboardWriter,
            textInserter: resolvedDependencies.textInserter,
            workspaceReader: resolvedDependencies.workspaceReader,
            notifications: resolvedDependencies.notificationSubmitter,
            permissionFlow: permissionCoordinator
        )
        DLOG("=== StatusBarController.init() START ===")
        NSLog("🔧 [MacTalk] StatusBarController.init() called")

        // Load the authoritative settings snapshot.
        let settingsSnapshot = AppSettings.shared.snapshot
        refreshAutoPasteStateFromPermissions(updateStoredPreference: false)
        provider = settingsSnapshot.provider
        currentWhisperModelName = ModelCatalog.findById(settingsSnapshot.whisperModelID)?.filename ?? currentWhisperModelName
        mode = settingsSnapshot.captureMode == .micPlusAppAudio ? .micPlusAppAudio : .micOnly
        showNotifications = settingsSnapshot.showNotifications

        NSLog("🔧 [MacTalk] Loaded auto-paste setting: \(autoPaste)")
        NSLog("🔧 [MacTalk] Loaded show-notifications setting: \(showNotifications)")
        NSLog("📋 [MacTalk] Clipboard copy: Always enabled (required for transcription)")

        // Listen for shortcut changes
        notificationTokens.append(
            NotificationCenter.default.addObserver(
                forName: .shortcutsDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.shortcutsDidChange()
                }
            }
        )

        // Listen for settings changes (including showNotifications)
        notificationTokens.append(
            NotificationCenter.default.addObserver(
                forName: .settingsDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.settingsDidChange()
                }
            }
        )

        // Listen for provider changes
        notificationTokens.append(
            NotificationCenter.default.addObserver(
                forName: .providerDidChange,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let provider = notification.object as? ASRProvider else { return }
                Task { @MainActor in
                    self?.providerDidChange(provider)
                }
            }
        )

        // Listen for permission changes so stale Accessibility grants do not leave Auto-paste visually enabled.
        notificationTokens.append(
            NotificationCenter.default.addObserver(
                forName: .permissionsDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.permissionsDidChange()
                }
            }
        )

        // Listen for Parakeet download updates
        notificationTokens.append(
            NotificationCenter.default.addObserver(
                forName: .parakeetDownloadStateDidChange,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let state = notification.object as? ParakeetModelDownloader.State else { return }
                Task { @MainActor in
                    self?.handleParakeetDownloadState(state)
                }
            }
        )

        DLOG("=== StatusBarController.init() END ===")
    }

    deinit {
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
    }

    func show() {
        DLOG("=== StatusBarController.show() START ===")
        NSLog("🔧 [MacTalk] StatusBarController.show() called")

        // MUST be called from main thread (applicationDidFinishLaunching)
        assert(Thread.isMainThread, "StatusBarController.show() must be called from main thread")
        NSLog("🔧 [MacTalk] Thread check passed - on main thread")

        // Create status item on main thread (critical for macOS 26 Tahoe)
        // Use squareLength as recommended in the checklist
        NSLog("🔧 [MacTalk] Creating status item...")
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        NSLog("🔧 [MacTalk] Status item created: %@", statusItem)

        // Make status item visible (macOS 26.0.1 workaround)
        statusItem.isVisible = true
        NSLog("🔧 [MacTalk] Status item visibility set to true")

        guard let button = statusItem.button else {
            NSLog("❌ [MacTalk] ERROR: Status item button is nil!")
            return
        }
        NSLog("🔧 [MacTalk] Status item button obtained: %@", button)

        // Set menu bar icon with custom waveform icon
        if let image = NSImage(named: "MenuBarIcon") {
            image.isTemplate = true  // Critical for visibility with Tahoe's transparent menu bar
            button.image = image
            button.imagePosition = .imageOnly
            NSLog("✅ [MacTalk] Set custom MenuBarIcon (template: %d)", image.isTemplate)
        } else {
            // Fallback to SF Symbol if custom icon not found
            if let fallback = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "MacTalk") {
                fallback.isTemplate = true
                button.image = fallback
                button.imagePosition = .imageOnly
                NSLog("⚠️ [MacTalk] Using mic.fill fallback icon")
            } else {
                button.title = "🎙️"
                NSLog("✅ [MacTalk] Set emoji icon as fallback")
            }
        }

        button.toolTip = "MacTalk - Voice Transcription"
        button.action = #selector(statusBarButtonClicked)
        button.target = self

        // Force the button to be visible
        button.isHidden = false
        NSLog("🔧 [MacTalk] Button isHidden set to false")

        NSLog("🔧 [MacTalk] About to call setupMenu()...")
        setupMenu()
        NSLog("🔧 [MacTalk] setupMenu() completed")

        // Register global shortcuts
        registerShortcuts()
        NSLog("🔧 [MacTalk] Shortcuts registered")

        NSLog("✅ [MacTalk] Status bar setup complete. Button frame: %@", NSStringFromRect(button.frame))
        NSLog("✅ [MacTalk] Status item isVisible: %d", statusItem.isVisible)
        NSLog("✅ [MacTalk] Status item length: %f", statusItem.length)
    }

    private func createModelSubmenu() -> NSMenuItem {
        let modelMenu = NSMenu()

        let parakeetItem = NSMenuItem(title: "Parakeet (Core ML)", action: #selector(selectParakeet), keyEquivalent: "")
        parakeetItem.target = self
        parakeetItem.state = provider == .parakeet ? .on : .off
        modelMenu.addItem(parakeetItem)
        modelMenu.addItem(NSMenuItem.separator())
        parakeetMenuItem = parakeetItem

        whisperModelItems.removeAll()

        // Use ModelCatalog for model selection with display names
        for spec in catalog {
            let item = NSMenuItem(title: spec.displayName, action: #selector(selectModelSpec(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = spec
            item.state = (provider == .whisper && spec.filename == currentWhisperModelName) ? .on : .off
            modelMenu.addItem(item)
            whisperModelItems.append(item)
        }

        let modelItem = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        modelItem.submenu = modelMenu
        return modelItem
    }

    private func setupMenu() {
        // Create menu
        let menu = NSMenu()

        // Recording controls
        micOnlyMenuItem = NSMenuItem(title: "Start (Mic Only)", action: #selector(startMicOnly), keyEquivalent: "")
        micOnlyMenuItem?.target = self
        menu.addItem(micOnlyMenuItem!)

        micPlusAppMenuItem = NSMenuItem(title: "Start (Mic + App Audio)", action: #selector(startMicPlusApp), keyEquivalent: "")
        micPlusAppMenuItem?.target = self
        menu.addItem(micPlusAppMenuItem!)

        menu.addItem(withTitle: "Stop Recording", action: #selector(stopRecording), keyEquivalent: "").target = self
        menu.addItem(NSMenuItem.separator())

        // Update menu shortcuts with current values
        updateMenuShortcuts()

        // Settings
        let autoPasteItem = NSMenuItem(
            title: "Auto-paste on Stop",
            action: #selector(toggleAutoPaste),
            keyEquivalent: "p"
        )
        autoPasteItem.state = autoPaste ? .on : .off
        autoPasteItem.target = self
        autoPasteMenuItem = autoPasteItem
        menu.addItem(autoPasteItem)
        refreshAutoPasteStateFromPermissions(updateStoredPreference: false)

        menu.addItem(NSMenuItem.separator())

        // Model selection
        menu.addItem(createModelSubmenu())

        // Download progress indicator (hidden by default)
        progressItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        progressItem?.isHidden = true
        menu.addItem(progressItem!)

        menu.addItem(NSMenuItem.separator())

        // Settings
        menu.addItem(withTitle: "Settings...", action: #selector(showSettings), keyEquivalent: ",").target = self

        // Permissions
        let permissionsItem = menu.addItem(
            withTitle: "Check Permissions",
            action: #selector(checkPermissions),
            keyEquivalent: ""
        )
        permissionsItem.target = self

        menu.addItem(NSMenuItem.separator())

        // About and Quit
        menu.addItem(withTitle: "About MacTalk", action: #selector(showAbout), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit MacTalk", action: #selector(quit), keyEquivalent: "q").target = self

        statusItem.menu = menu

        // Initialize HUD
        hudController = HUDWindowController()
        hudController?.onStop = { [weak self] in
            self?.stopRecording()
        }

        // Bind download progress updates
        ModelManager.shared.onDownloadState = { [weak self] state in
            self?.handleDownloadState(state)
        }

        // Load default model (async to avoid blocking menu bar icon)
        Task { @MainActor [weak self] in
            await self?.prepareEngineForCurrentProvider()
        }
    }

    @objc private func statusBarButtonClicked() {
        // Toggle HUD visibility
        if isRecording {
            hudController?.showWindow(nil)
        }
    }

    @objc private func startMicOnly() {
        mode = .micOnly
        pendingStartMode = .micOnly
        pendingSettingsLatch.captureIfNeeded(AppSettings.shared.snapshotAtRecordingStart().withCaptureMode(.micOnly))
        withMicrophonePermission(
            onGranted: { [weak self] in
                guard let self else { return }
                self.captureRecordingTarget()
                self.startRecording()
            },
            onAbandoned: { [weak self] in
                self?.abandonPendingStart()
            }
        )
    }

    @objc private func startMicPlusApp() {
        NSLog("🎙️ [StatusBar] Starting Mic + App Audio mode...")
        mode = .micPlusAppAudio
        pendingStartMode = .micPlusAppAudio
        pendingSettingsLatch.captureIfNeeded(AppSettings.shared.snapshotAtRecordingStart().withCaptureMode(.micPlusAppAudio))

        withMicrophonePermission(
            onGranted: { [weak self] in
                guard let self else { return }
                self.captureRecordingTarget()

                // Check screen recording permission
                NSLog("🔍 [StatusBar] Checking screen recording permission...")
                if Permissions.checkScreenRecordingPermission() {
                    NSLog("✅ [StatusBar] Permission granted, showing app picker")
                    self.showAppPicker()
                } else {
                    NSLog("❌ [StatusBar] Screen recording permission not granted")
                    self.abandonPendingStart()
                    // Show guide to help user enable permission
                    Permissions.ensureScreenRecordingGuide()
                }
            },
            onAbandoned: { [weak self] in
                self?.abandonPendingStart()
            }
        )
    }

    @objc private func stopRecording() {
        guard isRecording || isStartInFlight else { return }
        let shouldFlushFinalTranscript = isRecording
        invalidatePendingStart()
        if shouldFlushFinalTranscript {
            isFinalizing = true
            setStartItemsEnabled(false)
            transcriber?.stop()
        } else {
            transcriber?.cancelStart()
            outputCoordinator.cancel()
        }
        isRecording = false
        updateMenuBarIcon(recording: false)
        hudController?.close()
    }

    @objc private func toggleAutoPaste(_ sender: NSMenuItem) {
        if autoPaste {
            autoPaste = false
            sender.state = .off
            AppSettings.shared.setAutoPaste(false)
        } else if Permissions.isAccessibilityTrusted() {
            autoPaste = true
            sender.state = .on
            AppSettings.shared.setAutoPaste(true)
        } else {
            autoPaste = false
            sender.state = .off
            Task { @MainActor [weak self, weak sender] in
                guard let self else { return }
                let result = await self.permissionFlowCoordinator.requestEnableAutoPaste()
                if result == .enabled {
                    self.autoPaste = true
                    sender?.state = .on
                    AppSettings.shared.setAutoPaste(true)
                } else {
                    self.refreshAutoPasteStateFromPermissions(updateStoredPreference: false)
                }
            }
            return
            let diagnostics = Permissions.getAccessibilityDiagnostics()
            DLOG("Auto-paste enable requested but Accessibility is not trusted; bundle=\(diagnostics.bundleIdentifier), team=\(diagnostics.teamIdentifier.isEmpty ? "(none)" : diagnostics.teamIdentifier), adHoc=\(diagnostics.isAdHocSigned), fromXcode=\(diagnostics.isRunningFromXcode), executable=\(diagnostics.executablePath)")
            if AutoPastePermissionPolicy.shouldResetStaleAccessibilityApproval(
                accessibilityTrusted: diagnostics.isAccessibilityTrusted,
                diagnostics: diagnostics
            ) {
                DLOG("System Settings may show MacTalk enabled for a stale local build; resetting Accessibility approval before re-requesting")
                Permissions.resetAccessibilityApproval(reason: "Menu auto-paste enable saw stale/untrusted local build")
            }
            Permissions.requestAccessibilityPermission { [weak self, weak sender] in
                DLOG("Auto-paste Accessibility grant callback received; enabling preference")
                self?.autoPaste = true
                sender?.state = .on
                AppSettings.shared.setAutoPaste(true)
            }
        }

        NSLog("🔧 [MacTalk] Auto-paste setting changed to: \(autoPaste)")
    }

    @objc private func selectModel(_ sender: NSMenuItem) {
        guard let modelName = sender.representedObject as? String else { return }
        currentWhisperModelName = modelName
        if let spec = ModelCatalog.findByFilename(modelName) {
            AppSettings.shared.setWhisperModelID(spec.id)
        }

        requestProviderSwitch(to: .whisper, promptForDownload: false)
        updateProviderMenuState()

        // A recording owns its engine. The selected model is reconciled at the
        // next start rather than replacing an engine underneath that recording.
        if !isRecording && !isStartInFlight && !isFinalizing {
            prepareWhisperModel()
        }
    }

    @objc private func selectModelSpec(_ sender: NSMenuItem) {
        guard let spec = sender.representedObject as? ModelSpec else { return }
        selectedModel = spec
        currentWhisperModelName = spec.filename
        AppSettings.shared.setWhisperModelID(spec.id)

        requestProviderSwitch(to: .whisper, promptForDownload: false)
        updateProviderMenuState()

        // Prepare model with auto-download only while idle. During a recording
        // this selection is persisted for the next session and menu state stays
        // owned by the active recording.
        if !isRecording && !isStartInFlight && !isFinalizing {
            setStartItemsEnabled(false)
            prepareWhisperModelWithAutoDownload(spec: spec)
        }
    }

    @objc private func selectParakeet() {
        requestProviderSwitch(to: .parakeet, promptForDownload: true)
    }

    private func requestProviderSwitch(to newProvider: ASRProvider, promptForDownload: Bool) {
        guard provider != newProvider else { return }

        if newProvider == .parakeet, promptForDownload {
            if !ParakeetModelDownloader.modelsAvailable() {
                showParakeetDownloadConfirmation { [weak self] approved in
                    guard let self = self else { return }
                    if approved {
                        AppSettings.shared.provider = .parakeet
                        Task { [weak self] in
                            guard let self else { return }
                            do {
                                try await ParakeetBootstrap.shared.downloadModels()
                            } catch {
                                await MainActor.run {
                                    self.showError("Parakeet download failed: \(error.localizedDescription)")
                                }
                            }
                        }
                    } else {
                        self.updateProviderMenuState()
                    }
                }
                return
            }
        }

        AppSettings.shared.provider = newProvider
    }

    private func setStartItemsEnabled(_ enabled: Bool) {
        guard let menu = statusItem.menu else { return }
        for item in menu.items {
            if item.title.hasPrefix("Start") {
                item.isEnabled = enabled
            }
        }
    }

    private func withMicrophonePermission(
        onGranted: @escaping @MainActor () -> Void,
        onAbandoned: @escaping @MainActor () -> Void
    ) {
        switch PermissionFlowGate.microphoneAction(for: Permissions.microphonePermissionState()) {
        case .proceed:
            onGranted()
        case .requestPermission:
            Permissions.ensureMic { granted in
                if granted {
                    onGranted()
                } else {
                    onAbandoned()
                    Permissions.showMicrophonePermissionGuidance()
                }
            }
        case .openSettings:
            onAbandoned()
            Permissions.showMicrophonePermissionGuidance()
        }
    }

    @objc private func checkPermissions() {
        let micStatus = Permissions.isMicrophoneAuthorized() ? "✅ Granted" : "❌ Denied"
        let screenStatus = Permissions.checkScreenRecordingPermission() ? "✅ Granted" : "❌ Denied"
        let accessibilityStatus = Permissions.isAccessibilityTrusted() ? "✅ Granted" : "❌ Denied"

        let alert = NSAlert()
        alert.messageText = "Permissions Status"
        alert.informativeText = """
        Microphone: \(micStatus)
        Screen Recording: \(screenStatus)
        Accessibility: \(accessibilityStatus)
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func showSettings() {
        if settingsController == nil {
            settingsController = SettingsWindowController()
        }
        settingsController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "MacTalk v1.0"
        alert.informativeText = """
            A native macOS app for local voice transcription powered by Whisper.

            100% on-device processing. No cloud, no network calls.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func prepareWhisperModel() {
        // Find model spec from catalog
        if let spec = ModelCatalog.findByFilename(currentWhisperModelName) {
            prepareWhisperModelWithAutoDownload(spec: spec)
        } else {
            // Only catalog entries carry immutable provenance. Never fall back
            // to an existence-only legacy path for native model loading.
            showError("The selected Whisper model has no verified integrity metadata.")
        }
    }

    private func prepareWhisperModelWithAutoDownload(spec: ModelSpec) {
        // Cached files are untrusted input too. Validate before loading the
        // native whisper.cpp model; a corrupt cache must not be used.
        if ModelStore.exists(spec) {
            let url = ModelStore.path(for: spec)
            Task { [weak self] in
                let isValid = await Task.detached(priority: .utility) {
                    (try? ModelIntegrityVerifier.validate(source: url, spec: spec)) != nil
                }.value
                guard let self else { return }
                if isValid {
                    guard self.provider == .whisper else { return }
                    if let loadedEngine = NativeWhisperEngine(modelSpec: spec, modelURL: url) {
                        self.adoptLoadedEngine(
                            loadedEngine,
                            selection: .whisper(spec)
                        )
                    }
                    self.setStartItemsEnabled(true)
                } else {
                    // Missing/malformed catalog metadata is an external
                    // release blocker, not evidence that the user's cache is
                    // corrupt. Never delete an unverifiable file solely due
                    // to absent provenance.
                    if ModelIntegrityVerifier.isValidDigest(spec.sha256) {
                        try? FileManager.default.removeItem(at: url)
                    }
                    self.showError("Model integrity metadata is unavailable; this model cannot be loaded safely.")
                }
            }
            return
        }

        // Model doesn't exist - ask user if they want to download
        showDownloadConfirmationDialog(spec: spec)
    }

    private func showDownloadConfirmationDialog(spec: ModelSpec) {
        let alert = NSAlert()
        alert.messageText = "Model Not Available"
        alert.informativeText = """
        The model '\(spec.displayName)' is not downloaded yet.

        Size: \(ByteCountFormatter.string(fromByteCount: spec.sizeBytes, countStyle: .file))

        Would you like to download this model now?
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Use Different Model")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()

        switch response {
        case .alertFirstButtonReturn:
            // Download - user clicked "Download"
            startModelDownload(spec: spec)
        case .alertSecondButtonReturn:
            // Use Different Model - user clicked "Use Different Model"
            setStartItemsEnabled(true)
            showInfo("Please select a different model from the Model menu.")
        default:
            // Cancel
            setStartItemsEnabled(true)
        }
    }

    private func startModelDownload(spec: ModelSpec) {
        ModelManager.shared.ensureAvailable(spec) { [weak self] result in
            self?.setStartItemsEnabled(true)
            switch result {
            case .success(let url):
                if self?.provider == .whisper, let loadedEngine = NativeWhisperEngine(modelSpec: spec, modelURL: url) {
                    self?.adoptLoadedEngine(
                        loadedEngine,
                        selection: .whisper(spec)
                    )
                }
            case .failure(let error):
                self?.progressItem?.title = "Model error: \(error.localizedDescription)"
                self?.progressItem?.isHidden = false
                self?.showError("Failed to load model: \(error.localizedDescription)")
            }
        }
    }

    private func handleDownloadState(_ state: ModelDownloader.State) {
        guard provider == .whisper else { return }
        switch state {
        case .running(let progress):
            progressItem?.title = String(format: "Downloading model… %.0f%%", progress * 100)
            progressItem?.isHidden = false
        case .verifying:
            progressItem?.title = "Verifying model…"
            progressItem?.isHidden = false
        case .failed(let error):
            progressItem?.title = "Download failed: \(error.localizedDescription)"
            progressItem?.isHidden = false
            // Auto-hide error after 5 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                self?.progressItem?.isHidden = true
            }
        case .done:
            progressItem?.title = "Model ready ✓"
            progressItem?.isHidden = false
            // Auto-hide success message after 2 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.progressItem?.isHidden = true
            }
        default:
            progressItem?.isHidden = true
        }
    }

    private func handleParakeetDownloadState(_ state: ParakeetModelDownloader.State) {
        switch state {
        case .running(let progress, let index, let count, _):
            progressItem?.title = String(
                format: "Downloading Parakeet… %.0f%% (%d/%d)", progress * 100, index, count
            )
            progressItem?.isHidden = false
            setStartItemsEnabled(false)
        case .verifying:
            progressItem?.title = "Verifying Parakeet…"
            progressItem?.isHidden = false
        case .failed(let error):
            progressItem?.title = "Parakeet download failed: \(error.localizedDescription)"
            progressItem?.isHidden = false
            setStartItemsEnabled(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                self?.progressItem?.isHidden = true
            }
        case .done:
            progressItem?.title = "Parakeet ready ✓"
            progressItem?.isHidden = false
            setStartItemsEnabled(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.progressItem?.isHidden = true
            }
            Task { [weak self] in
                guard let self, self.provider == .parakeet else { return }
                await self.prepareParakeetEngine()
            }
        default:
            break
        }
    }

    private func showParakeetDownloadConfirmation(completion: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Download Parakeet Model?"
        alert.informativeText = "This will download approximately 600MB of model files."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Cancel")

        if let window = settingsController?.window {
            alert.beginSheetModal(for: window) { response in
                completion(response == .alertFirstButtonReturn)
            }
        } else {
            let response = alert.runModal()
            completion(response == .alertFirstButtonReturn)
        }
    }

    private func updateProviderMenuState() {
        parakeetMenuItem?.state = provider == .parakeet ? .on : .off
        for item in whisperModelItems {
            guard let spec = item.representedObject as? ModelSpec else {
                item.state = .off
                continue
            }
            item.state = (provider == .whisper && spec.filename == currentWhisperModelName) ? .on : .off
        }
    }

    private func engineSelection(for settings: SettingsSnapshot) -> EngineSelection? {
        switch settings.provider {
        case .whisper:
            guard let spec = ModelCatalog.findById(settings.whisperModelID) else { return nil }
            return .whisper(spec)
        case .parakeet:
            return .parakeet
        }
    }

    private func isEngineAvailableLocally(_ selection: EngineSelection) -> Bool {
        switch selection.provider {
        case .whisper:
            guard let spec = ModelCatalog.findById(selection.modelID) else { return false }
            return ModelStore.exists(spec)
        case .parakeet:
            return ParakeetModelDownloader.modelsAvailable()
        }
    }

    private func adoptLoadedEngine(_ engine: any ASREngine, selection: EngineSelection?) {
        self.engine = engine
        if let selection {
            engineReloadCoordinator.adoptLoadedEngine(engine, selection: selection)
        }
    }

    @MainActor
    private func prepareEngineForCurrentProvider() async {
        switch provider {
        case .whisper:
            prepareWhisperModel()
        case .parakeet:
            guard ParakeetModelDownloader.modelsAvailable() else { return }
            await prepareParakeetEngine()
        }
    }

    @MainActor
    @discardableResult
    private func beginParakeetPreparation() -> Bool {
        guard !isParakeetPreparationInFlight else { return false }
        isParakeetPreparationInFlight = true
        return true
    }

    @MainActor
    private func prepareParakeetEngine() async {
        guard beginParakeetPreparation() else { return }
        await prepareParakeetEngineAssumingInFlight()
    }

    @MainActor
    private func finishParakeetPreparation(triggerRetry: Bool) {
        let shouldRetry = triggerRetry && pendingParakeetStartRetry
        let pendingGeneration = pendingParakeetStartGeneration
        let hasPendingStart = pendingSettingsLatch.snapshot != nil
        pendingParakeetStartRetry = false
        pendingParakeetStartGeneration = nil
        isParakeetPreparationInFlight = false

        guard let pendingGeneration, pendingGeneration == startGeneration else {
            if !triggerRetry || !hasPendingStart {
                pendingSettingsLatch.clear()
            }
            return
        }

        isStartInFlight = false

        if shouldRetry {
            // Keep the latched snapshot until the retried start either succeeds
            // or reports failure. Settings edits during preparation are for the
            // next recording and must not alter this request.
            startRecording(allowParakeetPrepare: false)
        } else {
            pendingSettingsLatch.clear()
        }
    }

    @MainActor
    private func prepareParakeetEngineAssumingInFlight() async {
        setStartItemsEnabled(false)

        let engine = parakeetEngine ?? ParakeetEngine()
        do {
            try await engine.prepare()
            guard provider == .parakeet else {
                setStartItemsEnabled(true)
                finishParakeetPreparation(triggerRetry: false)
                return
            }
            parakeetEngine = engine
            adoptLoadedEngine(engine, selection: .parakeet)
            setStartItemsEnabled(true)
            finishParakeetPreparation(triggerRetry: true)
        } catch {
            setStartItemsEnabled(true)
            finishParakeetPreparation(triggerRetry: false)
            showError("Failed to load Parakeet engine: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func providerDidChange(_ newProvider: ASRProvider) {
        guard provider != newProvider else { return }

        // Settings are session-scoped. Do not tear down or replace an engine
        // while a recording (or its start) is active; the next start reads the
        // authoritative snapshot and reconciles it below.
        guard !isRecording, !isStartInFlight, !isFinalizing else { return }

        provider = newProvider
        engine = nil
        engineReloadCoordinator.clearLoadedEngine()
        if newProvider == .whisper {
            parakeetEngine = nil
        }
        updateProviderMenuState()

        Task { [weak self] in
            guard let self else { return }
            await self.prepareEngineForCurrentProvider()
        }
    }

    private func resumeRecordingAfterProviderSwitch() {
        if mode == .micPlusAppAudio && selectedAudioSource == nil {
            showAppPicker()
        } else {
            startRecording()
        }
    }

    private func setupTranscriptionCallbacks(_ controller: TranscriptionController) {
        controller.onPartial = { [weak self] text in
            // Route partial text to HUD for live streaming display
            self?.hudController?.updatePartial(text: text)
        }

        controller.onFinal = { [weak self] text in
            DebugLogger.shared.log(.transcriptCompleted(characterCount: text.count))
            guard let owner = self else { return }
            owner.hudController?.updateFinal(text: text)
            let target = owner.outputCoordinator.currentTarget
            let output = owner.outputCoordinator.handleFinal(
                text: text,
                context: OutputContext(
                    target: target,
                    autoPastePreference: owner.autoPaste,
                    showNotifications: owner.showNotifications
                )
            )
            if let permissionEffect = output.permissionEffect {
                owner.handle(permissionEffect)
            }
            if output.insertOutcome == .failed {
                DebugLogger.shared.log(.error(description: "auto-insert failed"))
            }
            return
            /*
            let accessibilityTrusted = Permissions.isAccessibilityTrusted()
            let autoPastePreference = self?.autoPaste ?? false
            let autoPasteEnabled = AutoPastePermissionPolicy.effectiveAutoPaste(
                storedPreference: autoPastePreference,
                accessibilityTrusted: accessibilityTrusted
            )
            if self?.autoPaste == true, !accessibilityTrusted {
                DLOG("Auto-paste preference is enabled, but Accessibility is not trusted at paste time; disabling effective auto-paste")
                self?.refreshAutoPasteStateFromPermissions(updateStoredPreference: false)
            }
            NSLog("[StatusBar] autoPaste setting: \(autoPasteEnabled) (Accessibility trusted: \(accessibilityTrusted))")
            DLOG("[AutoPaste] legacy output path removed")

            // Always copy to clipboard first
            NSLog("[StatusBar] Copying text to clipboard...")
            DLOG("[AutoPaste] copying final text to clipboard")
            ClipboardManager.setClipboard(text)

            var message = "Text copied to clipboard"

            // Auto-insert if enabled (uses AX SetValue first, then Cmd+V fallback)
            if autoPasteEnabled, let self {
                DLOG("[AutoPaste] effective auto-paste enabled; checking target/frontmost match")
                if self.isRecordingTargetAppStillFrontmost() {
                    NSLog("[StatusBar] Auto-paste is enabled - using AutoInsertManager...")
                    DLOG("[AutoPaste] target/frontmost check passed; invoking AutoInsertManager")
                    let result = AutoInsertManager.insertText(text)
                    NSLog("[StatusBar] Auto-insert operation completed")
                    DLOG("[AutoPaste] AutoInsertManager returned: \(result.description)")

                    switch result {
                    case .axSetValueSuccess, .cmdVFallback:
                        message = "Text pasted"
                        self.resetPermissionPromptBackoff()
                    case .permissionDenied:
                        let now = Date()
                        let cooldown = self.currentPermissionPromptCooldown()
                        let shouldPrompt: Bool

                        if let lastPrompt = self.lastPermissionPromptTime {
                            let elapsed = now.timeIntervalSince(lastPrompt)
                            shouldPrompt = elapsed >= cooldown
                            if !shouldPrompt {
                                NSLog("[StatusBar] Permission prompt throttled (last prompt \(Int(elapsed))s ago, cooldown \(Int(cooldown))s)")
                                DLOG("[AutoPaste] permission prompt throttled: elapsed=\(Int(elapsed))s, cooldown=\(Int(cooldown))s")
                            }
                        } else {
                            shouldPrompt = true
                        }

                        if shouldPrompt {
                            NSLog("[StatusBar] Permission denied - requesting accessibility permission...")
                            DLOG("[AutoPaste] permission denied; requesting Accessibility permission")
                            self.recordPermissionPromptShown(at: now)
                            Permissions.requestAccessibilityPermission()
                        }
                    case .failed:
                        DebugLogger.shared.log(.error(description: "auto-insert failed"))
                        self.resetPermissionPromptBackoff()
                    }
                } else {
                    NSLog("⚠️ [StatusBar] Frontmost app changed during recording - skipping auto-paste and leaving text on clipboard")
                    DLOG("[AutoPaste] skipped because target/frontmost check failed")
                }
            } else {
                DLOG("[AutoPaste] effective auto-paste disabled; leaving text on clipboard")
            }

            DLOG("[AutoPaste] legacy output target cleanup removed")

            NSLog("[StatusBar] Showing transcription completion notification")
            self?.notificationManager.submit(.transcriptionComplete, enabled: self?.showNotifications ?? false)
            */
        }

        controller.onFinalizationComplete = { [weak self, weak controller] in
            guard let self, let controller, self.transcriber === controller else { return }
            self.isFinalizing = false
            self.setStartItemsEnabled(true)
            DLOG("Transcription finalization completed; recording controls re-enabled")
        }

        controller.onMicLevel = { [weak self] levelData in
            self?.hudController?.updateMicLevel(
                rms: levelData.rms,
                peak: levelData.peak,
                peakHold: levelData.peakHold
            )
        }

        controller.onAppLevel = { [weak self] levelData in
            self?.hudController?.updateAppLevel(
                rms: levelData.rms,
                peak: levelData.peak,
                peakHold: levelData.peakHold
            )
        }

        controller.onAppAudioLost = { [weak self] in
            guard let self else { return }
            self.outputCoordinator.handleAppAudioLost(showNotification: self.showNotifications)
        }

        controller.onFallbackToMicOnly = { [weak self] in
            guard let self else { return }
            self.outputCoordinator.handleFallbackToMicOnly(showNotification: self.showNotifications)
            self.hudController?.setAppMeterVisible(false)
        }
    }

    private func captureRecordingTarget() {
        _ = outputCoordinator.captureTarget()
    }

    private func startRecording() {
        startRecording(allowParakeetPrepare: true, requestedMode: nil)
    }

    private func startRecording(
        allowParakeetPrepare: Bool,
        requestedMode: TranscriptionController.Mode? = nil
    ) {
        if let requestedMode {
            pendingStartMode = requestedMode
            mode = requestedMode
            if pendingSettingsLatch.snapshot == nil {
                pendingSettingsLatch.captureIfNeeded(AppSettings.shared.snapshotAtRecordingStart().withCaptureMode(
                    requestedMode == .micPlusAppAudio ? .micPlusAppAudio : .micOnly
                ))
            }
        }
        NSLog("🎬 [StatusBar] startRecording() called")
        if outputCoordinator.currentTarget == nil {
            captureRecordingTarget()
        }
        NSLog("🎬 [StatusBar] Mode: \(mode)")
        if let source = selectedAudioSource {
            NSLog("🎬 [StatusBar] Audio source: \(source.name)")
        } else {
            NSLog("🎬 [StatusBar] Audio source: nil (mic-only mode)")
        }

        if isRecording || isStartInFlight || isFinalizing {
            NSLog("⚠️ [StatusBar] Ignoring start request while recording is active, starting, or finalizing")
            return
        }

        // Take one authoritative snapshot for this recording session. Explicit
        // menu/hotkey intent overrides the configured default mode, but all
        // other provider/model/language values come from this one snapshot.
        let requestedMode = pendingStartMode ?? mode
        let settingsSnapshot: SettingsSnapshot
        if let pendingSettingsSnapshot = pendingSettingsLatch.snapshot {
            settingsSnapshot = pendingSettingsSnapshot
        } else {
            let configuredSnapshot = AppSettings.shared.snapshotAtRecordingStart()
            settingsSnapshot = configuredSnapshot.withCaptureMode(
                requestedMode == .micPlusAppAudio ? .micPlusAppAudio : .micOnly
            )
            pendingSettingsLatch.captureIfNeeded(settingsSnapshot)
        }
        provider = settingsSnapshot.provider
        mode = requestedMode
        currentWhisperModelName = ModelCatalog.findById(settingsSnapshot.whisperModelID)?.filename ?? currentWhisperModelName
        selectedModel = ModelCatalog.findById(settingsSnapshot.whisperModelID)

        // Reconcile the complete engine identity before each new recording.
        // Provider-only checks are insufficient when the selected Whisper model
        // changes. Availability is checked locally; this path never downloads.
        if let pendingSelection = engineSelection(for: settingsSnapshot),
           engineReloadCoordinator.loadedSelection != pendingSelection || engineReloadCoordinator.loadedEngine == nil {
            if isEngineAvailableLocally(pendingSelection) {
                isStartInFlight = true
                startGeneration += 1
                let reconciliationGeneration = startGeneration
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        let loaded = try await self.engineReloadCoordinator.reconcile(
                            pending: PendingSettingsSnapshot(engine: pendingSelection),
                            isRecording: false
                        )
                        guard self.startGeneration == reconciliationGeneration, !self.isRecording else {
                            return
                        }
                        self.adoptLoadedEngine(loaded, selection: pendingSelection)
                        self.isStartInFlight = false
                        self.startRecording(allowParakeetPrepare: allowParakeetPrepare)
                    } catch {
                        guard self.startGeneration == reconciliationGeneration else { return }
                        self.isStartInFlight = false
                        self.pendingSettingsLatch.clear()
                        self.pendingStartMode = nil
                        self.showError("Failed to load the selected engine: \(error.localizedDescription)")
                    }
                }
                return
            } else if pendingSelection.provider == .whisper {
                engine = nil
                engineReloadCoordinator.clearLoadedEngine()
                pendingSettingsLatch.clear()
                pendingStartMode = nil
                showError("The selected Whisper model is not available locally.")
                return
            }
        }

        let parakeetModelsAvailable = provider == .parakeet ? ParakeetModelDownloader.modelsAvailable() : false
        if provider == .parakeet, parakeetModelsAvailable, engine?.provider != .parakeet {
            let immediateEngine = parakeetEngine ?? ParakeetEngine()
            parakeetEngine = immediateEngine
            engine = immediateEngine
            DLOG("Created Parakeet engine immediately so microphone capture can start before model preparation finishes")
            NSLog("✅ [StatusBar] Created Parakeet engine immediately; preparation will happen after mic capture starts")
        }

        let preparationDecision = RecordingStartGate.decision(
            provider: provider,
            engineProvider: engine?.provider,
            modelsAvailable: parakeetModelsAvailable,
            allowParakeetPrepare: allowParakeetPrepare,
            isPreparingParakeetEngine: isParakeetPreparationInFlight
        )

        if preparationDecision.clearMismatchedEngine, let engine {
            NSLog("⚠️ [StatusBar] Engine/provider mismatch (\(engine.provider) vs \(provider)) - clearing")
            self.engine = nil
            engineReloadCoordinator.clearLoadedEngine()
        }

        switch preparationDecision.action {
        case .promptForParakeetDownload:
            showParakeetDownloadConfirmation { [weak self] approved in
                guard let self = self else { return }
                if approved {
                    Task { [weak self] in
                        guard let self else { return }
                        do {
                            try await ParakeetBootstrap.shared.downloadModels()
                            await MainActor.run {
                                self.startRecording(allowParakeetPrepare: false)
                            }
                        } catch {
                            await MainActor.run {
                                self.pendingSettingsLatch.clear()
                                self.pendingStartMode = nil
                                self.showError("Parakeet download failed: \(error.localizedDescription)")
                            }
                        }
                    }
                } else {
                    self.pendingSettingsLatch.clear()
                    self.pendingStartMode = nil
                }
            }
            return
        case .prepareParakeetEngineAndRetry:
            NSLog("⏳ [StatusBar] Preparing Parakeet engine before starting recording")
            pendingParakeetStartRetry = true
            if pendingParakeetStartGeneration == nil {
                startGeneration += 1
                pendingParakeetStartGeneration = startGeneration
            }
            isStartInFlight = true
            guard beginParakeetPreparation() else {
                NSLog("⏳ [StatusBar] Parakeet engine preparation already in flight; waiting for retry")
                return
            }
            Task { [weak self] in
                guard let self else { return }
                await self.prepareParakeetEngineAssumingInFlight()
            }
            return
        case .waitForParakeetEnginePreparation:
            pendingParakeetStartRetry = true
            if pendingParakeetStartGeneration == nil {
                startGeneration += 1
                pendingParakeetStartGeneration = startGeneration
            }
            isStartInFlight = true
            NSLog("⏳ [StatusBar] Parakeet engine preparation already in flight; waiting for retry")
            return
        case .none:
            break
        }

        guard let engine = engine, engine.provider == provider else {
            NSLog("❌ [StatusBar] Engine not loaded or provider mismatch!")
            pendingSettingsLatch.clear()
            pendingStartMode = nil
            showError("Engine not loaded. Check that the \(provider.displayName) models are available.")
            return
        }

        let transcriptionController: TranscriptionController
        if let existing = transcriber,
           existing.provider == provider,
           existing.isUsingEngine(engine) {
            transcriptionController = existing
            DLOG("Reusing TranscriptionController and microphone engine for provider=\(provider.rawValue)")
            NSLog("✅ [StatusBar] Reusing existing TranscriptionController")
        } else {
            NSLog("✅ [StatusBar] Engine available, creating TranscriptionController...")
            transcriptionController = TranscriptionController(engine: engine)
            setupTranscriptionCallbacks(transcriptionController)
            transcriber = transcriptionController
            NSLog("🎬 [StatusBar] TranscriptionController created")
        }
        transcriptionController.autoPasteEnabled = autoPaste
        NSLog("🎬 [StatusBar] TranscriptionController configured with autoPaste=\(autoPaste)")
        isStartInFlight = true
        startGeneration += 1
        let startGeneration = self.startGeneration

        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                if let source = selectedAudioSource {
                    NSLog("🚀 [StatusBar] Starting transcription with mode=\(mode), source=\(source.name)")
                } else {
                    NSLog("🚀 [StatusBar] Starting transcription with mode=\(mode), source=nil")
                }
                try await transcriptionController.start(
                    mode: mode,
                    audioSource: selectedAudioSource,
                    settingsSnapshot: settingsSnapshot
                )
                await MainActor.run {
                    guard startGeneration == self.startGeneration else {
                        NSLog("⚠️ [StatusBar] Ignoring stale transcription start success for generation \(startGeneration)")
                        transcriptionController.stop()
                        return
                    }
                    NSLog("✅ [StatusBar] Transcription started successfully")
                    self.startTask = nil
                    self.isStartInFlight = false
                    self.isRecording = true
                    self.pendingStartMode = nil
                    self.pendingSettingsLatch.clear()
                    self.updateMenuBarIcon(recording: true)
                    self.hudController?.setAppMeterVisible(self.mode == .micPlusAppAudio)
                    self.hudController?.showWindow(nil)
                }
            } catch is CancellationError {
                transcriptionController.cancelStart()
                await MainActor.run {
                    guard startGeneration == self.startGeneration else { return }
                    self.startTask = nil
                    self.isStartInFlight = false
                    self.pendingSettingsLatch.clear()
                    self.pendingStartMode = nil
                    NSLog("ℹ️ [StatusBar] Recording start cancelled")
                }
            } catch {
                transcriptionController.cancelStart()
                NSLog("❌ [StatusBar] Failed to start recording: \(error.localizedDescription)")
                await MainActor.run {
                    guard startGeneration == self.startGeneration else { return }
                    self.startTask = nil
                    self.isStartInFlight = false
                    self.pendingSettingsLatch.clear()
                    self.pendingStartMode = nil
                    self.outputCoordinator.cancel()
                    self.showError("Failed to start recording: \(error.localizedDescription)")
                }
            }
        }
    }

    private func updateMenuBarIcon(recording: Bool) {
        guard let button = statusItem.button else { return }

        if recording {
            if let image = NSImage(named: "MenuBarIconRecording") {
                image.isTemplate = true
                button.image = image
                button.imagePosition = .imageOnly
            } else if let fallback = NSImage(systemSymbolName: "mic.fill.badge.plus", accessibilityDescription: "Recording") {
                fallback.isTemplate = true
                button.image = fallback
                button.imagePosition = .imageOnly
            } else {
                button.title = "🔴"
            }
        } else {
            if let image = NSImage(named: "MenuBarIcon") {
                image.isTemplate = true
                button.image = image
                button.imagePosition = .imageOnly
            } else if let fallback = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "MacTalk") {
                fallback.isTemplate = true
                button.image = fallback
                button.imagePosition = .imageOnly
            } else {
                button.title = "🎙️"
            }
        }
    }

    private func showModelMissingAlert(modelName: String, path: String) {
        let alert = NSAlert()
        alert.messageText = "Model File Not Found"
        alert.informativeText = """
        The model file '\(modelName)' was not found.

        Please download the model and place it at:
        \(path)

        You can download Whisper models from:
        https://huggingface.co/ggerganov/whisper.cpp
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Error"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showInfo(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Information"
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func cleanup() {
        invalidatePendingStart()
        transcriber?.stop()
        isRecording = false
        hudController?.close()
    }

    // MARK: - Menu Shortcut Display

    private func updateMenuShortcuts() {
        let defaults = UserDefaults.standard

        // Update Mic-Only shortcut
        if let data = defaults.data(forKey: "startMicOnlyShortcut"),
           let shortcut = try? JSONDecoder().decode(KeyboardShortcut.self, from: data) {
            updateMenuItemShortcut(micOnlyMenuItem, shortcut: shortcut)
        }

        // Update Mic + App Audio shortcut
        if let data = defaults.data(forKey: "startMicPlusAppShortcut"),
           let shortcut = try? JSONDecoder().decode(KeyboardShortcut.self, from: data) {
            updateMenuItemShortcut(micPlusAppMenuItem, shortcut: shortcut)
        }
    }

    private func updateMenuItemShortcut(_ menuItem: NSMenuItem?, shortcut: KeyboardShortcut) {
        guard let menuItem = menuItem else { return }

        // Get the base title without any previous shortcut
        let baseTitle = menuItem.title.components(separatedBy: "\t").first ?? menuItem.title

        // Create attributed string with tab-separated shortcut
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.tabStops = [NSTextTab(textAlignment: .right, location: 260)]

        let attributedTitle = NSMutableAttributedString(string: "\(baseTitle)\t\(shortcut.displayString)")
        attributedTitle.addAttribute(
            .paragraphStyle,
            value: paragraphStyle,
            range: NSRange(location: 0, length: attributedTitle.length)
        )

        // Make the shortcut text grey
        let shortcutRange = NSRange(
            location: baseTitle.count + 1,
            length: shortcut.displayString.count
        )
        attributedTitle.addAttribute(
            .foregroundColor,
            value: NSColor.tertiaryLabelColor,
            range: shortcutRange
        )

        menuItem.attributedTitle = attributedTitle
    }

    // MARK: - App Picker

    private func showAppPicker() {
        NSLog("🎬 [StatusBar] showAppPicker() - starting to load audio sources...")

        // Pattern 1: Preload → Inject → Then show
        // Load data FIRST, then create window controller with data
        Task { @MainActor in
            do {
                let sources = try await loadAudioSources()

                guard !sources.isEmpty else {
                    NSLog("⚠️ [StatusBar] No audio sources available")
                    abandonPendingStart()
                    showError("No audio sources found.\n\nMake sure Screen Recording permission is granted.")
                    return
                }

                NSLog("✅ [StatusBar] Loaded \(sources.count) audio sources - creating window controller...")

                // Now create window controller WITH data already available
                let picker = AppPickerWindowController(sources: sources)
                self.appPickerController = picker

                picker.onSelection = { [weak self] source in
                    NSLog("✅ [StatusBar] Audio source selected: \(source.name)")
                    self?.selectedAudioSource = source
                    self?.appPickerController = nil  // Release after selection
                    self?.startRecording()
                }
                picker.onCancel = { [weak self] in
                    self?.appPickerController = nil
                    self?.abandonPendingStart()
                }

                // Force window load synchronously BEFORE showing
                _ = picker.window
                NSLog("🎬 [StatusBar] Window loaded - now showing...")

                // Now show the window (data is already loaded and injected)
                picker.showWindow(nil)
                NSApp.activate(ignoringOtherApps: true)
                NSLog("✅ [StatusBar] App picker window shown successfully")

            } catch let error as ScreenCaptureError {
                NSLog("❌ [StatusBar] Screen capture error: \(error)")
                abandonPendingStart()
                showError(error.localizedDescription ?? "Unknown screen capture error")
            } catch {
                NSLog("❌ [StatusBar] Failed to load audio sources: \(error)")
                abandonPendingStart()
                showError("Failed to load audio sources.\n\nError: \(error.localizedDescription)")
            }
        }
    }

    private func loadAudioSources() async throws -> [AppPickerWindowController.AudioSource] {
        NSLog("🔍 [StatusBar] loadAudioSources() - checking screen recording permission...")

        // Check screen recording permission first (synchronous, reliable)
        let hasPermission = Permissions.checkScreenRecordingPermission()
        NSLog("🔍 [StatusBar] Screen recording permission: \(hasPermission)")

        guard hasPermission else {
            NSLog("❌ [StatusBar] Screen recording permission NOT granted")
            abandonPendingStart()
            showError("Screen Recording permission is required.\n\nPlease enable it in:\nSystem Settings > Privacy & Security > Screen Recording > MacTalk\n\nThen restart MacTalk.")
            return []
        }

        NSLog("🔍 [StatusBar] Fetching shareable content with timeout protection...")

        // Wrap SCShareableContent with timeout protection to prevent infinite hangs
        let content: SCShareableContent
        do {
            content = try await withTimeout(seconds: 5) {
                try await SCShareableContent.excludingDesktopWindows(
                    false,
                    onScreenWindowsOnly: true
                )
            }
            NSLog("✅ [StatusBar] Successfully fetched shareable content")
            NSLog("🔍 [StatusBar] Found \(content.displays.count) displays, \(content.applications.count) applications, \(content.windows.count) windows")
        } catch is TimeoutError {
            NSLog("⏱️ [StatusBar] SCShareableContent timed out after 5 seconds")
            throw ScreenCaptureError.timeout
        }

        var sources: [AppPickerWindowController.AudioSource] = []

        // Add system audio option
        if let display = content.displays.first {
            NSLog("🔍 [StatusBar] Adding system audio source for display: \(display.displayID)")
            sources.append(.systemAudio(display: display))
        }

        // Add running applications with windows
        for app in content.applications {
            let hasWindow = content.windows.contains(where: { $0.owningApplication == app })
            if hasWindow {
                NSLog("🔍 [StatusBar] Adding app: \(app.applicationName)")
                sources.append(.fromApp(app))
            }
        }

        NSLog("✅ [StatusBar] Total audio sources found: \(sources.count)")

        // Sort alphabetically
        sources.sort { $0.name < $1.name }

        return sources
    }

    // MARK: - Hotkeys

    private func registerShortcuts() {
        // Unregister all existing hotkeys first
        for (_, hotkeyID) in registeredHotkeyIDs {
            hotkeyManager.unregister(hotkeyID: hotkeyID)
        }
        registeredHotkeyIDs.removeAll()

        // Load shortcuts from UserDefaults
        let defaults = UserDefaults.standard

        // Start Mic-Only Recording (toggle behavior)
        if let data = defaults.data(forKey: "startMicOnlyShortcut"),
           let shortcut = try? JSONDecoder().decode(KeyboardShortcut.self, from: data) {
            if let hotkeyID = hotkeyManager.register(
                keyCode: shortcut.keyCode,
                modifiers: shortcut.carbonModifiers,
                handler: { [weak self] in
                    self?.toggleMicOnly()
                }
            ) {
                registeredHotkeyIDs["startMicOnly"] = hotkeyID
                NSLog("✅ [MacTalk] Registered Start Mic-Only shortcut: \(shortcut.displayString)")
            }
        }

        // Start Mic + App Audio Recording (toggle behavior)
        if let data = defaults.data(forKey: "startMicPlusAppShortcut"),
           let shortcut = try? JSONDecoder().decode(KeyboardShortcut.self, from: data) {
            if let hotkeyID = hotkeyManager.register(
                keyCode: shortcut.keyCode,
                modifiers: shortcut.carbonModifiers,
                handler: { [weak self] in
                    self?.toggleMicPlusApp()
                }
            ) {
                registeredHotkeyIDs["startMicPlusApp"] = hotkeyID
                NSLog("✅ [MacTalk] Registered Start Mic+App shortcut: \(shortcut.displayString)")
            }
        }

    }

    @objc private func shortcutsDidChange() {
        registerShortcuts()
        updateMenuShortcuts()
    }

    @objc private func settingsDidChange() {
        let settingsSnapshot = AppSettings.shared.snapshot
        refreshAutoPasteStateFromPermissions(updateStoredPreference: false)
        showNotifications = settingsSnapshot.showNotifications

        // Runtime settings are session-scoped. Edits during capture are stored
        // now but become authoritative only on the next recording.
        guard !isRecording, !isStartInFlight, !isFinalizing else { return }
        provider = settingsSnapshot.provider
        mode = settingsSnapshot.captureMode == .micPlusAppAudio ? .micPlusAppAudio : .micOnly
        currentWhisperModelName = ModelCatalog.findById(settingsSnapshot.whisperModelID)?.filename ?? currentWhisperModelName
        selectedModel = ModelCatalog.findById(settingsSnapshot.whisperModelID)
        if engine?.provider != provider {
            engine = nil
            engineReloadCoordinator.clearLoadedEngine()
        }
        updateProviderMenuState()
    }

    @objc private func permissionsDidChange() {
        refreshAutoPasteStateFromPermissions(updateStoredPreference: false)
    }

    private func handle(_ effect: PermissionEffect) {
        switch effect {
        case .requestAccessibility:
            Permissions.requestAccessibilityPermission()
        case .openAccessibilitySettings:
            dependencies.permissionClient.openAccessibilitySettings()
        case .resetStaleAccessibilityApproval:
            _ = dependencies.permissionClient.resetAccessibilityApproval(reason: "stale local Accessibility approval")
        }
    }

    private func refreshAutoPasteStateFromPermissions(updateStoredPreference: Bool) {
        let storedAutoPaste = AppSettings.shared.snapshot.autoPaste
        let permissionState = permissionFlowCoordinator.refresh(storedAutoPaste: storedAutoPaste)
        let accessibilityTrusted = permissionState.accessibilityTrusted
        let effectiveAutoPaste = permissionState.effectiveAutoPaste

        if storedAutoPaste && !accessibilityTrusted {
            let diagnostics = Permissions.getAccessibilityDiagnostics()
            DLOG("Auto-paste preference is on, but Accessibility is not trusted for this build; showing Auto-paste as off. bundle=\(diagnostics.bundleIdentifier), team=\(diagnostics.teamIdentifier.isEmpty ? "(none)" : diagnostics.teamIdentifier), adHoc=\(diagnostics.isAdHocSigned), fromXcode=\(diagnostics.isRunningFromXcode), executable=\(diagnostics.executablePath). If System Settings shows MacTalk enabled, that row is likely stale for a previous code signature/CDHash.")
            NSLog("⚠️ [MacTalk] Auto-paste preference is on, but Accessibility is not trusted for this build")
        }

        autoPaste = effectiveAutoPaste
        transcriber?.autoPasteEnabled = effectiveAutoPaste
        autoPasteMenuItem?.state = effectiveAutoPaste ? .on : .off

        if updateStoredPreference && storedAutoPaste != effectiveAutoPaste {
            AppSettings.shared.setAutoPaste(effectiveAutoPaste)
        }
    }

    private func abandonPendingStart() {
        outputCoordinator.cancel()
        pendingSettingsLatch.clear()
        pendingStartMode = nil
        pendingParakeetStartRetry = false
        pendingParakeetStartGeneration = nil
        isStartInFlight = false
    }

    private func invalidatePendingStart() {
        outputCoordinator.cancel()
        startGeneration += 1
        pendingParakeetStartRetry = false
        pendingParakeetStartGeneration = nil
        pendingSettingsLatch.clear()
        pendingStartMode = nil
        isStartInFlight = false
        startTask?.cancel()
        startTask = nil
    }

    private func toggleRecording() {
        if isRecording || isStartInFlight {
            stopRecording()
        } else {
            // Use current mode
            if mode == .micPlusAppAudio {
                // Need to show app picker first
                showAppPicker()
            } else {
                startRecording()
            }
        }
    }

    private func toggleMicOnly() {
        if isRecording || isStartInFlight {
            stopRecording()
        } else {
            startMicOnly()
        }
    }

    private func toggleMicPlusApp() {
        if isRecording || isStartInFlight {
            stopRecording()
        } else {
            startMicPlusApp()
        }
    }

    private func toggleHUD() {
        if let hud = hudController {
            if hud.window?.isVisible == true {
                hud.close()
            } else {
                hud.showWindow(nil)
            }
        }
    }
}
