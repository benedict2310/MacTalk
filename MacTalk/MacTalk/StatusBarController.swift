//
//  StatusBarController.swift
//  MacTalk
//
//  Menu bar controller for MacTalk application
//

import AppKit

final class StatusBarController {
    // Create status item lazily to ensure proper registration on macOS 26 (Tahoe)
    private var statusItem: NSStatusItem!
    private var engine: WhisperEngine?
    private var transcriber: TranscriptionController?
    private var hudController: HUDWindowController?
    private var settingsController: SettingsWindowController?

    private var autoPaste = false
    private var mode: TranscriptionController.Mode = .micOnly
    private var isRecording = false
    private var currentModelName = "ggml-large-v3-turbo-q5_0.bin"
    private var selectedAudioSource: AppPickerWindowController.AudioSource?
    // FIX P0: Retain app picker to keep callbacks alive
    private var appPickerController: AppPickerWindowController?

    // Auto-download feature
    private var catalog = ModelCatalog.bundled()
    private var selectedModel: ModelSpec?
    private var progressItem: NSMenuItem?

    // Hotkeys
    private let hotkeyManager = HotkeyManager()
    private var registeredHotkeyIDs: [String: UInt32] = [:]

    init() {
        DLOG("=== StatusBarController.init() START ===")
        NSLog("🔧 [MacTalk] StatusBarController.init() called")

        // Listen for shortcut changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(shortcutsDidChange),
            name: .shortcutsDidChange,
            object: nil
        )

        DLOG("=== StatusBarController.init() END ===")
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

