//
//  StatusBarController.swift
//  MacTalk
//
//  Menu bar controller for MacTalk application
//

import AppKit

final class StatusBarController {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var engine: WhisperEngine?
    private var transcriber: TranscriptionController?
    private var hudController: HUDWindowController?
    private var settingsController: SettingsWindowController?

    private var autoPaste = false
    private var mode: TranscriptionController.Mode = .micOnly
    private var isRecording = false
    private var currentModelName = "ggml-large-v3-turbo-q5_0.gguf"
    private var selectedAudioSource: AppPickerWindowController.AudioSource?

    func show() {
        guard let button = statusItem.button else { return }

        // Set menu bar icon
        button.title = "🎙️"
        button.action = #selector(statusBarButtonClicked)
        button.target = self

        // Create menu
        let menu = NSMenu()

        // Recording controls
        let micOnlyItem = menu.addItem(
            withTitle: "Start (Mic Only)",
            action: #selector(startMicOnly),
            keyEquivalent: "m"
        )
        micOnlyItem.target = self

        let micPlusAppItem = menu.addItem(
            withTitle: "Start (Mic + App Audio)",
            action: #selector(startMicPlusApp),
            keyEquivalent: "a"
        )
        micPlusAppItem.target = self

        let stopItem = menu.addItem(
            withTitle: "Stop Recording",
            action: #selector(stopRecording),
            keyEquivalent: "s"
        )
        stopItem.target = self
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

        // Model selection submenu
        let modelMenu = NSMenu()
        let modelNames = [
            "ggml-tiny-q5_0.gguf",
            "ggml-base-q5_0.gguf",
            "ggml-small-q5_0.gguf",
            "ggml-medium-q5_0.gguf",
            "ggml-large-v3-turbo-q5_0.gguf"
        ]
        for modelName in modelNames {
            let item = NSMenuItem(
                title: modelName,
                action: #selector(selectModel(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = modelName
            item.state = modelName == currentModelName ? .on : .off
            modelMenu.addItem(item)
        }
        let modelItem = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        modelItem.submenu = modelMenu
        menu.addItem(modelItem)

        menu.addItem(NSMenuItem.separator())

        // Settings
        let settingsItem = menu.addItem(
            withTitle: "Settings...",
            action: #selector(showSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self

        // Permissions
        let permissionsItem = menu.addItem(
            withTitle: "Check Permissions",
            action: #selector(checkPermissions),
            keyEquivalent: ""
        )
        permissionsItem.target = self

        menu.addItem(NSMenuItem.separator())

        // About and Quit
        let aboutItem = menu.addItem(
            withTitle: "About MacTalk",
            action: #selector(showAbout),
            keyEquivalent: ""
        )
        aboutItem.target = self

        let quitItem = menu.addItem(
            withTitle: "Quit MacTalk",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self

        statusItem.menu = menu

        // Initialize HUD
        hudController = HUDWindowController()

        // Load default model
        prepareModel()
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
        let modelURL = ModelManager.ensureModelDownloaded(name: currentModelName)
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            showModelMissingAlert(modelName: currentModelName, path: modelURL.path)
            return
        }
        engine = WhisperEngine(modelURL: modelURL)
    }

    private func startRecording() {
        guard let engine = engine else {
            showError("Model not loaded. Please check that the model file exists.")
            return
        }

        let transcriptionController = TranscriptionController(engine: engine)
        transcriptionController.autoPasteEnabled = autoPaste

        transcriptionController.onPartial = { [weak self] text in
            DispatchQueue.main.async {
                self?.hudController?.update(text: text)
            }
        }

        transcriptionController.onFinal = { [weak self] text in
            DispatchQueue.main.async {
                self?.hudController?.update(text: "Final: \(text)")
                ClipboardManager.setClipboard(text)

                if self?.autoPaste == true {
                    ClipboardManager.pasteIfAllowed()
                }

                // Show notification
                self?.showNotification(title: "Transcription Complete", message: "Text copied to clipboard")
            }
        }

        transcriptionController.onMicLevel = { [weak self] levelData in
            DispatchQueue.main.async {
                self?.hudController?.updateMicLevel(
                    rms: levelData.rms,
                    peak: levelData.peak,
                    peakHold: levelData.peakHold
                )
            }
        }

        transcriptionController.onAppLevel = { [weak self] levelData in
            DispatchQueue.main.async {
                self?.hudController?.updateAppLevel(
                    rms: levelData.rms,
                    peak: levelData.peak,
                    peakHold: levelData.peakHold
                )
            }
        }

        transcriptionController.onAppAudioLost = { [weak self] in
            DispatchQueue.main.async {
                self?.showNotification(
                    title: "App Audio Lost",
                    message: "The selected app's audio stream was interrupted. Retrying..."
                )
            }
        }

        transcriptionController.onFallbackToMicOnly = { [weak self] in
            DispatchQueue.main.async {
                self?.showNotification(
                    title: "Switched to Mic-Only Mode",
                    message: "App audio could not be restored. Continuing with microphone only."
                )
                self?.hudController?.setAppMeterVisible(false)
            }
        }

        transcriber = transcriptionController

        Task {
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
                DispatchQueue.main.async {
                    self.showError("Failed to start recording: \(error.localizedDescription)")
                }
            }
        }
    }

    private func updateMenuBarIcon(recording: Bool) {
        statusItem.button?.title = recording ? "🔴" : "🎙️"
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
        let picker = AppPickerWindowController()
        picker.onSelection = { [weak self] source in
            self?.selectedAudioSource = source
            self?.startRecording()
        }
        picker.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
