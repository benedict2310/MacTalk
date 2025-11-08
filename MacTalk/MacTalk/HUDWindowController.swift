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
    private let levelMeterView = DualChannelLevelMeterView()
    private let containerStack = NSStackView()
    private let stopButton = NSButton()

    var onStop: (() -> Void)?

    convenience init() {
        // Create a borderless, floating panel
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 180),
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
        setupAccessibility()
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

        // Stop button
        stopButton.title = "Stop Recording"
        stopButton.bezelStyle = .rounded
        stopButton.target = self
        stopButton.action = #selector(stopButtonClicked)
        stopButton.translatesAutoresizingMaskIntoConstraints = false
        stopButton.setAccessibilityLabel("Stop Recording")
        stopButton.setAccessibilityHelp("Click to stop the current recording")

        // Setup container stack
        containerStack.orientation = .vertical
        containerStack.spacing = 12
        containerStack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        containerStack.translatesAutoresizingMaskIntoConstraints = false

        containerStack.addArrangedSubview(levelMeterView)
        containerStack.addArrangedSubview(textView)
        containerStack.addArrangedSubview(stopButton)

        backgroundView.addSubview(containerStack)

        // Constraints
        NSLayoutConstraint.activate([
            containerStack.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor),
            containerStack.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor),
            containerStack.topAnchor.constraint(equalTo: backgroundView.topAnchor),
            containerStack.bottomAnchor.constraint(equalTo: backgroundView.bottomAnchor),

            levelMeterView.heightAnchor.constraint(equalToConstant: 50)
        ])
    }

    private func centerWindow() {
        guard let window = window, let screen = NSScreen.main else { return }

        let screenFrame = screen.visibleFrame
        let windowFrame = window.frame

        let xPosition = screenFrame.maxX - windowFrame.width - 20
        let yPosition = screenFrame.maxY - windowFrame.height - 20

        window.setFrameOrigin(NSPoint(x: xPosition, y: yPosition))
    }

    func update(text: String) {
        textView.stringValue = text

        // Animate appearance
        window?.animator().alphaValue = 1.0
    }

    func updateMicLevel(rms: Float, peak: Float, peakHold: Float) {
        levelMeterView.updateMic(rms: rms, peak: peak, peakHold: peakHold)
    }

    func updateAppLevel(rms: Float, peak: Float, peakHold: Float) {
        levelMeterView.updateApp(rms: rms, peak: peak, peakHold: peakHold)
    }

    func setAppMeterVisible(_ visible: Bool) {
        levelMeterView.setAppMeterVisible(visible)
    }

    func resetLevels() {
        levelMeterView.reset()
    }

    @objc private func stopButtonClicked() {
        onStop?()
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(nil)
        window?.alphaValue = 0.0
        window?.animator().alphaValue = 1.0
        resetLevels()
    }

    override func close() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            window?.animator().alphaValue = 0.0
        }, completionHandler: {
            super.close()
        })
    }

    // MARK: - Accessibility

    private func setupAccessibility() {
        guard let window = window else { return }

        // Window accessibility
        window.setAccessibilityLabel("MacTalk HUD")
        window.setAccessibilityRole(.window)
        window.setAccessibilityHelp("Live transcription overlay showing partial transcripts and audio levels")

        // Text view accessibility
        textView.setAccessibilityLabel("Live Transcript")
        textView.setAccessibilityRole(.staticText)
        textView.setAccessibilityHelp("Shows the current transcription in real-time")

        // Level meter accessibility
        levelMeterView.setAccessibilityLabel("Audio Level Meters")
        levelMeterView.setAccessibilityRole(.levelIndicator)
        levelMeterView.setAccessibilityHelp("Displays microphone and application audio levels")

        // Enable keyboard navigation
        window.initialFirstResponder = textView
    }
}
