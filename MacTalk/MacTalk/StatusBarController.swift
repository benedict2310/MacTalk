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
    private var transcriber: TranscriptionController?
    private var hudController: HUDWindowController?
    private var settingsController: SettingsWindowController?

    private var provider: ASRProvider = AppSettings.shared.provider
    private var autoPaste = false
    private var showNotifications = true  // Default to true
    private var mode: TranscriptionController.Mode = .micOnly
    private var isRecording = false
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

    // Hotkeys
    private let hotkeyManager = HotkeyManager()
    private var registeredHotkeyIDs: [String: UInt32] = [:]

    // Permission prompt throttling (CR-03)
    private var lastPermissionPromptTime: Date?
    private let permissionPromptCooldown: TimeInterval = 30.0 // 30 seconds between prompts

    // Menu items for shortcut display
    private var micOnlyMenuItem: NSMenuItem?
    private var micPlusAppMenuItem: NSMenuItem?
    // Use nonisolated(unsafe) because deinit cannot access @MainActor-isolated properties
    private nonisolated(unsafe) var notificationTokens: [NSObjectProtocol] = []

    init() {
        DLOG("=== StatusBarController.init() START ===")
        NSLog("🔧 [MacTalk] StatusBarController.init() called")

        // Load settings from UserDefaults
        let defaults = UserDefaults.standard
        autoPaste = defaults.bool(forKey: "autoPaste")
        provider = AppSettings.shared.provider

        // Show notifications defaults to true if not set
        if defaults.object(forKey: "showNotifications") != nil {
            showNotifications = defaults.bool(forKey: "showNotifications")
        } else {
            showNotifications = true  // Default
        }

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
                self?.shortcutsDidChange()
            }
        )

        // Listen for settings changes (including showNotifications)
        notificationTokens.append(
            NotificationCenter.default.addObserver(
                forName: .settingsDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.settingsDidChange()
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
                self?.providerDidChange(provider)
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
                self?.handleParakeetDownloadState(state)
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
        menu.addItem(autoPasteItem)

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
        startRecording()
    }

    @objc private func startMicPlusApp() {
        NSLog("🎙️ [StatusBar] Starting Mic + App Audio mode...")
        mode = .micPlusAppAudio

        // Check screen recording permission
        NSLog("🔍 [StatusBar] Checking screen recording permission...")
        if Permissions.checkScreenRecordingPermission() {
            NSLog("✅ [StatusBar] Permission granted, showing app picker")
            showAppPicker()
        } else {
            NSLog("❌ [StatusBar] Screen recording permission not granted - requesting...")
            // Request permission
            Permissions.requestScreenRecordingPermission()
            // Show guide to help user enable permission
            Permissions.ensureScreenRecordingGuide()
        }
    }

    @objc private func stopRecording() {
        guard isRecording else { return }
        transcriber?.stop()
        isRecording = false
        updateMenuBarIcon(recording: false)
        hudController?.close()
    }

    @objc private func toggleAutoPaste(_ sender: NSMenuItem) {
        autoPaste.toggle()
        sender.state = autoPaste ? .on : .off

        // Save to UserDefaults
        let defaults = UserDefaults.standard
        defaults.set(autoPaste, forKey: "autoPaste")
        NSLog("🔧 [MacTalk] Auto-paste setting changed to: \(autoPaste)")
    }

    @objc private func selectModel(_ sender: NSMenuItem) {
        guard let modelName = sender.representedObject as? String else { return }
        currentWhisperModelName = modelName

        requestProviderSwitch(to: .whisper, promptForDownload: false)
        updateProviderMenuState()

        // Reload model
        prepareWhisperModel()
    }

    @objc private func selectModelSpec(_ sender: NSMenuItem) {
        guard let spec = sender.representedObject as? ModelSpec else { return }
        selectedModel = spec
        currentWhisperModelName = spec.filename

        requestProviderSwitch(to: .whisper, promptForDownload: false)
        updateProviderMenuState()

        // Disable start items while downloading
        setStartItemsEnabled(false)

        // Prepare model with auto-download
        prepareWhisperModelWithAutoDownload(spec: spec)
    }

    @objc private func selectParakeet() {
        requestProviderSwitch(to: .parakeet, promptForDownload: true)
    }

    private func requestProviderSwitch(to newProvider: ASRProvider, promptForDownload: Bool) {
        guard provider != newProvider else { return }

        if newProvider == .parakeet, promptForDownload {
            let downloader = ParakeetModelDownloader()
            if !downloader.modelsAvailable() {
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

    @objc private func checkPermissions() {
        Permissions.ensureMic { micGranted in
            let alert = NSAlert()
            alert.messageText = "Permissions Status"
            alert.informativeText = """
            Microphone: \(micGranted ? "✅ Granted" : "❌ Denied")
            Screen Recording: Check System Settings
            Accessibility: \(Permissions.isAccessibilityTrusted() ? "✅ Granted" : "❌ Denied")
            """
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
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
            // Fallback to legacy behavior for models not in catalog
            let modelURL = ModelManager.ensureModelDownloaded(name: currentWhisperModelName)
            guard FileManager.default.fileExists(atPath: modelURL.path) else {
                showModelMissingAlert(modelName: currentWhisperModelName, path: modelURL.path)
                return
            }
            if provider == .whisper {
                engine = NativeWhisperEngine(modelURL: modelURL)
            }
        }
    }

    private func prepareWhisperModelWithAutoDownload(spec: ModelSpec) {
        // Check if model already exists
        if ModelStore.exists(spec) {
            // Model exists - load it directly
            let url = ModelStore.path(for: spec)
            if provider == .whisper {
                engine = NativeWhisperEngine(modelURL: url)
            }
            setStartItemsEnabled(true)
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
                if self?.provider == .whisper {
                    self?.engine = NativeWhisperEngine(modelURL: url)
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

    @MainActor
    private func prepareEngineForCurrentProvider() async {
        switch provider {
        case .whisper:
            prepareWhisperModel()
        case .parakeet:
            let downloader = ParakeetModelDownloader()
            guard downloader.modelsAvailable() else { return }
            await prepareParakeetEngine()
        }
    }

    @MainActor
    private func prepareParakeetEngine() async {
        setStartItemsEnabled(false)
        let engine = parakeetEngine ?? ParakeetEngine()
        do {
            try await engine.prepare()
            guard provider == .parakeet else {
                setStartItemsEnabled(true)
                return
            }
            parakeetEngine = engine
            self.engine = engine
            setStartItemsEnabled(true)
        } catch {
            setStartItemsEnabled(true)
            showError("Failed to load Parakeet engine: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func providerDidChange(_ newProvider: ASRProvider) {
        guard provider != newProvider else { return }

        let wasRecording = isRecording
        if wasRecording {
            stopRecording()
        }

        provider = newProvider
        engine = nil
        if newProvider == .whisper {
            parakeetEngine = nil
        }
        updateProviderMenuState()

        Task { [weak self] in
            guard let self else { return }
            await self.prepareEngineForCurrentProvider()
            guard wasRecording,
                  let engine = self.engine,
                  engine.provider == self.provider else { return }
            await MainActor.run {
                self.resumeRecordingAfterProviderSwitch()
            }
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
            NSLog("[StatusBar] onFinal callback triggered with text: \(text.prefix(100))...")
            self?.hudController?.updateFinal(text: text)

            let autoPasteEnabled = self?.autoPaste ?? false
            NSLog("[StatusBar] autoPaste setting: \(autoPasteEnabled)")

            // Always copy to clipboard first
            NSLog("[StatusBar] Copying text to clipboard...")
            ClipboardManager.setClipboard(text)

            // Auto-insert if enabled (uses AX SetValue first, then Cmd+V fallback)
            if autoPasteEnabled {
                NSLog("[StatusBar] Auto-paste is enabled - using AutoInsertManager...")
                let result = AutoInsertManager.insertText(text)
                NSLog("[StatusBar] Auto-insert result: \(result.description)")

                if case .permissionDenied = result {
                    // CR-03: Throttle permission prompts to avoid spam
                    let now = Date()
                    let shouldPrompt: Bool
                    if let lastPrompt = self?.lastPermissionPromptTime {
                        let elapsed = now.timeIntervalSince(lastPrompt)
                        shouldPrompt = elapsed >= (self?.permissionPromptCooldown ?? 30.0)
                        if !shouldPrompt {
                            NSLog("[StatusBar] Permission prompt throttled (last prompt \(Int(elapsed))s ago)")
                        }
                    } else {
                        shouldPrompt = true
                    }

                    if shouldPrompt {
                        NSLog("[StatusBar] Permission denied - requesting accessibility permission...")
                        self?.lastPermissionPromptTime = now
                        Permissions.requestAccessibilityPermission()
                    }
                }
            }

            // Show notification
            let message = autoPasteEnabled ? "Text pasted" : "Text copied to clipboard"
            NSLog("[StatusBar] Showing notification: \(message)")
            self?.showNotification(title: "Transcription Complete", message: message)
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
            self?.showNotification(
                title: "App Audio Lost",
                message: "The selected app's audio stream was interrupted. Retrying..."
            )
        }

        controller.onFallbackToMicOnly = { [weak self] in
            self?.showNotification(
                title: "Switched to Mic-Only Mode",
                message: "App audio could not be restored. Continuing with microphone only."
            )
            self?.hudController?.setAppMeterVisible(false)
        }
    }

    private func startRecording() {
        startRecording(allowParakeetPrepare: true)
    }

    private func startRecording(allowParakeetPrepare: Bool) {
        NSLog("🎬 [StatusBar] startRecording() called")
        NSLog("🎬 [StatusBar] Mode: \(mode)")
        if let source = selectedAudioSource {
            NSLog("🎬 [StatusBar] Audio source: \(source.name)")
        } else {
            NSLog("🎬 [StatusBar] Audio source: nil (mic-only mode)")
        }

        if let engine, engine.provider != provider {
            NSLog("⚠️ [StatusBar] Engine/provider mismatch (\(engine.provider) vs \(provider)) - clearing")
            self.engine = nil
        }

        if provider == .parakeet, engine == nil, allowParakeetPrepare {
            let downloader = ParakeetModelDownloader()
            if !downloader.modelsAvailable() {
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
                                    self.showError("Parakeet download failed: \(error.localizedDescription)")
                                }
                            }
                        }
                    }
                }
                return
            }

            Task { [weak self] in
                guard let self else { return }
                await self.prepareParakeetEngine()
                await MainActor.run {
                    guard self.provider == .parakeet else { return }
                    self.startRecording(allowParakeetPrepare: false)
                }
            }
            return
        }

        guard let engine = engine, engine.provider == provider else {
            NSLog("❌ [StatusBar] Engine not loaded or provider mismatch!")
            showError("Engine not loaded. Check that the \(provider.displayName) models are available.")
            return
        }

        NSLog("✅ [StatusBar] Engine available, creating TranscriptionController...")
        let transcriptionController = TranscriptionController(engine: engine)
        transcriptionController.autoPasteEnabled = autoPaste
        NSLog("🎬 [StatusBar] TranscriptionController created with autoPaste=\(autoPaste)")

        setupTranscriptionCallbacks(transcriptionController)
        transcriber = transcriptionController

        Task { [weak self] in
            guard let self else { return }
            do {
                if let source = selectedAudioSource {
                    NSLog("🚀 [StatusBar] Starting transcription with mode=\(mode), source=\(source.name)")
                } else {
                    NSLog("🚀 [StatusBar] Starting transcription with mode=\(mode), source=nil")
                }
                try await transcriptionController.start(
                    mode: mode,
                    audioSource: selectedAudioSource
                )
                await MainActor.run {
                    NSLog("✅ [StatusBar] Transcription started successfully")
                    self.isRecording = true
                    self.updateMenuBarIcon(recording: true)
                    self.hudController?.setAppMeterVisible(self.mode == .micPlusAppAudio)
                    self.hudController?.showWindow(nil)
                }
            } catch {
                NSLog("❌ [StatusBar] Failed to start recording: \(error.localizedDescription)")
                await MainActor.run {
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

    private func showNotification(title: String, message: String) {
        // Only show notifications if enabled in settings
        guard showNotifications else {
            NSLog("🔕 [MacTalk] Notifications disabled - skipping: \(title)")
            return
        }

        let notification = NSUserNotification()
        notification.title = title
        notification.informativeText = message
        notification.soundName = NSUserNotificationDefaultSoundName
        NSUserNotificationCenter.default.deliver(notification)
    }

    func cleanup() {
        transcriber?.stop()
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

                // Force window load synchronously BEFORE showing
                _ = picker.window
                NSLog("🎬 [StatusBar] Window loaded - now showing...")

                // Now show the window (data is already loaded and injected)
                picker.showWindow(nil)
                NSApp.activate(ignoringOtherApps: true)
                NSLog("✅ [StatusBar] App picker window shown successfully")

            } catch let error as ScreenCaptureError {
                NSLog("❌ [StatusBar] Screen capture error: \(error)")
                showError(error.localizedDescription ?? "Unknown screen capture error")
            } catch {
                NSLog("❌ [StatusBar] Failed to load audio sources: \(error)")
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
        // Reload settings from UserDefaults when they change
        let defaults = UserDefaults.standard
        autoPaste = defaults.bool(forKey: "autoPaste")

        let newShowNotifications = defaults.object(forKey: "showNotifications") != nil ?
            defaults.bool(forKey: "showNotifications") : true

        if newShowNotifications != showNotifications {
            NSLog("🔔 [MacTalk] Show notifications setting changed: \(showNotifications) → \(newShowNotifications)")
            showNotifications = newShowNotifications
        }
    }

    private func toggleRecording() {
        if isRecording {
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
        if isRecording {
            stopRecording()
        } else {
            startMicOnly()
        }
    }

    private func toggleMicPlusApp() {
        if isRecording {
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
