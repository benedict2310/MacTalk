//
//  HUDWindowController.swift
//  MacTalk
//
//  Floating Liquid Glass HUD overlay with compact, expanded, and copied phases.
//

import AppKit
import SwiftUI
import QuartzCore
import Combine

// MARK: - Layout

enum HUDLayoutPhase: Sendable {
    case compact
    case expanded
    case copied

    var preferredSize: CGSize {
        switch self {
        case .compact:
            return CGSize(width: 140, height: 36)
        case .expanded:
            return CGSize(width: 320, height: 44)
        case .copied:
            return CGSize(width: 130, height: 36)
        }
    }
}

// MARK: - Window

private final class HUDWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Shared State

@MainActor
final class HUDState: ObservableObject {
    @Published private(set) var layoutPhase: HUDLayoutPhase = .compact
    @Published var transcriptText: String = "Listening…"
    @Published var transcriptOpacity: Double = 0.55
    @Published var isFinalTranscript = false
    @Published var barLevels: [CGFloat] = [0.18, 0.28, 0.22, 0.26, 0.18]
    @Published var startDate: Date = Date()

    var onLayoutPhaseChange: (@MainActor @Sendable (HUDLayoutPhase) -> Void)?

    private let springAnimation = Animation.spring(duration: 0.28, bounce: 0.14)
    private let smoothingFactor: Float = 0.18
    private let idleBarLevels: [CGFloat] = [0.18, 0.28, 0.22, 0.26, 0.18]
    private let barWeights: [CGFloat] = [0.58, 0.82, 1.0, 0.78, 0.6]

    private var micLevel: Float = 0
    private var appLevel: Float = 0
    private var isHovering = false
    private var hasTranscript = false
    private var showingCopied = false

    func beginSession() {
        startDate = Date()
        transcriptText = "Listening…"
        transcriptOpacity = 0.55
        isFinalTranscript = false
        hasTranscript = false
        showingCopied = false
        isHovering = false
        micLevel = 0
        appLevel = 0
        resetLevels()
        updateLayoutPhase(animated: false)
    }

    func resetAll() {
        beginSession()
    }

    func setHovering(_ hovering: Bool) {
        guard !showingCopied else { return }
        isHovering = hovering
        updateLayoutPhase(animated: true)
    }

    func showPartialText(_ text: String) {
        showingCopied = false
        hasTranscript = !text.isEmpty
        transcriptText = Self.previewText(for: text.isEmpty ? "Listening…" : text)
        transcriptOpacity = 0.7
        isFinalTranscript = false
        updateLayoutPhase(animated: true)
    }

    func showFinalText(_ text: String) {
        showingCopied = false
        hasTranscript = !text.isEmpty
        transcriptText = Self.previewText(for: text.isEmpty ? "Listening…" : text)
        transcriptOpacity = 1.0
        isFinalTranscript = true
        updateLayoutPhase(animated: true)
    }

    func showCopiedState() {
        showingCopied = true
        updateLayoutPhase(animated: true)
    }

    func updateMic(rms: Float, peak: Float, peakHold: Float) {
        let input = max(rms, peak * 0.8, peakHold * 0.65)
        micLevel = smoothed(level: micLevel, toward: max(0, input))
        refreshBars()
    }

    func updateApp(rms: Float, peak: Float, peakHold: Float) {
        let input = max(rms, peak * 0.8, peakHold * 0.65)
        appLevel = smoothed(level: appLevel, toward: max(0, input))
        refreshBars()
    }

    func resetLevels() {
        micLevel = 0
        appLevel = 0
        barLevels = idleBarLevels
    }

    private func smoothed(level current: Float, toward target: Float) -> Float {
        current * (1 - smoothingFactor) + target * smoothingFactor
    }

    private func refreshBars() {
        let combinedLevel = max(micLevel, appLevel)

        guard combinedLevel > 0.02 else {
            barLevels = idleBarLevels
            return
        }

        let clamped = CGFloat(min(max(combinedLevel, 0), 1))
        barLevels = barWeights.map { weight in
            let jitter = CGFloat.random(in: -0.07 ... 0.07)
            let normalized = min(max(clamped * weight + jitter, 0.08), 1.0)
            return normalized
        }
    }

