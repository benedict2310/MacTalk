//
//  AppPickerWindowController.swift
//  MacTalk
//
//  App picker dialog for selecting audio capture source
//

import AppKit
import ScreenCaptureKit

final class AppPickerWindowController: NSWindowController {

    // MARK: - UI Components

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let searchField = NSSearchField()
    private let selectButton = NSButton()
    private let cancelButton = NSButton()
    private let levelMeterView = AudioLevelMeterView()

    // MARK: - Data

    private var allAudioSources: [AudioSource] = []
    private var filteredSources: [AudioSource] = []
    private var selectedSource: AudioSource?

    var onSelection: ((AudioSource) -> Void)?

    // MARK: - Types

    struct AudioSource {
        let app: SCRunningApplication?
        let display: SCDisplay?
        let name: String
        let icon: NSImage?

        var isSystemAudio: Bool {
            return display != nil
        }

        static func fromApp(_ app: SCRunningApplication) -> AudioSource {
            AudioSource(
                app: app,
                display: nil,
                name: app.applicationName,
                icon: NSWorkspace.shared.icon(forFile: app.bundleIdentifier ?? "")
            )
        }

        static func systemAudio(display: SCDisplay) -> AudioSource {
            AudioSource(
                app: nil,
                display: display,
                name: "System Audio",
                icon: NSImage(systemSymbolName: "speaker.wave.3", accessibilityDescription: "System Audio")
            )
        }
    }

    // MARK: - Initialization

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Select Audio Source"
        window.center()

        self.init(window: window)

        setupUI()
        loadAudioSources()
    }

    // MARK: - UI Setup

    private func setupSearchField(in contentView: NSView) {
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Filter apps..."
        searchField.target = self
        searchField.action = #selector(searchFieldDidChange)
        contentView.addSubview(searchField)
    }

    private func setupTableView(in contentView: NSView) {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(doubleClickOnRow)
        tableView.allowsMultipleSelection = false

        // Add columns
        let iconColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("icon"))
        iconColumn.title = ""
        iconColumn.width = 40
        iconColumn.minWidth = 40
        iconColumn.maxWidth = 40
        tableView.addTableColumn(iconColumn)

        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.title = "Application"
        nameColumn.width = 300
        tableView.addTableColumn(nameColumn)

        // Scroll view
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        contentView.addSubview(scrollView)

        // Level meter preview
        levelMeterView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(levelMeterView)
    }

    private func setupButtons(in contentView: NSView) {
        selectButton.translatesAutoresizingMaskIntoConstraints = false
        selectButton.title = "Select"
        selectButton.bezelStyle = .rounded
        selectButton.keyEquivalent = "\r" // Enter key
        selectButton.target = self
        selectButton.action = #selector(selectButtonClicked)
        selectButton.isEnabled = false
        contentView.addSubview(selectButton)

        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.title = "Cancel"
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}" // Escape key
        cancelButton.target = self
        cancelButton.action = #selector(cancelButtonClicked)
        contentView.addSubview(cancelButton)
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        setupSearchField(in: contentView)
        setupTableView(in: contentView)
        setupButtons(in: contentView)

        // Layout constraints
        NSLayoutConstraint.activate([
            // Search field
            searchField.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            searchField.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            searchField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            // Scroll view
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            scrollView.bottomAnchor.constraint(equalTo: levelMeterView.topAnchor, constant: -12),

            // Level meter
            levelMeterView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            levelMeterView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            levelMeterView.bottomAnchor.constraint(equalTo: cancelButton.topAnchor, constant: -12),
            levelMeterView.heightAnchor.constraint(equalToConstant: 60),

            // Buttons
            cancelButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
            cancelButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            cancelButton.widthAnchor.constraint(equalToConstant: 100),

            selectButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
            selectButton.trailingAnchor.constraint(equalTo: cancelButton.leadingAnchor, constant: -12),
            selectButton.widthAnchor.constraint(equalToConstant: 100)
        ])
    }

    // MARK: - Data Loading

    private func loadAudioSources() {
        Task {
            do {
                let content = try await SCShareableContent.current

                var sources: [AudioSource] = []

                // Add system audio option
                if let display = content.displays.first {
                    sources.append(.systemAudio(display: display))
                }

                // Add running applications
                for app in content.applications {
                    // Filter out apps without windows
                    let hasWindow = content.windows.contains(where: { $0.owningApplication == app })
                    if hasWindow {
                        sources.append(.fromApp(app))
                    }
                }

                // Sort alphabetically
                sources.sort { $0.name < $1.name }

                await MainActor.run {
                    self.allAudioSources = sources
                    self.filteredSources = sources
                    self.tableView.reloadData()
                }
            } catch {
                await MainActor.run {
                    self.showError("Failed to load audio sources: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Actions

    @objc private func searchFieldDidChange() {
        let searchText = searchField.stringValue.lowercased()

        if searchText.isEmpty {
            filteredSources = allAudioSources
        } else {
            filteredSources = allAudioSources.filter { source in
                source.name.lowercased().contains(searchText)
            }
        }

        tableView.reloadData()
    }

    @objc private func selectButtonClicked() {
        guard let source = selectedSource else { return }
        onSelection?(source)
        close()
    }

    @objc private func cancelButtonClicked() {
        close()
    }

    @objc private func doubleClickOnRow() {
        let row = tableView.clickedRow
        guard row >= 0, row < filteredSources.count else { return }

        selectedSource = filteredSources[row]
        selectButtonClicked()
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Error"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - NSTableViewDataSource

extension AppPickerWindowController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return filteredSources.count
    }
}

// MARK: - NSTableViewDelegate

extension AppPickerWindowController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < filteredSources.count else { return nil }
        let source = filteredSources[row]

        if tableColumn?.identifier == NSUserInterfaceItemIdentifier("icon") {
            let imageView = NSImageView(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
            imageView.image = source.icon
            imageView.imageScaling = .scaleProportionallyUpOrDown
            return imageView
        } else if tableColumn?.identifier == NSUserInterfaceItemIdentifier("name") {
            let textField = NSTextField(labelWithString: source.name)
            return textField
        }

        return nil
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let selectedRow = tableView.selectedRow

        if selectedRow >= 0, selectedRow < filteredSources.count {
            selectedSource = filteredSources[selectedRow]
            selectButton.isEnabled = true

            // Note: Audio preview for selected source could be added in future
            // This would require starting a temporary capture to show levels
        } else {
            selectedSource = nil
            selectButton.isEnabled = false
        }
    }
}
