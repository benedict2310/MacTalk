//
//  SettingsWindowController.swift
//  MacTalk
//
//  Settings window — modern SwiftUI with Liquid Glass on macOS 26.4+
//

import AppKit
import SwiftUI
import Carbon

// MARK: - SwiftUI Settings Views

@available(macOS 26.4, *)
struct SettingsContentView: View {
    @StateObject private var vm = SettingsViewModel()

    var body: some View {
        TabView {
            GeneralTab(vm: vm)
                .tabItem { Label("General", systemImage: "gearshape") }
            OutputTab(vm: vm)
                .tabItem { Label("Output", systemImage: "doc.on.clipboard") }
            AudioTab(vm: vm)
                .tabItem { Label("Audio", systemImage: "waveform") }
            ShortcutsTab(vm: vm)
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
            AdvancedTab(vm: vm)
                .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
            PermissionsTab(vm: vm)
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
        }
        .frame(width: 480, height: 360)
    }
}

// MARK: - ViewModel

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var showInDock: Bool
    @Published var showNotifications: Bool
    @Published var autoPaste: Bool
    @Published var defaultModeIndex: Int
    @Published var providerIndex: Int
    @Published var modelIndex: Int
    @Published var languageIndex: Int
    @Published var micStatus: PermissionState = .checking
    @Published var screenStatus: PermissionState = .checking
    @Published var accessibilityStatus: PermissionState = .checking
    @Published var engineState: ParakeetBootstrap.EngineState = .idle
    @Published var downloadProgress: Double = 0
    @Published var downloadVisible: Bool = false

    // Shortcut recorders (AppKit bridge — kept as pass-through)
    var startMicOnlyShortcut: KeyboardShortcut?
    var startMicPlusAppShortcut: KeyboardShortcut?

    enum PermissionState: String {
        case checking = "Checking…"
        case granted = "Granted"
        case denied = "Denied"
        case notGranted = "Not Granted"
        case notAsked = "Not Asked"
    }

    private nonisolated(unsafe) var tokens: [NSObjectProtocol] = []

    init() {
        let d = UserDefaults.standard
        showInDock = d.bool(forKey: "showInDock")
        showNotifications = d.bool(forKey: "showNotifications")
        autoPaste = d.bool(forKey: "autoPaste")
        defaultModeIndex = d.integer(forKey: "defaultMode")
        let provider = AppSettings.shared.provider
        providerIndex = ASRProvider.allCases.firstIndex(of: provider) ?? 0
        let savedModel = d.integer(forKey: "modelIndex")
        modelIndex = savedModel == 0 ? 4 : savedModel
        let savedLang = d.integer(forKey: "languageIndex")
        languageIndex = savedLang == 0 ? 1 : savedLang

        startMicOnlyShortcut = Self.loadShortcut(forKey: "startMicOnlyShortcut")
        startMicPlusAppShortcut = Self.loadShortcut(forKey: "startMicPlusAppShortcut")

        refreshPermissions()
        observeEngine()
    }

    deinit {
        let captured = tokens
        for t in captured { NotificationCenter.default.removeObserver(t) }
    }

    // MARK: - Save

    func save() {
        let d = UserDefaults.standard
        d.set(showInDock, forKey: "showInDock")
        d.set(showNotifications, forKey: "showNotifications")
        d.set(autoPaste, forKey: "autoPaste")
        d.set(defaultModeIndex, forKey: "defaultMode")
        d.set(modelIndex, forKey: "modelIndex")
        d.set(languageIndex, forKey: "languageIndex")
        NotificationCenter.default.post(name: .settingsDidChange, object: nil)
    }

    func applyDockPolicy() {
        let policy: NSApplication.ActivationPolicy = showInDock ? .regular : .accessory
        NSApp.setActivationPolicy(policy)
        if showInDock { NSApp.activate(ignoringOtherApps: true) }
    }

    func setProvider(_ idx: Int) {
        providerIndex = idx
        let provider = ASRProvider.allCases[idx]
        AppSettings.shared.provider = provider
        save()
    }

    // MARK: - Permissions

    func refreshPermissions() {
        let mic = Permissions.microphoneAuthorizationStatus()
        switch mic {
        case .authorized: micStatus = .granted
        case .denied: micStatus = .denied
        case .notDetermined: micStatus = .notAsked
        default: micStatus = .notGranted
        }

        screenStatus = Permissions.checkScreenRecordingPermission() ? .granted : .notGranted
        accessibilityStatus = Permissions.isAccessibilityTrusted() ? .granted : .notGranted
    }

    // MARK: - Engine

    private func observeEngine() {
        tokens.append(NotificationCenter.default.addObserver(
            forName: .parakeetEngineStateDidChange, object: nil, queue: .main
        ) { [weak self] n in
            if let s = n.object as? ParakeetBootstrap.EngineState { self?.engineState = s }
        })

        tokens.append(NotificationCenter.default.addObserver(
            forName: .parakeetDownloadStateDidChange, object: nil, queue: .main
        ) { [weak self] n in
            guard let state = n.object as? ParakeetModelDownloader.State else { return }
            switch state {
            case .running(let p, _, _, _):
                self?.downloadVisible = true
                self?.downloadProgress = p
            case .verifying:
                self?.downloadVisible = true
            case .done, .failed:
                self?.downloadVisible = false
            default: break
            }
        })

        engineState = ParakeetBootstrap.shared.currentState()
    }

    // MARK: - Shortcuts

    static func loadShortcut(forKey key: String) -> KeyboardShortcut? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(KeyboardShortcut.self, from: data)
    }

    func saveShortcut(_ s: KeyboardShortcut?, forKey key: String) {
        if let s, let data = try? JSONEncoder().encode(s) {
            UserDefaults.standard.set(data, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        NotificationCenter.default.post(name: .shortcutsDidChange, object: nil)
    }
}

// MARK: - Tab Views

@available(macOS 26.4, *)
private struct GeneralTab: View {
    @ObservedObject var vm: SettingsViewModel
    var body: some View {
        Form {
            Toggle("Show in Dock", isOn: $vm.showInDock)
                .onChange(of: vm.showInDock) { vm.save(); vm.applyDockPolicy() }
            Toggle("Show Notifications", isOn: $vm.showNotifications)
                .onChange(of: vm.showNotifications) { vm.save() }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

@available(macOS 26.4, *)
private struct OutputTab: View {
    @ObservedObject var vm: SettingsViewModel
    var body: some View {
        Form {
            Toggle("Auto-paste Transcript on Stop", isOn: $vm.autoPaste)
                .onChange(of: vm.autoPaste) { vm.save() }
            Text("Transcript is always copied to clipboard. Enable auto-paste to automatically paste it.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

@available(macOS 26.4, *)
private struct AudioTab: View {
    @ObservedObject var vm: SettingsViewModel
    let modes = ["Mic Only", "Mic + App Audio"]
    var body: some View {
        Form {
            Picker("Default Mode", selection: $vm.defaultModeIndex) {
                ForEach(0..<modes.count, id: \.self) { Text(modes[$0]) }
            }
            .onChange(of: vm.defaultModeIndex) { vm.save() }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

@available(macOS 26.4, *)
private struct ShortcutsTab: View {
    @ObservedObject var vm: SettingsViewModel
    var body: some View {
        Form {
            Section("Keyboard Shortcuts") {
                ShortcutRow(label: "Start Mic-Only", shortcut: vm.startMicOnlyShortcut) { s in
                    vm.startMicOnlyShortcut = s
                    vm.saveShortcut(s, forKey: "startMicOnlyShortcut")
                }
                ShortcutRow(label: "Start Mic + App", shortcut: vm.startMicPlusAppShortcut) { s in
                    vm.startMicPlusAppShortcut = s
                    vm.saveShortcut(s, forKey: "startMicPlusAppShortcut")
                }
            }
            Text("Click a field and press the desired key combination.\nShortcuts are global and work in the background.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

/// Wraps the AppKit `ShortcutRecorderView` for SwiftUI.
@available(macOS 26.4, *)
private struct ShortcutRow: View {
    let label: String
    let shortcut: KeyboardShortcut?
    let onChange: @MainActor @Sendable (KeyboardShortcut?) -> Void

    var body: some View {
        LabeledContent(label) {
            ShortcutRecorderRepresentable(shortcut: shortcut, onChange: onChange)
                .frame(width: 200, height: 24)
        }
    }
}

@available(macOS 26.4, *)
private struct ShortcutRecorderRepresentable: NSViewRepresentable {
    var shortcut: KeyboardShortcut?
    var onChange: @MainActor @Sendable (KeyboardShortcut?) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderView {
        let v = ShortcutRecorderView()
        v.shortcut = shortcut
        v.onShortcutChanged = onChange
        return v
    }

    func updateNSView(_ nsView: ShortcutRecorderView, context: Context) {
        nsView.shortcut = shortcut
    }
}

@available(macOS 26.4, *)
private struct AdvancedTab: View {
    @ObservedObject var vm: SettingsViewModel

    let providers = ASRProvider.allCases.map(\.displayName)
    let models = [
        "tiny (75 MB, fastest)",
        "base (140 MB, very fast)",
        "small (460 MB, balanced)",
        "medium (1.4 GB, accurate)",
        "large-v3-turbo (2.8 GB, best)"
    ]
    let languages = [
        "Auto-detect", "English", "Spanish", "French", "German",
        "Italian", "Portuguese", "Dutch", "Japanese", "Chinese"
    ]

    var isParakeet: Bool { ASRProvider.allCases[vm.providerIndex] == .parakeet }

    var body: some View {
        Form {
            Picker("Provider", selection: $vm.providerIndex) {
                ForEach(0..<providers.count, id: \.self) { Text(providers[$0]) }
            }
            .onChange(of: vm.providerIndex) { vm.setProvider(vm.providerIndex) }

            if isParakeet {
                Text("Parakeet TDT 0.6B (Core ML)")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Model", selection: $vm.modelIndex) {
                    ForEach(0..<models.count, id: \.self) { Text(models[$0]) }
                }
                .onChange(of: vm.modelIndex) { vm.save() }
            }

            Picker("Language", selection: $vm.languageIndex) {
                ForEach(0..<languages.count, id: \.self) { Text(languages[$0]) }
            }
            .onChange(of: vm.languageIndex) { vm.save() }

            Section("Status") {
                engineStatusRow
                if vm.downloadVisible {
                    ProgressView(value: vm.downloadProgress)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private var engineStatusRow: some View {
        switch vm.engineState {
        case .idle:
            Label("Idle", systemImage: "circle")
                .foregroundStyle(.secondary)
        case .downloading:
            HStack {
                ProgressView().controlSize(.small)
                Text("Downloading model…")
            }
        case .loading:
            HStack {
                ProgressView().controlSize(.small)
                Text("Loading engine…")
            }
        case .ready:
            Label("Ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let msg):
            Label(msg, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }
}

@available(macOS 26.4, *)
private struct PermissionsTab: View {
    @ObservedObject var vm: SettingsViewModel

    var body: some View {
        Form {
            Section("Required Permissions") {
                permissionRow("Microphone", status: vm.micStatus)
                permissionRow("Screen Recording", status: vm.screenStatus)
                permissionRow("Accessibility", status: vm.accessibilityStatus)
            }

            Section {
                Button("Refresh") { vm.refreshPermissions() }
                Button("Open Accessibility Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }

            Text("• Microphone: Capture your voice\n• Screen Recording: Capture app audio\n• Accessibility: Auto-paste transcripts")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func permissionRow(_ name: String, status: SettingsViewModel.PermissionState) -> some View {
        LabeledContent(name) {
            Text(status.rawValue)
                .foregroundStyle(colorForStatus(status))
        }
    }

    private func colorForStatus(_ s: SettingsViewModel.PermissionState) -> Color {
        switch s {
        case .granted: .green
        case .denied: .red
        case .notGranted, .notAsked: .orange
        case .checking: .secondary
        }
    }
}

// MARK: - Window Controller (thin shell)

@MainActor
final class SettingsWindowController: NSWindowController, @unchecked Sendable {

    private nonisolated(unsafe) var notificationTokens: [NSObjectProtocol] = []

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "MacTalk Settings"
        window.titlebarAppearsTransparent = true
        window.center()

        super.init(window: window)

        if #available(macOS 26.4, *) {
            let host = NSHostingView(rootView: SettingsContentView())
            host.frame = window.contentView!.bounds
            host.autoresizingMask = [.width, .height]
            window.contentView?.addSubview(host)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        for token in notificationTokens { NotificationCenter.default.removeObserver(token) }
    }
}
