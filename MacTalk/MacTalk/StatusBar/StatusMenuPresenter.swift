import AppKit

/// Builds and renders the status menu. It deliberately has no access to
/// settings, permissions, capture, engines, or output side effects.
@MainActor
final class StatusMenuPresenter: StatusMenuPresenting {
    enum ItemID {
        static let micOnly = "record.micOnly"
        static let micPlusApp = "record.micPlusApp"
        static let stop = "record.stop"
        static let autoPaste = "output.autoPaste"
        static let model = "engine.model"
        static let parakeet = "engine.parakeet"
        static let progress = "engine.downloadProgress"
        static let performanceReport = "application.performanceReport"
        static let settings = "application.settings"
        static let permissions = "application.permissions"
        static let about = "application.about"
        static let quit = "application.quit"
    }

    let menu: NSMenu
    private let catalog: [ModelSpec]
    private weak var target: AnyObject?
    private let micOnlyItem: NSMenuItem
    private let micPlusAppItem: NSMenuItem
    private let stopItem: NSMenuItem
    private let autoPasteItem: NSMenuItem
    private let parakeetItem: NSMenuItem
    private let whisperItems: [NSMenuItem]
    private let progressItem: NSMenuItem

    init(target: AnyObject, catalog: [ModelSpec] = ModelCatalog.bundled()) {
        self.target = target
        self.catalog = catalog
        self.menu = NSMenu()

        micOnlyItem = Self.item(id: ItemID.micOnly, title: "Start (Mic Only)", action: #selector(StatusBarController.startMicOnly), target: target)
        micPlusAppItem = Self.item(id: ItemID.micPlusApp, title: "Start (Mic + App Audio)", action: #selector(StatusBarController.startMicPlusApp), target: target)
        stopItem = Self.item(id: ItemID.stop, title: "Stop Recording", action: #selector(StatusBarController.stopRecording), target: target)
        autoPasteItem = Self.item(id: ItemID.autoPaste, title: "Auto-paste on Stop", action: #selector(StatusBarController.toggleAutoPaste), target: target, keyEquivalent: "p")
        parakeetItem = Self.item(id: ItemID.parakeet, title: "Parakeet (Core ML)", action: #selector(StatusBarController.selectParakeet), target: target)
        whisperItems = catalog.map { spec in
            let item = Self.item(id: "engine.whisper.\(spec.id)", title: spec.displayName, action: #selector(StatusBarController.selectModelSpec), target: target)
            item.representedObject = spec
            return item
        }
        progressItem = Self.item(id: ItemID.progress, title: "", action: nil, target: nil)
        progressItem.isHidden = true

        let modelMenu = NSMenu()
        modelMenu.addItem(parakeetItem)
        modelMenu.addItem(.separator())
        whisperItems.forEach(modelMenu.addItem)
        let modelItem = Self.item(id: ItemID.model, title: "Model", action: nil, target: nil)
        modelItem.submenu = modelMenu

        menu.addItem(micOnlyItem)
        menu.addItem(micPlusAppItem)
        menu.addItem(stopItem)
        menu.addItem(.separator())
        menu.addItem(autoPasteItem)
        menu.addItem(.separator())
        menu.addItem(modelItem)
        menu.addItem(progressItem)
        menu.addItem(.separator())
        menu.addItem(Self.item(id: ItemID.performanceReport, title: "Copy Performance Report", action: #selector(StatusBarController.copyPerformanceReport), target: target))
        menu.addItem(Self.item(id: ItemID.settings, title: "Settings...", action: #selector(StatusBarController.showSettings), target: target, keyEquivalent: ","))
        menu.addItem(Self.item(id: ItemID.permissions, title: "Check Permissions", action: #selector(StatusBarController.checkPermissions), target: target))
        menu.addItem(.separator())
        menu.addItem(Self.item(id: ItemID.about, title: "About MacTalk", action: #selector(StatusBarController.showAbout), target: target))
        menu.addItem(Self.item(id: ItemID.quit, title: "Quit MacTalk", action: #selector(StatusBarController.quit), target: target, keyEquivalent: "q"))
    }

    func render(_ state: StatusBarViewState) {
        micOnlyItem.isEnabled = state.startEnabled
        micPlusAppItem.isEnabled = state.startEnabled
        stopItem.isEnabled = state.stopEnabled
        autoPasteItem.state = state.effectiveAutoPaste ? .on : .off
        parakeetItem.state = state.provider == .parakeet ? .on : .off
        whisperItems.forEach { item in
            let selected = (item.representedObject as? ModelSpec)?.id == state.whisperModelID
            item.state = state.provider == .whisper && selected ? .on : .off
        }
        renderDownload(state.download)
        renderShortcut(micOnlyItem, shortcut: state.shortcuts.micOnly)
        renderShortcut(micPlusAppItem, shortcut: state.shortcuts.micPlusAppAudio)
    }

    private func renderDownload(_ download: ModelDownloadViewState) {
        let parakeet = if case .parakeet = download.requirement { true } else { false }
        switch download.phase {
        case let .downloading(fraction, index, count):
            if parakeet, let index, let count {
                progressItem.title = String(format: "Downloading Parakeet… %.0f%% (%d/%d)", fraction * 100, index, count)
            } else {
                progressItem.title = String(format: "Downloading model… %.0f%%", fraction * 100)
            }
            progressItem.isHidden = false
        case .verifying:
            progressItem.title = parakeet ? "Verifying Parakeet…" : "Verifying model…"
            progressItem.isHidden = false
        case .ready:
            progressItem.title = parakeet ? "Parakeet ready ✓" : "Model ready ✓"
            progressItem.isHidden = false
        case let .failed(message):
            progressItem.title = parakeet ? "Parakeet download failed: \(message)" : "Download failed: \(message)"
            progressItem.isHidden = false
        case .idle:
            progressItem.isHidden = true
        }
    }

    private func renderShortcut(_ item: NSMenuItem, shortcut: KeyboardShortcut?) {
        let baseTitle = item.title.components(separatedBy: "\t").first ?? item.title
        guard let shortcut else {
            item.title = baseTitle
            item.attributedTitle = nil
            return
        }
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.tabStops = [NSTextTab(textAlignment: .right, location: 260)]
        let title = NSMutableAttributedString(string: "\(baseTitle)\t\(shortcut.displayString)")
        title.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: title.length))
        title.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: NSRange(location: baseTitle.count + 1, length: shortcut.displayString.count))
        item.attributedTitle = title
    }

    private static func item(id: String, title: String, action: Selector?, target: AnyObject?, keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.identifier = NSUserInterfaceItemIdentifier(id)
        item.target = target
        return item
    }
}

@MainActor
protocol StatusMenuPresenting: AnyObject {
    var menu: NSMenu { get }
    func render(_ state: StatusBarViewState)
}