        // Set menu bar icon with SF Symbol for macOS 26 Tahoe transparency
        if let image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "MacTalk") {
            image.isTemplate = true  // Critical for visibility with Tahoe's transparent menu bar
            button.image = image
            button.imagePosition = .imageOnly
            NSLog("✅ [MacTalk] Set mic.fill icon (template: %d)", image.isTemplate)
        } else {
            // Fallback to emoji for older macOS
            button.title = "🎙️"
            NSLog("✅ [MacTalk] Set emoji icon as fallback")
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

        // Use ModelCatalog for model selection with display names
        for spec in catalog {
            let item = NSMenuItem(title: spec.displayName, action: #selector(selectModelSpec(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = spec
            item.state = spec.filename == currentModelName ? .on : .off
            modelMenu.addItem(item)
        }

        let modelItem = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        modelItem.submenu = modelMenu
        return modelItem
    }

    private func setupMenu() {
        // Create menu
        let menu = NSMenu()

        // Recording controls
        menu.addItem(withTitle: "Start (Mic Only)", action: #selector(startMicOnly), keyEquivalent: "m").target = self
        let micPlusAppItem = menu.addItem(
            withTitle: "Start (Mic + App Audio)",
            action: #selector(startMicPlusApp),
            keyEquivalent: "a"
        )
        micPlusAppItem.target = self
        menu.addItem(withTitle: "Stop Recording", action: #selector(stopRecording), keyEquivalent: "s").target = self
        menu.addItem(NSMenuItem.separator())

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
            DispatchQueue.main.async {
                self?.handleDownloadState(state)
            }
        }

        // Load default model (async to avoid blocking menu bar icon)
        DispatchQueue.main.async { [weak self] in
            self?.prepareModel()
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
        mode = .micPlusAppAudio
        showAppPicker()
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
    }

    @objc private func selectModel(_ sender: NSMenuItem) {
        guard let modelName = sender.representedObject as? String else { return }
        currentModelName = modelName

        // Update checkmarks
        if let menu = sender.menu {
            for item in menu.items {
                item.state = .off
            }
        }
        sender.state = .on

        // Reload model
        prepareModel()
    }

    @objc private func selectModelSpec(_ sender: NSMenuItem) {
        guard let spec = sender.representedObject as? ModelSpec else { return }
        selectedModel = spec
        currentModelName = spec.filename

        // Update checkmarks
        if let menu = sender.menu {
            for item in menu.items {
                item.state = .off
            }
        }
        sender.state = .on

        // Disable start items while downloading
        setStartItemsEnabled(false)

        // Prepare model with auto-download
        prepareModelWithAutoDownload(spec: spec)
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
            DispatchQueue.main.async {
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

    private func prepareModel() {
        // Find model spec from catalog
        if let spec = ModelCatalog.findByFilename(currentModelName) {
            prepareModelWithAutoDownload(spec: spec)
        } else {
            // Fallback to legacy behavior for models not in catalog
            let modelURL = ModelManager.ensureModelDownloaded(name: currentModelName)
            guard FileManager.default.fileExists(atPath: modelURL.path) else {
                showModelMissingAlert(modelName: currentModelName, path: modelURL.path)
                return
            }
            engine = WhisperEngine(modelURL: modelURL)
        }
    }

    private func prepareModelWithAutoDownload(spec: ModelSpec) {
        // Check if model already exists
        if ModelStore.exists(spec) {
            // Model exists - load it directly
            let url = ModelStore.path(for: spec)
            engine = WhisperEngine(modelURL: url)
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
            DispatchQueue.main.async {
                self?.setStartItemsEnabled(true)
                switch result {
                case .success(let url):
                    self?.engine = WhisperEngine(modelURL: url)
                case .failure(let error):
                    self?.progressItem?.title = "Model error: \(error.localizedDescription)"
                    self?.progressItem?.isHidden = false
                    self?.showError("Failed to load model: \(error.localizedDescription)")
                }
            }
        }
    }

    private func handleDownloadState(_ state: ModelDownloader.State) {
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

    private func setupTranscriptionCallbacks(_ controller: TranscriptionController) {
        controller.onPartial = { [weak self] text in
            DispatchQueue.main.async {
                self?.hudController?.update(text: text)
            }
        }

        controller.onFinal = { [weak self] text in
            DispatchQueue.main.async {
                self?.hudController?.update(text: "Final: \(text)")
                ClipboardManager.setClipboard(text)

                if self?.autoPaste == true {
                    ClipboardManager.pasteIfAllowed()
                }

                self?.showNotification(title: "Transcription Complete", message: "Text copied to clipboard")
            }
        }

        controller.onMicLevel = { [weak self] levelData in
            DispatchQueue.main.async {
                self?.hudController?.updateMicLevel(
                    rms: levelData.rms,
                    peak: levelData.peak,
                    peakHold: levelData.peakHold
                )
            }
        }

        controller.onAppLevel = { [weak self] levelData in
            DispatchQueue.main.async {
                self?.hudController?.updateAppLevel(
                    rms: levelData.rms,
                    peak: levelData.peak,
                    peakHold: levelData.peakHold
                )
            }
        }

        controller.onAppAudioLost = { [weak self] in
            DispatchQueue.main.async {
                self?.showNotification(
                    title: "App Audio Lost",
                    message: "The selected app's audio stream was interrupted. Retrying..."
                )
            }
        }

        controller.onFallbackToMicOnly = { [weak self] in
            DispatchQueue.main.async {
                self?.showNotification(
                    title: "Switched to Mic-Only Mode",
                    message: "App audio could not be restored. Continuing with microphone only."
                )
                self?.hudController?.setAppMeterVisible(false)
            }
        }
    }

    private func startRecording() {
        guard let engine = engine else {
            showError("Model not loaded. Please check that the model file exists.")
            return
        }

        let transcriptionController = TranscriptionController(engine: engine)
        transcriptionController.autoPasteEnabled = autoPaste

        setupTranscriptionCallbacks(transcriptionController)
        transcriber = transcriptionController

        Task { [self] in
            do {
                try await transcriptionController.start(
                    mode: mode,
                    audioSource: selectedAudioSource
                )
                DispatchQueue.main.async {
                    self.isRecording = true
                    self.updateMenuBarIcon(recording: true)
                    self.hudController?.setAppMeterVisible(mode == .micPlusAppAudio)
                    self.hudController?.showWindow(nil)
                }
            } catch {
                DispatchQueue.main.async { [self] in
                    self.showError("Failed to start recording: \(error.localizedDescription)")
                }
            }
        }
    }

    private func updateMenuBarIcon(recording: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let button = self.statusItem.button else { return }

            if recording {
                if let image = NSImage(systemSymbolName: "mic.fill.badge.plus", accessibilityDescription: "Recording") {
                    image.isTemplate = true
                    button.image = image
                    button.imagePosition = .imageOnly
                } else {
                    button.title = "🔴"
                }
            } else {
                if let image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "MacTalk") {
                    image.isTemplate = true
                    button.image = image
                    button.imagePosition = .imageOnly
                } else {
                    button.title = "🎙️"
                }
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

    // MARK: - App Picker

    private func showAppPicker() {
        // FIX P0: Retain the picker controller so it stays alive
        let picker = AppPickerWindowController()
        self.appPickerController = picker

        picker.onSelection = { [weak self] source in
            self?.selectedAudioSource = source
            self?.appPickerController = nil  // Release after selection
            self?.startRecording()
        }
        picker.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
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

        // Start/Stop Recording
        if let data = defaults.data(forKey: "startStopShortcut"),
           let shortcut = try? JSONDecoder().decode(KeyboardShortcut.self, from: data) {
            if let hotkeyID = hotkeyManager.register(
                keyCode: shortcut.keyCode,
                modifiers: shortcut.carbonModifiers,
                handler: { [weak self] in
                    self?.toggleRecording()
                }
            ) {
                registeredHotkeyIDs["startStop"] = hotkeyID
                NSLog("✅ [MacTalk] Registered Start/Stop shortcut: \(shortcut.displayString)")
            }
        }

        // Show/Hide HUD
        if let data = defaults.data(forKey: "showHideHUDShortcut"),
           let shortcut = try? JSONDecoder().decode(KeyboardShortcut.self, from: data) {
            if let hotkeyID = hotkeyManager.register(
                keyCode: shortcut.keyCode,
                modifiers: shortcut.carbonModifiers,
                handler: { [weak self] in
                    self?.toggleHUD()
                }
            ) {
                registeredHotkeyIDs["showHideHUD"] = hotkeyID
                NSLog("✅ [MacTalk] Registered Show/Hide HUD shortcut: \(shortcut.displayString)")
            }
        }

        // Open Settings
        if let data = defaults.data(forKey: "openSettingsShortcut"),
           let shortcut = try? JSONDecoder().decode(KeyboardShortcut.self, from: data) {
            if let hotkeyID = hotkeyManager.register(
                keyCode: shortcut.keyCode,
                modifiers: shortcut.carbonModifiers,
                handler: { [weak self] in
                    self?.showSettings()
                }
            ) {
                registeredHotkeyIDs["openSettings"] = hotkeyID
                NSLog("✅ [MacTalk] Registered Open Settings shortcut: \(shortcut.displayString)")
            }
        }
    }

    @objc private func shortcutsDidChange() {
        registerShortcuts()
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
