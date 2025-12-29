//
//  HUDWindowController.swift
//  MacTalk
//
//  Floating HUD overlay - Liquid glass bubble with audio-reactive waves
//

import AppKit
import QuartzCore

@MainActor
final class HUDWindowController: NSWindowController {
    private let waveView = AudioWaveView()
    private let backgroundView = NSVisualEffectView()
    private let glassEdgeLayer = CAGradientLayer()
    private let stopButton = NSButton()
    private let transcriptLabel = NSTextField(labelWithString: "")

    /// Tracks whether we've received any partial text this session
    private var hasReceivedPartial = false
    /// The last displayed text (for throttling identical updates)
    private var lastDisplayedText: String = ""
    /// Timer to clear final text after display
    private var clearTimer: Timer?

    var onStop: (() -> Void)?

    convenience init() {
        // Create a circular borderless window
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]

        self.init(window: window)

        setupUI()
        setupAccessibility()
        centerWindow()
    }

    private func setupUI() {
        guard let window = window, let contentView = window.contentView else { return }

        // Ensure content view has layer with centered anchor point for scale animations
        contentView.wantsLayer = true

        // Set anchor point to center for proper scaling
        // Note: Changing anchor point affects position, so we need to adjust
        if let layer = contentView.layer {
            let oldAnchor = layer.anchorPoint
            let newAnchor = CGPoint(x: 0.5, y: 0.5)

            // Calculate position adjustment to keep layer in same visual location
            let oldPosition = layer.position
            let deltaX = (newAnchor.x - oldAnchor.x) * layer.bounds.width
            let deltaY = (newAnchor.y - oldAnchor.y) * layer.bounds.height

            layer.anchorPoint = newAnchor
            layer.position = CGPoint(x: oldPosition.x + deltaX, y: oldPosition.y + deltaY)
        }

        // Glass effect background (circular)
        backgroundView.material = .hudWindow  // Dark glass effect
        backgroundView.state = .active
        backgroundView.blendingMode = .behindWindow
        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerRadius = 100  // Circular (half of 200x200)
        backgroundView.layer?.masksToBounds = true  // Clip to circle
        backgroundView.alphaValue = 0.85  // Add transparency for liquid glass effect
        backgroundView.frame = contentView.bounds
        backgroundView.autoresizingMask = [.width, .height]
        contentView.addSubview(backgroundView)

        // Add glass edge effects using radial gradient (realistic glass aberration)
        glassEdgeLayer.type = .radial
        glassEdgeLayer.frame = contentView.bounds

        // Create radial gradient from center to edge
        // This creates the frosted glass edge effect
        let clearColor = NSColor.white.withAlphaComponent(0.0).cgColor
        let edgeGlowColor = NSColor.white.withAlphaComponent(0.4).cgColor
        let outerGlowColor = NSColor.white.withAlphaComponent(0.2).cgColor

        glassEdgeLayer.colors = [clearColor, clearColor, edgeGlowColor, outerGlowColor]
        glassEdgeLayer.locations = [0.0, 0.75, 0.92, 1.0]  // Glow concentrated at edges

        // Center the gradient
        glassEdgeLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        glassEdgeLayer.endPoint = CGPoint(x: 1.0, y: 1.0)  // Radius to corner

        // Mask to circle shape
        let maskLayer = CAShapeLayer()
        maskLayer.path = NSBezierPath(ovalIn: contentView.bounds).cgPath
        glassEdgeLayer.mask = maskLayer

        contentView.layer?.addSublayer(glassEdgeLayer)

        // Wave visualization on top
        waveView.frame = contentView.bounds
        waveView.autoresizingMask = [.width, .height]
        contentView.addSubview(waveView)

        // Stop button (small, centered at bottom)
        stopButton.title = ""
        stopButton.bezelStyle = .circular
        stopButton.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Stop Recording")
        stopButton.target = self
        stopButton.action = #selector(stopButtonClicked)
        stopButton.translatesAutoresizingMaskIntoConstraints = false
        stopButton.setAccessibilityLabel("Stop Recording")
        stopButton.setAccessibilityHelp("Click to stop the current recording")
        stopButton.isBordered = false
        stopButton.contentTintColor = .white.withAlphaComponent(0.8)

        contentView.addSubview(stopButton)

        // Live transcript label (positioned above stop button)
        transcriptLabel.translatesAutoresizingMaskIntoConstraints = false
        transcriptLabel.alignment = .center
        transcriptLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        transcriptLabel.textColor = .white
        transcriptLabel.backgroundColor = .clear
        transcriptLabel.isBezeled = false
        transcriptLabel.isEditable = false
        transcriptLabel.isSelectable = false
        transcriptLabel.lineBreakMode = .byTruncatingTail
        transcriptLabel.maximumNumberOfLines = 2
        transcriptLabel.cell?.truncatesLastVisibleLine = true
        transcriptLabel.alphaValue = 0.7  // Default partial opacity
        transcriptLabel.setAccessibilityLabel("Live Transcription")
        transcriptLabel.setAccessibilityRole(.staticText)
        contentView.addSubview(transcriptLabel)

        // Constraints - center stop button at bottom
        NSLayoutConstraint.activate([
            stopButton.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            stopButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
            stopButton.widthAnchor.constraint(equalToConstant: 32),
            stopButton.heightAnchor.constraint(equalToConstant: 32),

            // Transcript label - centered horizontally, above stop button
            transcriptLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            transcriptLabel.bottomAnchor.constraint(equalTo: stopButton.topAnchor, constant: -8),
            transcriptLabel.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 16),
            transcriptLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -16),
            transcriptLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 168)  // Max width within bubble
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

    // MARK: - Live Transcript Updates

    /// Updates HUD with partial (in-progress) transcription text.
    /// Shows at 70% opacity to indicate text may change.
    func updatePartial(text: String) {
        // Skip if text hasn't changed (throttle identical updates)
        guard text != lastDisplayedText else { return }
        lastDisplayedText = text

        // Cancel any pending clear timer
        clearTimer?.invalidate()
        clearTimer = nil

        hasReceivedPartial = true

        // Truncate to last ~50 characters for display
        let displayText = truncateForDisplay(text)

        transcriptLabel.stringValue = displayText
        transcriptLabel.alphaValue = 0.7  // Partial opacity
    }

    /// Updates HUD with final (committed) transcription text.
    /// Shows at 100% opacity, then clears after a short delay.
    func updateFinal(text: String) {
        // Cancel any pending clear timer
        clearTimer?.invalidate()
        clearTimer = nil

        lastDisplayedText = text

        // Truncate to last ~50 characters for display
        let displayText = truncateForDisplay(text)

        transcriptLabel.stringValue = displayText
        transcriptLabel.alphaValue = 1.0  // Full opacity for final

        // Clear after 2 seconds
        clearTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.transcriptLabel.stringValue = ""
                self?.lastDisplayedText = ""
            }
        }
    }

    /// Truncates text to show the most recent portion for display.
    private func truncateForDisplay(_ text: String) -> String {
        let maxLength = 60
        if text.count <= maxLength {
            return text
        }
        // Show last portion with ellipsis prefix
        let startIndex = text.index(text.endIndex, offsetBy: -maxLength)
        return "…" + String(text[startIndex...])
    }

    @available(*, deprecated, message: "Use updatePartial(text:) or updateFinal(text:) instead")
    func update(text: String) {
        // Legacy method - route to updatePartial for compatibility
        updatePartial(text: text)
    }

    func updateMicLevel(rms: Float, peak: Float, peakHold: Float) {
        // Use RMS level for wave visualization (most representative of audio energy)
        waveView.updateAudioLevel(rms)
    }

    func updateAppLevel(rms: Float, peak: Float, peakHold: Float) {
        // For combined mic+app mode, we could blend both levels
        // For now, mic level drives the wave (main audio source)
        // App audio could be visualized differently in future iterations
    }

    func setAppMeterVisible(_ visible: Bool) {
        // In bubble UI, we don't have separate meters
        // This is a no-op for API compatibility
    }

    func resetLevels() {
        waveView.reset()
    }

    @objc private func stopButtonClicked() {
        onStop?()
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        animateIn()
        reset()
    }

    /// Reset HUD to initial state (clear waves and transcript)
    func reset() {
        resetLevels()
        resetTranscript()
    }

    /// Reset transcript state to initial "Listening..." state
    private func resetTranscript() {
        clearTimer?.invalidate()
        clearTimer = nil
        hasReceivedPartial = false
        lastDisplayedText = ""
        transcriptLabel.stringValue = "Listening…"
        transcriptLabel.alphaValue = 0.5  // Dim for placeholder state
    }

    override func close() {
        // Clean up timer
        clearTimer?.invalidate()
        clearTimer = nil

        guard let window = window, window.isVisible else {
            super.close()
            return
        }

        animateOut {
            super.close()
        }
    }

    // MARK: - Animations

    private func animateIn() {
        guard let window = window else { return }

        // Start invisible
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)

        // Spring animation for scale (expand from center)
        let springAnimation = CASpringAnimation(keyPath: "transform.scale")
        springAnimation.fromValue = 0.0
        springAnimation.toValue = 1.0
        springAnimation.damping = 15  // Subtle bounce
        springAnimation.stiffness = 300  // Responsive
        springAnimation.duration = springAnimation.settlingDuration

        window.contentView?.layer?.add(springAnimation, forKey: "scaleIn")

        // Fade in
        window.animator().alphaValue = 1.0
    }

    private func animateOut(completion: @escaping () -> Void) {
        guard let window = window else {
            completion()
            return
        }

        // Scale animation (contract to center)
        let scaleAnimation = CABasicAnimation(keyPath: "transform.scale")
        scaleAnimation.fromValue = 1.0
        scaleAnimation.toValue = 0.0
        scaleAnimation.duration = 0.25
        scaleAnimation.timingFunction = CAMediaTimingFunction(name: .easeIn)

        CATransaction.begin()
        CATransaction.setCompletionBlock {
            completion()
        }

        window.contentView?.layer?.add(scaleAnimation, forKey: "scaleOut")

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            window.animator().alphaValue = 0
        }, completionHandler: { [weak window] in
            MainActor.assumeIsolated {
                window?.orderOut(nil)
            }
        })

        CATransaction.commit()
    }

    // MARK: - Accessibility

    private func setupAccessibility() {
        guard let window = window else { return }

        // Window accessibility
        window.setAccessibilityLabel("MacTalk Recording Bubble")
        window.setAccessibilityRole(.window)
        window.setAccessibilityHelp("Audio-reactive bubble showing live recording with wave visualization")

        // Wave view accessibility
        waveView.setAccessibilityLabel("Audio Wave Visualization")
        waveView.setAccessibilityRole(.levelIndicator)
        waveView.setAccessibilityHelp("Visual representation of audio input levels as animated waves")

        // Stop button already has accessibility labels set in setupUI()

        // Enable keyboard navigation
        window.initialFirstResponder = stopButton
    }
}
