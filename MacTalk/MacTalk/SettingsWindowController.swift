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
    private let showInDockCheckbox = NSButton(checkboxWithTitle: "Show in Dock", target: nil, action: nil)
    private let showNotificationsCheckbox = NSButton(checkboxWithTitle: "Show Notifications", target: nil, action: nil)

    // Output tab controls
    private let autoPasteCheckbox = NSButton(checkboxWithTitle: "Auto-paste Transcript on Stop", target: nil, action: nil)
    private let copyToClipboardCheckbox = NSButton(checkboxWithTitle: "Copy to Clipboard", target: nil, action: nil)

    // Audio tab controls
    private let defaultModePopup = NSPopUpButton(frame: .zero, pullsDown: false)

    // Advanced tab controls
    private let modelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let languagePopup = NSPopUpButton(frame: .zero, pullsDown: false)

    // Shortcuts tab controls
    private let startMicOnlyRecorder = ShortcutRecorderView()
    private let startMicPlusAppRecorder = ShortcutRecorderView()

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

        copyToClipboardCheckbox.frame = NSRect(x: 20, y: 250, width: 440, height: 25)
        copyToClipboardCheckbox.target = self
        copyToClipboardCheckbox.action = #selector(outputSettingChanged)
        copyToClipboardCheckbox.state = .on  // Default to on

        let infoLabel = NSTextField(labelWithString: "Configure how transcripts are delivered")
        infoLabel.frame = NSRect(x: 20, y: 210, width: 440, height: 20)
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)

        view.addSubview(autoPasteCheckbox)
        view.addSubview(copyToClipboardCheckbox)
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
        languagePopup.selectItem(at: 1)  // Default to English
        languagePopup.target = self
        languagePopup.action = #selector(advancedSettingChanged)

        let infoLabel = NSTextField(labelWithString: "Whisper model and language settings")
        infoLabel.frame = NSRect(x: 20, y: 205, width: 440, height: 20)
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)

        view.addSubview(modelLabel)
        view.addSubview(modelPopup)
        view.addSubview(languageLabel)
        view.addSubview(languagePopup)
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
        showInDockCheckbox.state = defaults.bool(forKey: "showInDock") ? .on : .off
        showNotificationsCheckbox.state = defaults.bool(forKey: "showNotifications") ? .on : .off

        // Shortcuts
        startMicOnlyRecorder.shortcut = loadShortcut(forKey: "startMicOnlyShortcut")
        startMicPlusAppRecorder.shortcut = loadShortcut(forKey: "startMicPlusAppShortcut")

        // Output
        autoPasteCheckbox.state = defaults.bool(forKey: "autoPaste") ? .on : .off
        copyToClipboardCheckbox.state = defaults.bool(forKey: "copyToClipboard") ? .on : .off

        // Audio
        defaultModePopup.selectItem(at: defaults.integer(forKey: "defaultMode"))

        // Advanced
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
    }

    private func saveSettings() {
        let defaults = UserDefaults.standard

        // General
        defaults.set(showInDockCheckbox.state == .on, forKey: "showInDock")
        defaults.set(showNotificationsCheckbox.state == .on, forKey: "showNotifications")

        // Output
        defaults.set(autoPasteCheckbox.state == .on, forKey: "autoPaste")
        defaults.set(copyToClipboardCheckbox.state == .on, forKey: "copyToClipboard")

        // Audio
        defaults.set(defaultModePopup.indexOfSelectedItem, forKey: "defaultMode")

        // Advanced
        defaults.set(modelPopup.indexOfSelectedItem, forKey: "modelIndex")
        defaults.set(languagePopup.indexOfSelectedItem, forKey: "languageIndex")
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
