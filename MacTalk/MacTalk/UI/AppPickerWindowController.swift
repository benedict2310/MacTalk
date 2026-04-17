//
//  AppPickerWindowController.swift
//  MacTalk
//
//  Application audio source picker — Liquid Glass on macOS 26.4+
//

import AppKit
import ScreenCaptureKit
import SwiftUI

// MARK: - Window Controller

@MainActor
final class AppPickerWindowController: NSWindowController {

    // MARK: - Types

    /// Audio source for capture (app or system audio).
    /// Marked @unchecked Sendable because SCK types are immutable snapshots
    /// and this type is only used within MainActor context.
    struct AudioSource: @unchecked Sendable {
        let app: SCRunningApplication?
        let display: SCDisplay?
        let name: String
        let icon: NSImage?

        var isSystemAudio: Bool { display != nil }

        static func fromApp(_ app: SCRunningApplication) -> AudioSource {
            let icon: NSImage?
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleIdentifier) {
                icon = NSWorkspace.shared.icon(forFile: appURL.path)
            } else {
                icon = NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil)
            }
            return AudioSource(app: app, display: nil, name: app.applicationName, icon: icon)
        }

        static func systemAudio(display: SCDisplay) -> AudioSource {
            AudioSource(
                app: nil, display: display, name: "System Audio",
                icon: NSImage(systemSymbolName: "speaker.wave.3", accessibilityDescription: "System Audio")
            )
        }
    }

    // MARK: - Properties

    private let allSources: [AudioSource]
    var onSelection: ((AudioSource) -> Void)?

    // MARK: - Initialization

    init(sources: [AudioSource]) {
        self.allSources = sources

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 380),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Select Audio Source"
        window.titlebarAppearsTransparent = true
        window.center()

        super.init(window: window)

        if #available(macOS 26.4, *) {
            let state = PickerState(sources: allSources)
            let host = NSHostingView(
                rootView: PickerContentView(
                    state: state,
                    onSelect: { [weak self] source in
                        self?.onSelection?(source)
                        self?.close()
                    },
                    onCancel: { [weak self] in
                        self?.close()
                    }
                )
            )
            host.frame = window.contentView!.bounds
            host.autoresizingMask = [.width, .height]
            window.contentView?.addSubview(host)
        } else {
            let state = PickerState(sources: allSources)
            let host = NSHostingView(
                rootView: LegacyPickerContentView(
                    state: state,
                    onSelect: { [weak self] source in
                        self?.onSelection?(source)
                        self?.close()
                    },
                    onCancel: { [weak self] in
                        self?.close()
                    }
                )
            )
            host.frame = window.contentView!.bounds
            host.autoresizingMask = [.width, .height]
            window.contentView?.addSubview(host)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

// MARK: - SwiftUI (macOS 26.4+)

@MainActor
private final class PickerState: ObservableObject {
    @Published var searchText: String = ""
    @Published var selectionID: String?

    struct Entry: Identifiable {
        let id: String   // bundleId or "system"
        let source: AppPickerWindowController.AudioSource
        var name: String { source.name }
        var icon: NSImage { source.icon ?? NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil)! }
    }

    let entries: [Entry]

    init(sources: [AppPickerWindowController.AudioSource]) {
        self.entries = sources.enumerated().map { idx, s in
            Entry(id: s.app?.bundleIdentifier ?? "system-\(idx)", source: s)
        }
    }

    var filtered: [Entry] {
        if searchText.isEmpty { return entries }
        return entries.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var selectedSource: AppPickerWindowController.AudioSource? {
        guard let id = selectionID else { return nil }
        return entries.first(where: { $0.id == id })?.source
    }
}

@available(macOS 26.4, *)
private struct PickerContentView: View {
    @ObservedObject var state: PickerState
    var onSelect: (AppPickerWindowController.AudioSource) -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter apps…", text: $state.searchText)
                    .textFieldStyle(.plain)
            }
            .padding(10)
            .glassEffect()
            .padding(.horizontal, 12)
            .padding(.top, 8)

            // Source list
            List(state.filtered, selection: $state.selectionID) { entry in
                HStack(spacing: 10) {
                    Image(nsImage: entry.icon)
                        .resizable()
                        .frame(width: 28, height: 28)
                    Text(entry.name)
                        .lineLimit(1)
                }
                .tag(entry.id)
                .padding(.vertical, 2)
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)

            // Action buttons
            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Select") {
                    if let src = state.selectedSource { onSelect(src) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(state.selectedSource == nil)
                .buttonStyle(.glass)
            }
            .padding(12)
        }
        .frame(minWidth: 420, minHeight: 340)
    }
}

private struct LegacyPickerContentView: View {
    @ObservedObject var state: PickerState
    var onSelect: (AppPickerWindowController.AudioSource) -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Filter apps…", text: $state.searchText)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)

            List(state.filtered, selection: $state.selectionID) { entry in
                HStack(spacing: 10) {
                    Image(nsImage: entry.icon)
                        .resizable()
                        .frame(width: 28, height: 28)
                    Text(entry.name)
                        .lineLimit(1)
                }
                .tag(entry.id)
                .padding(.vertical, 2)
            }
            .padding(.horizontal, 12)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Select") {
                    if let src = state.selectedSource { onSelect(src) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(state.selectedSource == nil)
            }
            .padding([.horizontal, .bottom], 12)
        }
        .frame(minWidth: 420, minHeight: 340)
    }
}
