//
//  SettingsWindowController.swift
//  MacTalk
//
//  Settings window with tabbed interface for MacTalk configuration
//

import AppKit
import Carbon

final class SettingsWindowController: NSWindowController {

    // MARK: - Properties

    private let tabView = NSTabView()

    // General tab controls
    private let launchAtLoginCheckbox = NSButton(checkboxWithTitle: "Launch at Login", target: nil, action: nil)
    private let showInDockCheckbox = NSButton(checkboxWithTitle: "Show in Dock", target: nil, action: nil)
    private let showNotificationsCheckbox = NSButton(checkboxWithTitle: "Show Notifications", target: nil, action: nil)

    // Output tab controls
    private let autoPasteCheckbox = NSButton(checkboxWithTitle: "Auto-paste Transcript on Stop", target: nil, action: nil)
    private let copyToClipboardCheckbox = NSButton(checkboxWithTitle: "Copy to Clipboard", target: nil, action: nil)
    private let showTimestampsCheckbox = NSButton(checkboxWithTitle: "Include Timestamps", target: nil, action: nil)

    // Audio tab controls
    private let defaultModePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let silenceDetectionCheckbox = NSButton(checkboxWithTitle: "Enable Silence Detection", target: nil, action: nil)
    private let silenceThresholdSlider = NSSlider()
    private let silenceThresholdLabel = NSTextField(labelWithString: "Silence Threshold:")
    private let silenceThresholdValueLabel = NSTextField(labelWithString: "-40 dB")

    // Advanced tab controls
    private let modelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let languagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let translateCheckbox = NSButton(checkboxWithTitle: "Translate to English", target: nil, action: nil)
    private let beamSizeSlider = NSSlider()
    private let beamSizeLabel = NSTextField(labelWithString: "Beam Size:")
    private let beamSizeValueLabel = NSTextField(labelWithString: "5")

    // Shortcuts tab controls
    private let startMicOnlyRecorder = ShortcutRecorderView()
    private let startMicPlusAppRecorder = ShortcutRecorderView()
    private let showHideHUDRecorder = ShortcutRecorderView()
    private let openSettingsRecorder = ShortcutRecorderView()

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
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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
        launchAtLoginCheckbox.frame = NSRect(x: 20, y: 280, width: 440, height: 25)
        launchAtLoginCheckbox.target = self
        launchAtLoginCheckbox.action = #selector(generalSettingChanged)

        showInDockCheckbox.frame = NSRect(x: 20, y: 250, width: 440, height: 25)
        showInDockCheckbox.target = self
        showInDockCheckbox.action = #selector(generalSettingChanged)

        showNotificationsCheckbox.frame = NSRect(x: 20, y: 220, width: 440, height: 25)
        showNotificationsCheckbox.target = self
        showNotificationsCheckbox.action = #selector(generalSettingChanged)
        showNotificationsCheckbox.state = .on  // Default to on