    private func updateLayoutPhase(animated: Bool) {
        let nextPhase: HUDLayoutPhase = showingCopied ? .copied : ((hasTranscript || isHovering) ? .expanded : .compact)
        guard nextPhase != layoutPhase else { return }

        if animated {
            withAnimation(springAnimation) {
                layoutPhase = nextPhase
            }
        } else {
            layoutPhase = nextPhase
        }

        onLayoutPhaseChange?(nextPhase)
    }

    private static func previewText(for text: String) -> String {
        let collapsed = text
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")

        guard collapsed.count > 220 else { return collapsed }
        return "…" + String(collapsed.suffix(220))
    }
}

// MARK: - SwiftUI Views

@available(macOS 26.4, *)
private struct HUDLevelBarsView: View {
    let levels: [CGFloat]

    private var isActive: Bool {
        levels.contains { $0 > 0.3 }
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(.white.opacity(isActive ? 0.7 : 0.3))
                    .frame(width: 3, height: 3 + (min(max(level, 0), 1) * 11))
                    .animation(.linear(duration: 0.06), value: level)
            }
        }
        .frame(height: 14, alignment: .bottom)
        .accessibilityHidden(true)
    }
}

@available(macOS 26.4, *)
private struct HUDContentView: View {
    @ObservedObject var state: HUDState
    let onStop: @MainActor @Sendable () -> Void

    @State private var currentDate = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        let phase = state.layoutPhase

        Group {
            switch phase {
            case .compact, .expanded:
                liveContent(for: phase)
            case .copied:
                copiedContent
            }
        }
        .frame(width: phase.preferredSize.width, height: phase.preferredSize.height, alignment: .leading)
        .glassEffect()
        .clipShape(Capsule())
        .contentShape(Capsule())
        .animation(.spring(duration: 0.28, bounce: 0.14), value: phase)
        .onHover { hovering in
            state.setHovering(hovering)
        }
        .onReceive(timer) { date in
            currentDate = date
        }
    }

    @ViewBuilder
    private func liveContent(for phase: HUDLayoutPhase) -> some View {
        HStack(spacing: phase == .expanded ? 10 : 8) {
            Image(systemName: "mic.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.red)
                .frame(width: 12)

            HUDLevelBarsView(levels: state.barLevels)

            Text(Self.elapsedString(from: state.startDate, now: currentDate))
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 30, alignment: .trailing)

            if phase == .expanded {
                Text(state.transcriptText)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .opacity(state.transcriptOpacity)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: onStop) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Stop Recording")
            }
        }
        .padding(.horizontal, phase == .expanded ? 14 : 12)
        .padding(.vertical, phase == .expanded ? 9 : 8)
    }

    private var copiedContent: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.green)

            Text("Copied")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private static func elapsedString(from startDate: Date, now: Date) -> String {
        let elapsed = max(0, Int(now.timeIntervalSince(startDate)))
        let minutes = elapsed / 60
        let seconds = elapsed % 60
        let secondsText = seconds < 10 ? "0\(seconds)" : "\(seconds)"
        return "\(minutes):\(secondsText)"
    }
}

// MARK: - Window Controller

@MainActor
final class HUDWindowController: NSWindowController {
    var onStop: (() -> Void)?

    private let hudState = HUDState()
    private var postFinalTask: Task<Void, Never>?

