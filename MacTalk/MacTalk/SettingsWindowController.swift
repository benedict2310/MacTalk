//
//  SettingsWindowController.swift
//  MacTalk
//
//  Settings window with tabbed interface for MacTalk configuration
//

// swiftlint:disable type_body_length

import AppKit
import Carbon

@MainActor
final class SettingsWindowController: NSWindowController, @unchecked Sendable {

    // MARK: - Properties

    private let tabView = NSTabView()

    // General tab controls
    private let showInDockCheckbox = NSButton(checkboxWithTitle: "Show in Dock", target: nil, action: nil)
    private let showNotificationsCheckbox = NSButton(checkboxWithTitle: "Show Notifications", target: nil, action: nil)

    // Output tab controls
    private let autoPasteCheckbox = NSButton(checkboxWithTitle: "Auto-paste Transcript on Stop", target: nil, action: nil)

    // Audio tab controls
    private let defaultModePopup = NSPopUpButton(frame: .zero, pullsDown: false)

    // Advanced tab controls
    private let providerPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let modelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let parakeetModelLabel = NSTextField(labelWithString: "Parakeet TDT 0.6B (Core ML)")
    private let languagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let engineStatusIndicator = NSProgressIndicator()
    private let engineStatusValueLabel = NSTextField(labelWithString: "")
    private let downloadProgressIndicator = NSProgressIndicator()
    private let downloadProgressLabel = NSTextField(labelWithString: "Download:")
    private let parakeetDownloadButton = NSButton(title: "Download Parakeet Model", target: nil, action: nil)

    // Permissions tab controls (stored for live updates)
    private var micStatusLabel: NSTextField?
    private var screenStatusLabel: NSTextField?
    private var accessibilityStatusLabel: NSTextField?

    // Shortcuts tab controls
    private let startMicOnlyRecorder = ShortcutRecorderView()
    private let startMicPlusAppRecorder = ShortcutRecorderView()

    private nonisolated(unsafe) var notificationTokens: [NSObjectProtocol] = []
    private var currentProvider: ASRProvider = AppSettings.shared.provider

    // MARK: - Initialization

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "MacTalk Settings"
        window.center()

        super.init(window: window)

        setupUI()
        loadSettings()
        startObservingEngineState()

