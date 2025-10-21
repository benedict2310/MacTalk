//
//  HUDWindowController.swift
//  MacTalk
//
//  Floating HUD overlay for live transcript display
//

import AppKit

final class HUDWindowController: NSWindowController {
    private let textView = NSTextField(labelWithString: "…")
    private let backgroundView = NSVisualEffectView()

    convenience init() {
        // Create a borderless, floating panel
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 100),
            styleMask: [.nonactivatingPanel, .titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.styleMask.insert(.fullSizeContentView)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        self.init(window: panel)

        setupUI()
        centerWindow()
    }

    private func setupUI() {
        guard let window = window, let contentView = window.contentView else { return }

        // Background with blur effect
        backgroundView.material = .hudWindow
        backgroundView.state = .active
        backgroundView.blendingMode = .behindWindow
        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerRadius = 10
        backgroundView.frame = contentView.bounds
        backgroundView.autoresizingMask = [.width, .height]
        contentView.addSubview(backgroundView)

        // Text display
        textView.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.textColor = .labelColor
        textView.backgroundColor = .clear
        textView.isBezeled = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.lineBreakMode = .byWordWrapping
        textView.maximumNumberOfLines = 3
        textView.translatesAutoresizingMaskIntoConstraints = false

        backgroundView.addSubview(textView)

        // Constraints
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor, constant: 16),
            textView.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor, constant: -16),
            textView.topAnchor.constraint(equalTo: backgroundView.topAnchor, constant: 16),
            textView.bottomAnchor.constraint(equalTo: backgroundView.bottomAnchor, constant: -16)
        ])
    }

    private func centerWindow() {
        guard let window = window, let screen = NSScreen.main else { return }

        let screenFrame = screen.visibleFrame
        let windowFrame = window.frame

        let x = screenFrame.maxX - windowFrame.width - 20
        let y = screenFrame.maxY - windowFrame.height - 20

        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func update(text: String) {
        textView.stringValue = text

        // Animate appearance
        window?.animator().alphaValue = 1.0
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(nil)
        window?.alphaValue = 0.0
        window?.animator().alphaValue = 1.0
    }

    override func close() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            window?.animator().alphaValue = 0.0
        }, completionHandler: {
            super.close()
        })
    }
}
