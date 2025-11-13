//
//  HUDWindowController.swift
//  MacTalk
//
//  Floating HUD overlay - Liquid glass bubble with audio-reactive waves
//

import AppKit
import QuartzCore

final class HUDWindowController: NSWindowController {
    private let waveView = AudioWaveView()
    private let backgroundView = NSVisualEffectView()
    private let glassEdgeLayer = CAGradientLayer()
    private let stopButton = NSButton()

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

        // Constraints - center stop button at bottom
        NSLayoutConstraint.activate([
            stopButton.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            stopButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
            stopButton.widthAnchor.constraint(equalToConstant: 32),
            stopButton.heightAnchor.constraint(equalToConstant: 32)
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
        // In bubble UI, we don't show text during recording
        // Text could be shown in a tooltip or separate UI element if needed
        // For now, we just ensure the window is visible
        window?.animator().alphaValue = 1.0
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

    /// Reset HUD to initial state (clear waves)
    func reset() {
        resetLevels()
    }

    override func close() {
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
        }, completionHandler: {
            window.orderOut(nil)
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