        // Refresh permission status when window becomes key
        notificationTokens.append(
            NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.refreshPermissionStatus()
            }
        )

        // Initial refresh
        refreshPermissionStatus()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
    }

    // MARK: - UI Setup

    private func setupUI() {
        guard let window = window else { return }

        let containerView = NSView(frame: window.contentView!.bounds)
        containerView.autoresizingMask = [.width, .height]

        // Setup tab view
        tabView.frame = containerView.bounds
        tabView.autoresizingMask = [.width, .height]
        tabView.tabViewType = .topTabsBezelBorder

        // Add tabs
        tabView.addTabViewItem(createGeneralTab())
        tabView.addTabViewItem(createOutputTab())
        tabView.addTabViewItem(createAudioTab())
        tabView.addTabViewItem(createShortcutsTab())
        tabView.addTabViewItem(createAdvancedTab())
        tabView.addTabViewItem(createPermissionsTab())

        containerView.addSubview(tabView)
        window.contentView = containerView
    }

    private func createGeneralTab() -> NSTabViewItem {
        let tab = NSTabViewItem(identifier: "general")
        tab.label = "General"

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 340))

        // Layout controls
        showInDockCheckbox.frame = NSRect(x: 20, y: 280, width: 440, height: 25)
        showInDockCheckbox.target = self
        showInDockCheckbox.action = #selector(generalSettingChanged)

        showNotificationsCheckbox.frame = NSRect(x: 20, y: 250, width: 440, height: 25)
        showNotificationsCheckbox.target = self
        showNotificationsCheckbox.action = #selector(generalSettingChanged)
        showNotificationsCheckbox.state = .on  // Default to on

        let infoLabel = NSTextField(labelWithString: "General application preferences")
        infoLabel.frame = NSRect(x: 20, y: 210, width: 440, height: 20)
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)

        view.addSubview(showInDockCheckbox)
        view.addSubview(showNotificationsCheckbox)
        view.addSubview(infoLabel)

        tab.view = view
        return tab
    }

    private func createOutputTab() -> NSTabViewItem {
        let tab = NSTabViewItem(identifier: "output")
        tab.label = "Output"

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 340))

        // Layout controls
        autoPasteCheckbox.frame = NSRect(x: 20, y: 280, width: 440, height: 25)
        autoPasteCheckbox.target = self
        autoPasteCheckbox.action = #selector(outputSettingChanged)

        let infoLabel = NSTextField(labelWithString: "Transcript is always copied to clipboard. Enable auto-paste to automatically paste it.")
        infoLabel.frame = NSRect(x: 20, y: 240, width: 440, height: 40)
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        infoLabel.lineBreakMode = .byWordWrapping

        view.addSubview(autoPasteCheckbox)
        view.addSubview(infoLabel)

        tab.view = view
        return tab
    }

    private func createAudioTab() -> NSTabViewItem {
        let tab = NSTabViewItem(identifier: "audio")
        tab.label = "Audio"

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 340))

        // Default mode
        let modeLabel = NSTextField(labelWithString: "Default Mode:")
        modeLabel.frame = NSRect(x: 20, y: 280, width: 120, height: 25)
        modeLabel.isEditable = false
        modeLabel.isBordered = false
        modeLabel.backgroundColor = .clear

        defaultModePopup.frame = NSRect(x: 150, y: 280, width: 200, height: 25)
        defaultModePopup.addItems(withTitles: ["Mic Only", "Mic + App Audio"])
        defaultModePopup.target = self
        defaultModePopup.action = #selector(audioSettingChanged)

        let infoLabel = NSTextField(labelWithString: "Configure audio capture mode")
        infoLabel.frame = NSRect(x: 20, y: 240, width: 440, height: 20)
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)

        view.addSubview(modeLabel)
        view.addSubview(defaultModePopup)
        view.addSubview(infoLabel)

        tab.view = view
        return tab
    }

    private func createShortcutsTab() -> NSTabViewItem {
        let tab = NSTabViewItem(identifier: "shortcuts")
        tab.label = "Shortcuts"

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 340))

        // Title
        let titleLabel = NSTextField(labelWithString: "Keyboard Shortcuts")
        titleLabel.frame = NSRect(x: 20, y: 290, width: 440, height: 25)
        titleLabel.font = NSFont.boldSystemFont(ofSize: 14)
        titleLabel.isEditable = false
        titleLabel.isBordered = false
        titleLabel.backgroundColor = .clear

        // Start Mic-Only Recording
        let startMicOnlyLabel = NSTextField(labelWithString: "Start Mic-Only:")
        startMicOnlyLabel.frame = NSRect(x: 20, y: 250, width: 180, height: 25)
        startMicOnlyLabel.isEditable = false
        startMicOnlyLabel.isBordered = false
        startMicOnlyLabel.backgroundColor = .clear

        startMicOnlyRecorder.frame = NSRect(x: 210, y: 250, width: 250, height: 25)
        startMicOnlyRecorder.onShortcutChanged = { [weak self] shortcut in
            self?.saveShortcut(shortcut, forKey: "startMicOnlyShortcut")
        }

        // Start Mic + App Audio Recording
        let startMicPlusAppLabel = NSTextField(labelWithString: "Start Mic + App Audio:")
        startMicPlusAppLabel.frame = NSRect(x: 20, y: 215, width: 180, height: 25)
        startMicPlusAppLabel.isEditable = false
        startMicPlusAppLabel.isBordered = false
        startMicPlusAppLabel.backgroundColor = .clear

        startMicPlusAppRecorder.frame = NSRect(x: 210, y: 215, width: 250, height: 25)
        startMicPlusAppRecorder.onShortcutChanged = { [weak self] shortcut in
            self?.saveShortcut(shortcut, forKey: "startMicPlusAppShortcut")
        }

        // Info text
        let infoLabel = NSTextField(wrappingLabelWithString: """
        Click on a shortcut field and press the desired key combination.
        Shortcuts must include at least one modifier key (⌘, ⌃, ⌥, or ⇧).

        Note: Shortcuts are global and will work even when MacTalk is in the background.
        """)
        infoLabel.frame = NSRect(x: 20, y: 90, width: 440, height: 70)
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)

        // Reset to defaults button
        let resetButton = NSButton(title: "Reset to Defaults", target: self, action: #selector(resetShortcutsToDefaults))
        resetButton.frame = NSRect(x: 20, y: 50, width: 150, height: 30)
        resetButton.bezelStyle = .rounded

        view.addSubview(titleLabel)
        view.addSubview(startMicOnlyLabel)
        view.addSubview(startMicOnlyRecorder)
        view.addSubview(startMicPlusAppLabel)
        view.addSubview(startMicPlusAppRecorder)
        view.addSubview(infoLabel)
        view.addSubview(resetButton)

        tab.view = view
        return tab
    }

    private func createAdvancedTab() -> NSTabViewItem {
        let tab = NSTabViewItem(identifier: "advanced")
        tab.label = "Advanced"

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 340))

        // Provider selection
        let providerLabel = NSTextField(labelWithString: "Provider:")
        providerLabel.frame = NSRect(x: 20, y: 290, width: 120, height: 25)
        providerLabel.isEditable = false
        providerLabel.isBordered = false
        providerLabel.backgroundColor = .clear

        providerPopup.frame = NSRect(x: 150, y: 290, width: 200, height: 25)
        providerPopup.addItems(withTitles: ASRProvider.allCases.map { $0.displayName })
        providerPopup.target = self
        providerPopup.action = #selector(providerSelectionChanged)

        // Model selection
        let modelLabel = NSTextField(labelWithString: "Model:")
        modelLabel.frame = NSRect(x: 20, y: 255, width: 120, height: 25)
        modelLabel.isEditable = false
        modelLabel.isBordered = false
        modelLabel.backgroundColor = .clear

        modelPopup.frame = NSRect(x: 150, y: 255, width: 300, height: 25)
        modelPopup.addItems(withTitles: [
            "tiny (75 MB, fastest)",
            "base (140 MB, very fast)",
            "small (460 MB, balanced)",
            "medium (1.4 GB, accurate)",
            "large-v3-turbo (2.8 GB, best)"
        ])
        modelPopup.selectItem(at: 4)  // Default to large-v3-turbo
        modelPopup.target = self
        modelPopup.action = #selector(advancedSettingChanged)

        parakeetModelLabel.frame = NSRect(x: 150, y: 255, width: 300, height: 25)
        parakeetModelLabel.textColor = .secondaryLabelColor
        parakeetModelLabel.isHidden = true

        // Language selection
        let languageLabel = NSTextField(labelWithString: "Language:")
        languageLabel.frame = NSRect(x: 20, y: 220, width: 120, height: 25)
        languageLabel.isEditable = false
        languageLabel.isBordered = false
        languageLabel.backgroundColor = .clear

        languagePopup.frame = NSRect(x: 150, y: 220, width: 200, height: 25)
        languagePopup.addItems(withTitles: [
            "Auto-detect",
            "English",
            "Spanish",
            "French",
            "German",
            "Italian",
            "Portuguese",
            "Dutch",
            "Japanese",
            "Chinese"
        ])
        languagePopup.selectItem(at: 1)  // Default to English
        languagePopup.target = self
        languagePopup.action = #selector(advancedSettingChanged)

        // Engine status row
        let statusLabel = NSTextField(labelWithString: "Status:")
        statusLabel.frame = NSRect(x: 20, y: 185, width: 120, height: 20)
        statusLabel.isEditable = false
        statusLabel.isBordered = false
        statusLabel.backgroundColor = .clear

        engineStatusIndicator.frame = NSRect(x: 150, y: 188, width: 14, height: 14)
        engineStatusIndicator.style = .spinning
        engineStatusIndicator.controlSize = .small
        engineStatusIndicator.isIndeterminate = true
        engineStatusIndicator.isDisplayedWhenStopped = false

        engineStatusValueLabel.frame = NSRect(x: 172, y: 183, width: 278, height: 20)
        engineStatusValueLabel.textColor = .secondaryLabelColor

        // Download progress
        downloadProgressLabel.frame = NSRect(x: 20, y: 150, width: 120, height: 20)
        downloadProgressLabel.textColor = .secondaryLabelColor

        downloadProgressIndicator.frame = NSRect(x: 150, y: 150, width: 300, height: 16)
        downloadProgressIndicator.isIndeterminate = false
        downloadProgressIndicator.minValue = 0
        downloadProgressIndicator.maxValue = 1
        downloadProgressIndicator.doubleValue = 0
        downloadProgressIndicator.isHidden = true

        parakeetDownloadButton.frame = NSRect(x: 150, y: 120, width: 220, height: 30)
        parakeetDownloadButton.bezelStyle = .rounded
        parakeetDownloadButton.target = self
        parakeetDownloadButton.action = #selector(downloadParakeetModel)
        parakeetDownloadButton.isHidden = true

        let infoLabel = NSTextField(labelWithString: "Model and language settings")
        infoLabel.frame = NSRect(x: 20, y: 85, width: 440, height: 20)
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)

        view.addSubview(providerLabel)
        view.addSubview(providerPopup)
        view.addSubview(modelLabel)
        view.addSubview(modelPopup)
        view.addSubview(parakeetModelLabel)
        view.addSubview(languageLabel)
        view.addSubview(languagePopup)
        view.addSubview(statusLabel)
        view.addSubview(engineStatusIndicator)
        view.addSubview(engineStatusValueLabel)
        view.addSubview(downloadProgressLabel)
        view.addSubview(downloadProgressIndicator)
        view.addSubview(parakeetDownloadButton)
        view.addSubview(infoLabel)

        tab.view = view
        return tab
    }

    private func createPermissionsTab() -> NSTabViewItem {
        let tab = NSTabViewItem(identifier: "permissions")
        tab.label = "Permissions"

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 340))

        // Permission status labels
        let titleLabel = NSTextField(labelWithString: "Required Permissions")
        titleLabel.frame = NSRect(x: 20, y: 290, width: 440, height: 25)
        titleLabel.font = NSFont.boldSystemFont(ofSize: 14)
        titleLabel.isEditable = false
        titleLabel.isBordered = false
        titleLabel.backgroundColor = .clear

        let micLabel = NSTextField(labelWithString: "Microphone Access:")
        micLabel.frame = NSRect(x: 20, y: 250, width: 180, height: 25)
        micLabel.isEditable = false
        micLabel.isBordered = false
        micLabel.backgroundColor = .clear

        let micStatus = NSTextField(labelWithString: "Checking...")
        micStatus.frame = NSRect(x: 210, y: 250, width: 150, height: 25)
        micStatus.isEditable = false
        micStatus.isBordered = false
        micStatus.backgroundColor = .clear
        micStatus.textColor = .secondaryLabelColor
        self.micStatusLabel = micStatus

        let screenLabel = NSTextField(labelWithString: "Screen Recording:")
        screenLabel.frame = NSRect(x: 20, y: 220, width: 180, height: 25)
        screenLabel.isEditable = false
        screenLabel.isBordered = false
        screenLabel.backgroundColor = .clear

        let screenStatus = NSTextField(labelWithString: "Checking...")
        screenStatus.frame = NSRect(x: 210, y: 220, width: 150, height: 25)
        screenStatus.isEditable = false
        screenStatus.isBordered = false
        screenStatus.backgroundColor = .clear
        screenStatus.textColor = .secondaryLabelColor
        self.screenStatusLabel = screenStatus

        let accessibilityLabel = NSTextField(labelWithString: "Accessibility:")
        accessibilityLabel.frame = NSRect(x: 20, y: 190, width: 180, height: 25)
        accessibilityLabel.isEditable = false
        accessibilityLabel.isBordered = false
        accessibilityLabel.backgroundColor = .clear

        let accessibilityStatus = NSTextField(labelWithString: "Checking...")
        accessibilityStatus.frame = NSRect(x: 210, y: 190, width: 150, height: 25)
        accessibilityStatus.isEditable = false
        accessibilityStatus.isBordered = false
        accessibilityStatus.backgroundColor = .clear
        accessibilityStatus.textColor = .secondaryLabelColor
        self.accessibilityStatusLabel = accessibilityStatus

        // Buttons row
        let refreshButton = NSButton(title: "Refresh", target: self, action: #selector(refreshPermissionsTapped))
        refreshButton.frame = NSRect(x: 20, y: 140, width: 90, height: 30)
        refreshButton.bezelStyle = .rounded

        let openAccessibilityButton = NSButton(title: "Open Accessibility Settings", target: self, action: #selector(openAccessibilitySettings))
        openAccessibilityButton.frame = NSRect(x: 120, y: 140, width: 190, height: 30)
        openAccessibilityButton.bezelStyle = .rounded

        let diagnosticsButton = NSButton(title: "Diagnostics...", target: self, action: #selector(showDiagnostics))
        diagnosticsButton.frame = NSRect(x: 320, y: 140, width: 130, height: 30)
        diagnosticsButton.bezelStyle = .rounded

        let infoLabel = NSTextField(wrappingLabelWithString: """
        MacTalk requires certain permissions to function properly:

        • Microphone: To capture your voice
        • Screen Recording: To capture app audio (Mic + App mode only)
        • Accessibility: To auto-paste transcripts (optional)

        Permission changes take effect immediately - no restart needed.
        """)
        infoLabel.frame = NSRect(x: 20, y: 20, width: 440, height: 100)
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)

        view.addSubview(titleLabel)
        view.addSubview(micLabel)
        view.addSubview(micStatus)
        view.addSubview(screenLabel)
        view.addSubview(screenStatus)
        view.addSubview(accessibilityLabel)
        view.addSubview(accessibilityStatus)
        view.addSubview(refreshButton)
        view.addSubview(openAccessibilityButton)
        view.addSubview(diagnosticsButton)
        view.addSubview(infoLabel)

        tab.view = view
        return tab
    }

    // MARK: - Settings Management

    private func loadSettings() {
        let defaults = UserDefaults.standard

        // General
        showInDockCheckbox.state = defaults.bool(forKey: "showInDock") ? .on : .off
        showNotificationsCheckbox.state = defaults.bool(forKey: "showNotifications") ? .on : .off

        // Shortcuts
        startMicOnlyRecorder.shortcut = loadShortcut(forKey: "startMicOnlyShortcut")
        startMicPlusAppRecorder.shortcut = loadShortcut(forKey: "startMicPlusAppShortcut")

        // Output
        autoPasteCheckbox.state = defaults.bool(forKey: "autoPaste") ? .on : .off

        // Audio
        defaultModePopup.selectItem(at: defaults.integer(forKey: "defaultMode"))

        // Advanced - provider
        currentProvider = AppSettings.shared.provider
        if let providerIndex = ASRProvider.allCases.firstIndex(of: currentProvider) {
            providerPopup.selectItem(at: providerIndex)
        }

        // Advanced - Whisper model and language
        let modelIndex = defaults.integer(forKey: "modelIndex")
        if modelIndex > 0 {
            modelPopup.selectItem(at: modelIndex)
        } else {
            modelPopup.selectItem(at: 4)  // Default to large-v3-turbo
        }

        let languageIndex = defaults.integer(forKey: "languageIndex")
        if languageIndex > 0 {
            languagePopup.selectItem(at: languageIndex)
        } else {
            languagePopup.selectItem(at: 1)  // Default to English
        }

        updateProviderUI()
    }

    private func saveSettings() {
        let defaults = UserDefaults.standard

        // General
        defaults.set(showInDockCheckbox.state == .on, forKey: "showInDock")
        defaults.set(showNotificationsCheckbox.state == .on, forKey: "showNotifications")

        // Output
        defaults.set(autoPasteCheckbox.state == .on, forKey: "autoPaste")

        // Audio
        defaults.set(defaultModePopup.indexOfSelectedItem, forKey: "defaultMode")

        // Advanced
        defaults.set(modelPopup.indexOfSelectedItem, forKey: "modelIndex")
        defaults.set(languagePopup.indexOfSelectedItem, forKey: "languageIndex")

        // Notify that settings changed
        NotificationCenter.default.post(name: .settingsDidChange, object: nil)
    }

    // MARK: - Actions

    @objc private func generalSettingChanged() {
        saveSettings()

        // Update activation policy immediately when Show in Dock changes
        let showInDock = showInDockCheckbox.state == .on
        let policy: NSApplication.ActivationPolicy = showInDock ? .regular : .accessory
        NSLog("⚙️ [Settings] Changing activation policy to \(showInDock ? ".regular (show in dock)" : ".accessory (menu bar only)")")
        NSApp.setActivationPolicy(policy)

        if showInDock {
            // Activate the app to show the icon in the dock
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc private func outputSettingChanged() {
        // Check if user is enabling auto-paste
        let isEnablingAutoPaste = (autoPasteCheckbox.state == .on)

        if isEnablingAutoPaste {
            // Check accessibility permission proactively
            if !Permissions.isAccessibilityTrusted() {
                NSLog("⚠️ [Settings] Auto-paste enabled but accessibility permission not granted")

                // Show alert to inform user
                let alert = NSAlert()
                alert.messageText = "Accessibility Permission Needed"
                alert.informativeText = """
                Auto-paste requires Accessibility permission.

                Would you like to grant this permission now?
                """
                alert.alertStyle = .informational
                alert.addButton(withTitle: "Grant Permission")
                alert.addButton(withTitle: "Later")

                let response = alert.runModal()
                if response == .alertFirstButtonReturn {
                    // Request permission with system prompt
                    Permissions.requestAccessibilityPermission()
                }
            }
        }

        saveSettings()
    }

    @objc private func audioSettingChanged() {
        saveSettings()
    }

    @objc private func advancedSettingChanged() {
        saveSettings()
    }

    @objc private func providerSelectionChanged() {
        guard let selectedTitle = providerPopup.titleOfSelectedItem,
              let selectedProvider = ASRProvider.allCases.first(where: { $0.displayName == selectedTitle }) else {
            return
        }

        if selectedProvider == currentProvider {
            if selectedProvider == .parakeet, !ParakeetModelDownloader().modelsAvailable() {
                showParakeetDownloadConfirmation { [weak self] approved in
                    guard let self = self else { return }
                    if approved {
                        Task {
                            do {
                                try await ParakeetBootstrap.shared.downloadModels()
                            } catch {
                                self.updateEngineStatus(.failed(error.localizedDescription))
                            }
                        }
                    }
                }
            }
            return
        }

        if selectedProvider == .parakeet {
            let downloader = ParakeetModelDownloader()
            if !downloader.modelsAvailable() {
                showParakeetDownloadConfirmation { [weak self] approved in
                    guard let self = self else { return }
                    if approved {
                        self.currentProvider = .parakeet
                        AppSettings.shared.provider = .parakeet
                        self.updateProviderUI()
                        Task {
                            do {
                                try await ParakeetBootstrap.shared.downloadModels()
                            } catch {
                                self.updateEngineStatus(.failed(error.localizedDescription))
                            }
                        }
                    } else {
                        self.restoreProviderSelection()
                    }
                }
                return
            }
        }

        currentProvider = selectedProvider
        AppSettings.shared.provider = selectedProvider
        updateProviderUI()
    }

    @objc private func downloadParakeetModel() {
        showParakeetDownloadConfirmation { [weak self] approved in
            guard let self = self else { return }
            if approved {
                Task {
                    do {
                        try await ParakeetBootstrap.shared.downloadModels()
                    } catch {
                        self.updateEngineStatus(.failed(error.localizedDescription))
                    }
                }
            }
        }
    }

    @objc private func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Permission Status

    /// Refresh all permission status labels
    private func refreshPermissionStatus() {
        // Microphone status
        let micStatus = Permissions.microphoneAuthorizationStatus()
        switch micStatus {
        case .authorized:
            micStatusLabel?.stringValue = "Granted"
            micStatusLabel?.textColor = .systemGreen
        case .denied:
            micStatusLabel?.stringValue = "Denied"
            micStatusLabel?.textColor = .systemRed
        case .restricted:
            micStatusLabel?.stringValue = "Restricted"
            micStatusLabel?.textColor = .systemOrange
        case .notDetermined:
            micStatusLabel?.stringValue = "Not Asked"
            micStatusLabel?.textColor = .secondaryLabelColor
        @unknown default:
            micStatusLabel?.stringValue = "Unknown"
            micStatusLabel?.textColor = .secondaryLabelColor
        }

        // Screen recording status
        let hasScreenPermission = Permissions.checkScreenRecordingPermission()
        screenStatusLabel?.stringValue = hasScreenPermission ? "Granted" : "Not Granted"
        screenStatusLabel?.textColor = hasScreenPermission ? .systemGreen : .systemOrange

        // Accessibility status (updates immediately without restart)
        let hasAccessibility = Permissions.isAccessibilityTrusted()
        accessibilityStatusLabel?.stringValue = hasAccessibility ? "Granted" : "Not Granted"
        accessibilityStatusLabel?.textColor = hasAccessibility ? .systemGreen : .systemOrange
    }

    @objc private func refreshPermissionsTapped() {
        refreshPermissionStatus()
    }

    @objc private func openAccessibilitySettings() {
        // Use the modern deep-link URL for macOS 13+
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility") {
            if !NSWorkspace.shared.open(url) {
                // Fallback to legacy URL
                if let legacyURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(legacyURL)
                }
            }
        }
    }

    @objc private func showDiagnostics() {
        let diagnostics = Permissions.getAccessibilityDiagnostics()
        let report = diagnostics.formattedReport

        let alert = NSAlert()
        alert.messageText = "Permission Diagnostics"
        alert.informativeText = report
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Copy to Clipboard")
        alert.addButton(withTitle: "OK")

        if let window = window {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report, forType: .string)
                }
            }
        } else {
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(report, forType: .string)
            }
        }
    }

    @objc private func resetShortcutsToDefaults() {
        // Default: Cmd+Shift+M for Mic-Only
        let defaultMicOnly = KeyboardShortcut(
            keyCode: UInt32(kVK_ANSI_M),
            modifierFlags: [.command, .shift]
        )
        startMicOnlyRecorder.shortcut = defaultMicOnly
        saveShortcut(defaultMicOnly, forKey: "startMicOnlyShortcut")

        // Default: Cmd+Shift+A for Mic + App Audio
        let defaultMicPlusApp = KeyboardShortcut(
            keyCode: UInt32(kVK_ANSI_A),
            modifierFlags: [.command, .shift]
        )
        startMicPlusAppRecorder.shortcut = defaultMicPlusApp
        saveShortcut(defaultMicPlusApp, forKey: "startMicPlusAppShortcut")
    }

    // MARK: - Parakeet Status

    private func startObservingEngineState() {
        notificationTokens.append(
            NotificationCenter.default.addObserver(
                forName: .parakeetEngineStateDidChange,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let state = notification.object as? ParakeetBootstrap.EngineState else { return }
                self?.updateEngineStatus(state)
            }
        )

        notificationTokens.append(
            NotificationCenter.default.addObserver(
                forName: .parakeetDownloadStateDidChange,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let state = notification.object as? ParakeetModelDownloader.State else { return }
                self?.updateDownloadStatus(state)
            }
        )

        notificationTokens.append(
            NotificationCenter.default.addObserver(
                forName: .providerDidChange,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let provider = notification.object as? ASRProvider else { return }
                self?.currentProvider = provider
                self?.restoreProviderSelection()
                self?.updateProviderUI()
            }
        )

        updateEngineStatus(ParakeetBootstrap.shared.currentState())
    }

    private func updateProviderUI() {
        let isParakeet = currentProvider == .parakeet
        modelPopup.isHidden = isParakeet
        parakeetModelLabel.isHidden = !isParakeet
        downloadProgressIndicator.isHidden = true
        downloadProgressLabel.isHidden = true
        parakeetDownloadButton.isHidden = !isParakeet || ParakeetModelDownloader().modelsAvailable()
        updateEngineStatus(ParakeetBootstrap.shared.currentState())
    }

    private func updateEngineStatus(_ state: ParakeetBootstrap.EngineState) {
        guard currentProvider == .parakeet else {
            engineStatusIndicator.stopAnimation(nil)
            engineStatusValueLabel.stringValue = "Ready"
            engineStatusValueLabel.textColor = .secondaryLabelColor
            downloadProgressIndicator.isHidden = true
            downloadProgressLabel.isHidden = true
            return
        }

        switch state {
        case .idle:
            engineStatusIndicator.stopAnimation(nil)
            if ParakeetModelDownloader().modelsAvailable() {
                engineStatusValueLabel.stringValue = "Model downloaded"
                parakeetDownloadButton.isHidden = true
            } else {
                engineStatusValueLabel.stringValue = "Model not downloaded"
                parakeetDownloadButton.isHidden = false
            }
            engineStatusValueLabel.textColor = .secondaryLabelColor
            downloadProgressIndicator.isHidden = true
            downloadProgressLabel.isHidden = true
        case .downloading:
            engineStatusIndicator.startAnimation(nil)
            engineStatusValueLabel.stringValue = "Downloading model…"
            engineStatusValueLabel.textColor = .controlTextColor
            parakeetDownloadButton.isHidden = true
            downloadProgressIndicator.isHidden = false
            downloadProgressLabel.isHidden = false
        case .loading:
            engineStatusIndicator.startAnimation(nil)
            engineStatusValueLabel.stringValue = "Loading engine…"
            engineStatusValueLabel.textColor = .controlTextColor
            parakeetDownloadButton.isHidden = true
            downloadProgressIndicator.isHidden = true
            downloadProgressLabel.isHidden = true
        case .ready:
            engineStatusIndicator.stopAnimation(nil)
            engineStatusValueLabel.stringValue = "Ready"
            engineStatusValueLabel.textColor = .secondaryLabelColor
            downloadProgressIndicator.isHidden = true
            downloadProgressLabel.isHidden = true
            parakeetDownloadButton.isHidden = true
        case .failed(let message):
            engineStatusIndicator.stopAnimation(nil)
            engineStatusValueLabel.stringValue = "Error: \(message)"
            engineStatusValueLabel.textColor = .systemRed
            downloadProgressIndicator.isHidden = true
            downloadProgressLabel.isHidden = true
            parakeetDownloadButton.isHidden = ParakeetModelDownloader().modelsAvailable()
        }
    }

    private func updateDownloadStatus(_ state: ParakeetModelDownloader.State) {
        guard currentProvider == .parakeet else { return }

        switch state {
        case .running(let progress, let index, let count, _):
            downloadProgressIndicator.isHidden = false
            downloadProgressLabel.isHidden = false
            downloadProgressIndicator.doubleValue = progress
            engineStatusIndicator.startAnimation(nil)
            engineStatusValueLabel.stringValue = "Downloading… \(index)/\(count)"
            engineStatusValueLabel.textColor = .controlTextColor
            parakeetDownloadButton.isHidden = true
        case .verifying:
            downloadProgressIndicator.isHidden = false
            downloadProgressLabel.isHidden = false
            engineStatusIndicator.startAnimation(nil)
            engineStatusValueLabel.stringValue = "Verifying download…"
            engineStatusValueLabel.textColor = .controlTextColor
            parakeetDownloadButton.isHidden = true
        case .done:
            downloadProgressIndicator.isHidden = true
            downloadProgressLabel.isHidden = true
            updateEngineStatus(ParakeetBootstrap.shared.currentState())
        case .failed(let error):
            downloadProgressIndicator.isHidden = true
            downloadProgressLabel.isHidden = true
            updateEngineStatus(.failed(error.localizedDescription))
        default:
            break
        }
    }

    private func restoreProviderSelection() {
        if let index = ASRProvider.allCases.firstIndex(of: currentProvider) {
            providerPopup.selectItem(at: index)
        }
    }

    private func showParakeetDownloadConfirmation(completion: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Download Parakeet Model?"
        alert.informativeText = "This will download approximately 600MB of model files."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Cancel")

        if let window = window {
            alert.beginSheetModal(for: window) { response in
                completion(response == .alertFirstButtonReturn)
            }
        } else {
            completion(alert.runModal() == .alertFirstButtonReturn)
        }
    }

    // MARK: - Shortcut Helpers

    private func saveShortcut(_ shortcut: KeyboardShortcut?, forKey key: String) {
        let defaults = UserDefaults.standard
        if let shortcut = shortcut {
            if let data = try? JSONEncoder().encode(shortcut) {
                defaults.set(data, forKey: key)
            }
        } else {
            defaults.removeObject(forKey: key)
        }
        // Notify that shortcuts changed
        NotificationCenter.default.post(name: .shortcutsDidChange, object: nil)
    }

    private func loadShortcut(forKey key: String) -> KeyboardShortcut? {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(KeyboardShortcut.self, from: data)
    }
}