        let infoLabel = NSTextField(labelWithString: "General application preferences")
        infoLabel.frame = NSRect(x: 20, y: 180, width: 440, height: 20)
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)

        view.addSubview(launchAtLoginCheckbox)
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

        copyToClipboardCheckbox.frame = NSRect(x: 20, y: 250, width: 440, height: 25)
        copyToClipboardCheckbox.target = self
        copyToClipboardCheckbox.action = #selector(outputSettingChanged)
        copyToClipboardCheckbox.state = .on  // Default to on

        showTimestampsCheckbox.frame = NSRect(x: 20, y: 220, width: 440, height: 25)
        showTimestampsCheckbox.target = self
        showTimestampsCheckbox.action = #selector(outputSettingChanged)

        let infoLabel = NSTextField(labelWithString: "Configure how transcripts are delivered")
        infoLabel.frame = NSRect(x: 20, y: 180, width: 440, height: 20)
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)

        view.addSubview(autoPasteCheckbox)
        view.addSubview(copyToClipboardCheckbox)
        view.addSubview(showTimestampsCheckbox)
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

        // Silence detection
        silenceDetectionCheckbox.frame = NSRect(x: 20, y: 240, width: 440, height: 25)
        silenceDetectionCheckbox.target = self
        silenceDetectionCheckbox.action = #selector(silenceDetectionToggled)

        // Silence threshold
        silenceThresholdLabel.frame = NSRect(x: 40, y: 210, width: 120, height: 20)
        silenceThresholdLabel.isEditable = false
        silenceThresholdLabel.isBordered = false
        silenceThresholdLabel.backgroundColor = .clear

        silenceThresholdSlider.frame = NSRect(x: 170, y: 210, width: 200, height: 20)
        silenceThresholdSlider.minValue = -60
        silenceThresholdSlider.maxValue = -10
        silenceThresholdSlider.doubleValue = -40
        silenceThresholdSlider.target = self
        silenceThresholdSlider.action = #selector(silenceThresholdChanged)
        silenceThresholdSlider.isEnabled = false  // Disabled until checkbox is on

        silenceThresholdValueLabel.frame = NSRect(x: 380, y: 210, width: 60, height: 20)
        silenceThresholdValueLabel.isEditable = false
        silenceThresholdValueLabel.isBordered = false
        silenceThresholdValueLabel.backgroundColor = .clear
        silenceThresholdValueLabel.alignment = .right

        let infoLabel = NSTextField(labelWithString: "Configure audio capture and processing")
        infoLabel.frame = NSRect(x: 20, y: 170, width: 440, height: 20)
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)

        view.addSubview(modeLabel)
        view.addSubview(defaultModePopup)
        view.addSubview(silenceDetectionCheckbox)
        view.addSubview(silenceThresholdLabel)
        view.addSubview(silenceThresholdSlider)
        view.addSubview(silenceThresholdValueLabel)
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

        // Show/Hide HUD
        let showHideLabel = NSTextField(labelWithString: "Show/Hide HUD:")
        showHideLabel.frame = NSRect(x: 20, y: 180, width: 180, height: 25)
        showHideLabel.isEditable = false
        showHideLabel.isBordered = false
        showHideLabel.backgroundColor = .clear

        showHideHUDRecorder.frame = NSRect(x: 210, y: 180, width: 250, height: 25)
        showHideHUDRecorder.onShortcutChanged = { [weak self] shortcut in
            self?.saveShortcut(shortcut, forKey: "showHideHUDShortcut")
        }

        // Open Settings
        let openSettingsLabel = NSTextField(labelWithString: "Open Settings:")
        openSettingsLabel.frame = NSRect(x: 20, y: 145, width: 180, height: 25)
        openSettingsLabel.isEditable = false
        openSettingsLabel.isBordered = false
        openSettingsLabel.backgroundColor = .clear

        openSettingsRecorder.frame = NSRect(x: 210, y: 145, width: 250, height: 25)
        openSettingsRecorder.onShortcutChanged = { [weak self] shortcut in
            self?.saveShortcut(shortcut, forKey: "openSettingsShortcut")
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
        view.addSubview(showHideLabel)
        view.addSubview(showHideHUDRecorder)
        view.addSubview(openSettingsLabel)
        view.addSubview(openSettingsRecorder)
        view.addSubview(infoLabel)
        view.addSubview(resetButton)

        tab.view = view
        return tab
    }

    private func createAdvancedTab() -> NSTabViewItem {
        let tab = NSTabViewItem(identifier: "advanced")
        tab.label = "Advanced"

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 340))

        // Model selection
        let modelLabel = NSTextField(labelWithString: "Model:")
        modelLabel.frame = NSRect(x: 20, y: 280, width: 120, height: 25)
        modelLabel.isEditable = false
        modelLabel.isBordered = false
        modelLabel.backgroundColor = .clear

        modelPopup.frame = NSRect(x: 150, y: 280, width: 300, height: 25)
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

        // Language selection
        let languageLabel = NSTextField(labelWithString: "Language:")
        languageLabel.frame = NSRect(x: 20, y: 245, width: 120, height: 25)
        languageLabel.isEditable = false
        languageLabel.isBordered = false
        languageLabel.backgroundColor = .clear

        languagePopup.frame = NSRect(x: 150, y: 245, width: 200, height: 25)
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
        languagePopup.target = self
        languagePopup.action = #selector(advancedSettingChanged)

        // Translate checkbox
        translateCheckbox.frame = NSRect(x: 20, y: 210, width: 440, height: 25)
        translateCheckbox.target = self
        translateCheckbox.action = #selector(advancedSettingChanged)

        // Beam size
        beamSizeLabel.frame = NSRect(x: 20, y: 175, width: 120, height: 20)
        beamSizeLabel.isEditable = false
        beamSizeLabel.isBordered = false
        beamSizeLabel.backgroundColor = .clear

        beamSizeSlider.frame = NSRect(x: 150, y: 175, width: 200, height: 20)
        beamSizeSlider.minValue = 1
        beamSizeSlider.maxValue = 10
        beamSizeSlider.intValue = 5
        beamSizeSlider.target = self
        beamSizeSlider.action = #selector(beamSizeChanged)

        beamSizeValueLabel.frame = NSRect(x: 360, y: 175, width: 60, height: 20)
        beamSizeValueLabel.isEditable = false
        beamSizeValueLabel.isBordered = false
        beamSizeValueLabel.backgroundColor = .clear
        beamSizeValueLabel.alignment = .right

        let infoLabel = NSTextField(labelWithString: "Advanced transcription settings (affects quality and speed)")
        infoLabel.frame = NSRect(x: 20, y: 135, width: 440, height: 20)
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)

        view.addSubview(modelLabel)
        view.addSubview(modelPopup)
        view.addSubview(languageLabel)
        view.addSubview(languagePopup)
        view.addSubview(translateCheckbox)
        view.addSubview(beamSizeLabel)
        view.addSubview(beamSizeSlider)
        view.addSubview(beamSizeValueLabel)
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

        let micLabel = NSTextField(labelWithString: "🎤 Microphone Access:")
        micLabel.frame = NSRect(x: 20, y: 250, width: 200, height: 25)
        micLabel.isEditable = false
        micLabel.isBordered = false
        micLabel.backgroundColor = .clear

        let micStatusLabel = NSTextField(labelWithString: "Check Status")
        micStatusLabel.frame = NSRect(x: 230, y: 250, width: 120, height: 25)
        micStatusLabel.isEditable = false
        micStatusLabel.isBordered = false
        micStatusLabel.backgroundColor = .clear
        micStatusLabel.textColor = .secondaryLabelColor

        let screenLabel = NSTextField(labelWithString: "📺 Screen Recording:")
        screenLabel.frame = NSRect(x: 20, y: 220, width: 200, height: 25)
        screenLabel.isEditable = false
        screenLabel.isBordered = false
        screenLabel.backgroundColor = .clear

        let screenStatusLabel = NSTextField(labelWithString: "Check Status")
        screenStatusLabel.frame = NSRect(x: 230, y: 220, width: 120, height: 25)
        screenStatusLabel.isEditable = false
        screenStatusLabel.isBordered = false
        screenStatusLabel.backgroundColor = .clear
        screenStatusLabel.textColor = .secondaryLabelColor

        let accessibilityLabel = NSTextField(labelWithString: "♿ Accessibility:")
        accessibilityLabel.frame = NSRect(x: 20, y: 190, width: 200, height: 25)
        accessibilityLabel.isEditable = false
        accessibilityLabel.isBordered = false
        accessibilityLabel.backgroundColor = .clear

        let accessibilityStatusLabel = NSTextField(labelWithString: "Check Status")
        accessibilityStatusLabel.frame = NSRect(x: 230, y: 190, width: 120, height: 25)
        accessibilityStatusLabel.isEditable = false
        accessibilityStatusLabel.isBordered = false
        accessibilityStatusLabel.backgroundColor = .clear
        accessibilityStatusLabel.textColor = .secondaryLabelColor

        // Open System Settings button
        let openSettingsButton = NSButton(title: "Open System Settings", target: self, action: #selector(openSystemSettings))
        openSettingsButton.frame = NSRect(x: 20, y: 140, width: 200, height: 30)
        openSettingsButton.bezelStyle = .rounded

        let infoLabel = NSTextField(wrappingLabelWithString: """
        MacTalk requires certain permissions to function properly:

        • Microphone: To capture your voice
        • Screen Recording: To capture app audio (Mode B only)
        • Accessibility: To auto-paste transcripts (optional)

        If permissions are denied, you can grant them in System Settings.
        """)
        infoLabel.frame = NSRect(x: 20, y: 20, width: 440, height: 100)
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)

        view.addSubview(titleLabel)
        view.addSubview(micLabel)
        view.addSubview(micStatusLabel)
        view.addSubview(screenLabel)
        view.addSubview(screenStatusLabel)
        view.addSubview(accessibilityLabel)
        view.addSubview(accessibilityStatusLabel)
        view.addSubview(openSettingsButton)
        view.addSubview(infoLabel)

        tab.view = view
        return tab
    }

    // MARK: - Settings Management

    private func loadSettings() {
        let defaults = UserDefaults.standard

        // General
        launchAtLoginCheckbox.state = defaults.bool(forKey: "launchAtLogin") ? .on : .off
        showInDockCheckbox.state = defaults.bool(forKey: "showInDock") ? .on : .off
        showNotificationsCheckbox.state = defaults.bool(forKey: "showNotifications") ? .on : .off

        // Shortcuts
        startMicOnlyRecorder.shortcut = loadShortcut(forKey: "startMicOnlyShortcut")
        startMicPlusAppRecorder.shortcut = loadShortcut(forKey: "startMicPlusAppShortcut")
        showHideHUDRecorder.shortcut = loadShortcut(forKey: "showHideHUDShortcut")
        openSettingsRecorder.shortcut = loadShortcut(forKey: "openSettingsShortcut")

        // Output
        autoPasteCheckbox.state = defaults.bool(forKey: "autoPaste") ? .on : .off
        copyToClipboardCheckbox.state = defaults.bool(forKey: "copyToClipboard") ? .on : .off
        showTimestampsCheckbox.state = defaults.bool(forKey: "showTimestamps") ? .on : .off

        // Audio
        defaultModePopup.selectItem(at: defaults.integer(forKey: "defaultMode"))
        silenceDetectionCheckbox.state = defaults.bool(forKey: "silenceDetection") ? .on : .off
        let threshold = defaults.double(forKey: "silenceThreshold")
        if threshold != 0 {
            silenceThresholdSlider.doubleValue = threshold
        } else {
            silenceThresholdSlider.doubleValue = -40
        }
        silenceThresholdValueLabel.stringValue = "\(Int(silenceThresholdSlider.doubleValue)) dB"
        silenceThresholdSlider.isEnabled = silenceDetectionCheckbox.state == .on

        // Advanced
        let modelIndex = defaults.integer(forKey: "modelIndex")
        if modelIndex > 0 {
            modelPopup.selectItem(at: modelIndex)
        } else {
            modelPopup.selectItem(at: 4)  // Default to large-v3-turbo
        }

        languagePopup.selectItem(at: defaults.integer(forKey: "languageIndex"))
        translateCheckbox.state = defaults.bool(forKey: "translate") ? .on : .off

        let beamSize = defaults.integer(forKey: "beamSize")
        if beamSize > 0 {
            beamSizeSlider.intValue = Int32(beamSize)
        } else {
            beamSizeSlider.intValue = 5
        }
        beamSizeValueLabel.stringValue = "\(beamSizeSlider.intValue)"
    }

    private func saveSettings() {
        let defaults = UserDefaults.standard

        // General
        defaults.set(launchAtLoginCheckbox.state == .on, forKey: "launchAtLogin")
        defaults.set(showInDockCheckbox.state == .on, forKey: "showInDock")
        defaults.set(showNotificationsCheckbox.state == .on, forKey: "showNotifications")

        // Output
        defaults.set(autoPasteCheckbox.state == .on, forKey: "autoPaste")
        defaults.set(copyToClipboardCheckbox.state == .on, forKey: "copyToClipboard")
        defaults.set(showTimestampsCheckbox.state == .on, forKey: "showTimestamps")

        // Audio
        defaults.set(defaultModePopup.indexOfSelectedItem, forKey: "defaultMode")
        defaults.set(silenceDetectionCheckbox.state == .on, forKey: "silenceDetection")
        defaults.set(silenceThresholdSlider.doubleValue, forKey: "silenceThreshold")

        // Advanced
        defaults.set(modelPopup.indexOfSelectedItem, forKey: "modelIndex")
        defaults.set(languagePopup.indexOfSelectedItem, forKey: "languageIndex")
        defaults.set(translateCheckbox.state == .on, forKey: "translate")
        defaults.set(beamSizeSlider.intValue, forKey: "beamSize")
    }

    // MARK: - Actions

    @objc private func generalSettingChanged() {
        saveSettings()
    }

    @objc private func outputSettingChanged() {
        saveSettings()
    }

    @objc private func audioSettingChanged() {
        saveSettings()
    }

    @objc private func advancedSettingChanged() {
        saveSettings()
    }

    @objc private func silenceDetectionToggled() {
        silenceThresholdSlider.isEnabled = silenceDetectionCheckbox.state == .on
        saveSettings()
    }

    @objc private func silenceThresholdChanged() {
        silenceThresholdValueLabel.stringValue = "\(Int(silenceThresholdSlider.doubleValue)) dB"
        saveSettings()
    }

    @objc private func beamSizeChanged() {
        beamSizeValueLabel.stringValue = "\(beamSizeSlider.intValue)"
        saveSettings()
    }

    @objc private func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
            NSWorkspace.shared.open(url)
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

        // No defaults for other shortcuts
        showHideHUDRecorder.shortcut = nil
        saveShortcut(nil, forKey: "showHideHUDShortcut")

        openSettingsRecorder.shortcut = nil
        saveShortcut(nil, forKey: "openSettingsShortcut")
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

// MARK: - Notification Names

extension Notification.Name {
    static let shortcutsDidChange = Notification.Name("shortcutsDidChange")
}
