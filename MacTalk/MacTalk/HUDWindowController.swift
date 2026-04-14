//
//  HUDWindowController.swift
//  MacTalk
//
//  Floating HUD overlay — compact Liquid Glass pill with audio-reactive visualization
//

import AppKit
import SwiftUI

// MARK: - SwiftUI HUD View

/// Observable state object shared between the window controller and the SwiftUI view.
@MainActor
final class HUDState: ObservableObject {
    @Published var transcriptText: String = "Listening…"
    @Published var transcriptOpacity: Double = 0.5
    @Published var audioLevel: Float = 0.0
    @Published var smoothedLevel: Float = 0.0

    private let smoothingFactor: Float = 0.12

    func feedLevel(_ level: Float) {
        smoothedLevel = smoothedLevel * (1.0 - smoothingFactor) + level * smoothingFactor
        audioLevel = smoothedLevel
    }

    func reset() {
        smoothedLevel = 0.0
        audioLevel = 0.0
        transcriptText = "Listening…"
        transcriptOpacity = 0.5
    }
}

/// A compact audio-level bar rendered with Core Animation for buttery updates.
struct AudioLevelBar: View {
    var level: Float

    var body: some View {
        GeometryReader { geo in
            Capsule()
                .fill(.white.opacity(0.35))
                .frame(width: geo.size.width, height: geo.size.height)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.85))
                        .frame(width: max(2, geo.size.width * CGFloat(level)))
                        .animation(.linear(duration: 0.06), value: level)
                }
        }
    }
}

/// The Liquid Glass HUD — a floating pill that sits in the top-right corner.
@available(macOS 26.4, *)
struct HUDContentView: View {
    @ObservedObject var state: HUDState
    var onStop: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Audio level indicator
            AudioLevelBar(level: state.audioLevel)
                .frame(width: 48, height: 6)

            // Transcript
            Text(state.transcriptText)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.head)
                .opacity(state.transcriptOpacity)
                .frame(maxWidth: 200, alignment: .leading)

            // Stop button
            Button {
                onStop()
            } label: {
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: 18))
            }
            .buttonStyle(.glass)
            .accessibilityLabel("Stop Recording")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect()
    }
}

// MARK: - Window Controller

@MainActor
final class HUDWindowController: NSWindowController {
    private let hudState = HUDState()

    /// Tracks whether we've received any partial text this session
    private var hasReceivedPartial = false
    /// The last displayed text (for throttling identical updates)
    private var lastDisplayedText: String = ""
    /// Timer to clear final text after display
    private var clearTimer: Timer?

    var onStop: (() -> Void)?

    convenience init() {
        // Compact pill-shaped borderless window
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 48),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]

        self.init(window: window)

        if #available(macOS 26.4, *) {
            let hostView = NSHostingView(
                rootView: HUDContentView(state: hudState) { [weak self] in
                    self?.onStop?()
                }
            )
            hostView.frame = window.contentView!.bounds
            hostView.autoresizingMask = [.width, .height]
            window.contentView?.addSubview(hostView)
        }

        setupAccessibility()
        positionWindow()
    }

    private func positionWindow() {
        guard let window = window, let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let windowFrame = window.frame
        let x = screenFrame.maxX - windowFrame.width - 16
        let y = screenFrame.maxY - windowFrame.height - 12
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - Live Transcript Updates

    func updatePartial(text: String) {
        guard text != lastDisplayedText else { return }
        lastDisplayedText = text
        clearTimer?.invalidate()
        clearTimer = nil
        hasReceivedPartial = true

        hudState.transcriptText = truncateForDisplay(text)
        hudState.transcriptOpacity = 0.7
    }

    func updateFinal(text: String) {
        clearTimer?.invalidate()
        clearTimer = nil
        lastDisplayedText = text

        hudState.transcriptText = truncateForDisplay(text)
        hudState.transcriptOpacity = 1.0

        clearTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hudState.transcriptText = ""
                self?.lastDisplayedText = ""
            }
        }
    }

    private func truncateForDisplay(_ text: String) -> String {
        let maxLength = 50
        guard text.count > maxLength else { return text }
        let start = text.index(text.endIndex, offsetBy: -maxLength)
        return "…" + String(text[start...])
    }

    @available(*, deprecated, message: "Use updatePartial(text:) or updateFinal(text:) instead")
    func update(text: String) { updatePartial(text: text) }

    func updateMicLevel(rms: Float, peak: Float, peakHold: Float) {
        hudState.feedLevel(rms)
    }

    func updateAppLevel(rms: Float, peak: Float, peakHold: Float) {
        // Future: blend app level
    }

    func setAppMeterVisible(_ visible: Bool) { /* no-op */ }

    func resetLevels() { hudState.audioLevel = 0 }

    // MARK: - Lifecycle

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        animateIn()
        reset()
    }

    func reset() {
        hudState.reset()
        resetTranscript()
    }

    private func resetTranscript() {
        clearTimer?.invalidate()
        clearTimer = nil
        hasReceivedPartial = false
        lastDisplayedText = ""
        hudState.transcriptText = "Listening…"
        hudState.transcriptOpacity = 0.5
    }

    override func close() {
        clearTimer?.invalidate()
        clearTimer = nil
        guard let window = window, window.isVisible else { super.close(); return }
        animateOut { super.close() }
    }

    // MARK: - Animations

    private func animateIn() {
        guard let window = window else { return }
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1.0
        }
    }

    private func animateOut(completion: @MainActor @Sendable @escaping () -> Void) {
        guard let window = window else { completion(); return }

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                window.orderOut(nil)
                completion()
            }
        })
    }

    // MARK: - Accessibility

    private func setupAccessibility() {
        guard let window = window else { return }
        window.setAccessibilityLabel("MacTalk Recording HUD")
        window.setAccessibilityRole(.window)
        window.setAccessibilityHelp("Compact recording indicator with live transcription")
    }
}