    convenience init() {
        let initialSize = HUDLayoutPhase.compact.preferredSize
        let window = HUDWindow(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        window.ignoresMouseEvents = false
        window.isMovableByWindowBackground = false
        window.animationBehavior = .none

        self.init(window: window)
        setupContentView()
        setupAccessibility()
        setupPhaseCallback()
        updateWindowFrame(for: .compact, animated: false)
    }

    override func showWindow(_ sender: Any?) {
        cancelPostFinalTask()
        hudState.beginSession()
        updateWindowFrame(for: .compact, animated: false)

        guard let window else {
            super.showWindow(sender)
            return
        }

        window.alphaValue = 0
        super.showWindow(sender)
        animateIn()
    }

    override func close() {
        cancelPostFinalTask()

        guard let window, window.isVisible else {
            performImmediateClose()
            return
        }

        animateOut { [weak self] in
            self?.performImmediateClose()
        }
    }

    func updatePartial(text: String) {
        cancelPostFinalTask()
        hudState.showPartialText(text)
    }

    func updateFinal(text: String) {
        cancelPostFinalTask()
        hudState.showFinalText(text)

        postFinalTask = Task { @MainActor [weak self] in
            guard let self else { return }

            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            hudState.showCopiedState()

            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            close()
        }
    }

    func updateMicLevel(rms: Float, peak: Float, peakHold: Float) {
        hudState.updateMic(rms: rms, peak: peak, peakHold: peakHold)
    }

    func updateAppLevel(rms: Float, peak: Float, peakHold: Float) {
        hudState.updateApp(rms: rms, peak: peak, peakHold: peakHold)
    }

    func setAppMeterVisible(_ visible: Bool) {
        // Compatibility no-op.
    }

    func resetLevels() {
        hudState.resetLevels()
    }

    func reset() {
        cancelPostFinalTask()
        hudState.resetAll()
        updateWindowFrame(for: .compact, animated: false)
    }

    // MARK: - Setup

    private func setupContentView() {
        guard let window else { return }

        let containerView = NSView(frame: NSRect(origin: .zero, size: HUDLayoutPhase.compact.preferredSize))
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor.clear.cgColor
        window.contentView = containerView

        if #available(macOS 26.4, *) {
            let hostView = NSHostingView(
                rootView: HUDContentView(state: hudState) { [weak self] in
                    self?.onStop?()
                }
            )
            hostView.frame = containerView.bounds
            hostView.autoresizingMask = [.width, .height]
            hostView.wantsLayer = true
            hostView.layer?.backgroundColor = NSColor.clear.cgColor
            containerView.addSubview(hostView)
        }
    }

    private func setupAccessibility() {
        guard let window else { return }
        window.setAccessibilityLabel("MacTalk Recording HUD")
        window.setAccessibilityRole(.window)
        window.setAccessibilityHelp("Anchored recording HUD with live transcript preview and stop control")
    }

    private func setupPhaseCallback() {
        hudState.onLayoutPhaseChange = { [weak self] phase in
            self?.updateWindowFrame(for: phase, animated: true)
        }
    }

    // MARK: - Window Placement

    private func activeScreen() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private func updateWindowFrame(for phase: HUDLayoutPhase, animated: Bool) {
        guard let window else { return }

        let screen = window.isVisible ? (window.screen ?? activeScreen()) : activeScreen()
        guard let screen else { return }

        let size = phase.preferredSize
        let visibleFrame = screen.visibleFrame
        let origin = CGPoint(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.maxY - size.height - 12
        )
        let frame = CGRect(origin: origin, size: size)

        NSLog("[HUD] updateWindowFrame phase=\(phase) size=\(size) visibleFrame=\(visibleFrame) origin=\(origin) animated=\(animated)")

        if animated && window.isVisible {
            window.setFrame(frame, display: true, animate: true)
        } else {
            window.setFrame(frame, display: true)
        }
    }

    // MARK: - Animations

    private func animateIn() {
        guard let window else { return }
        let finalFrame = window.frame
        NSLog("[HUD] animateIn finalFrame=\(finalFrame)")

        // Start above the screen (slide down from top)
        var startFrame = finalFrame
        startFrame.origin.y = finalFrame.origin.y + 60
        window.setFrame(startFrame, display: false)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1.0
            window.animator().setFrame(finalFrame, display: true)
        }
    }

    private func animateOut(completion: @MainActor @Sendable @escaping () -> Void) {
        guard let window else {
            completion()
            return
        }

        // Slide up and fade out
        var upFrame = window.frame
        upFrame.origin.y = upFrame.origin.y + 40

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
            window.animator().setFrame(upFrame, display: true)
        }, completionHandler: {
            MainActor.assumeIsolated {
                window.orderOut(nil)
                completion()
            }
        })
    }

    // MARK: - Helpers

    private func cancelPostFinalTask() {
        postFinalTask?.cancel()
        postFinalTask = nil
    }

    private func performImmediateClose() {
        super.close()
    }
}
