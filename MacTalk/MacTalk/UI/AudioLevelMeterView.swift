//
//  AudioLevelMeterView.swift
//  MacTalk
//
//  Custom NSView for visualizing audio levels
//

import AppKit

@MainActor
final class AudioLevelMeterView: NSView {
    // MARK: - Configuration

    private let orientation: Orientation
    private let showPeakHold: Bool

    enum Orientation {
        case horizontal
        case vertical
    }

    // MARK: - State

    private var rmsLevel: Float = 0.0
    private var peakLevel: Float = 0.0
    private var peakHoldLevel: Float = 0.0

    // MARK: - Colors

    private let greenColor = NSColor(calibratedRed: 0.0, green: 0.8, blue: 0.0, alpha: 1.0)
    private let yellowColor = NSColor(calibratedRed: 1.0, green: 0.9, blue: 0.0, alpha: 1.0)
    private let redColor = NSColor(calibratedRed: 1.0, green: 0.0, blue: 0.0, alpha: 1.0)
    private let backgroundColor = NSColor(white: 0.2, alpha: 0.5)
    private let peakHoldColor = NSColor.white

    // MARK: - Thresholds

    private let yellowThreshold: Float = 0.7  // -6 dB
    private let redThreshold: Float = 0.9     // -1 dB

    // MARK: - Initialization

    init(orientation: Orientation = .horizontal, showPeakHold: Bool = true) {
        self.orientation = orientation
        self.showPeakHold = showPeakHold
        super.init(frame: .zero)
        self.wantsLayer = true
    }

    required init?(coder: NSCoder) {
        self.orientation = .horizontal
        self.showPeakHold = true
        super.init(coder: coder)
        self.wantsLayer = true
    }

    // MARK: - Public Interface

    func update(rms: Float, peak: Float, peakHold: Float) {
        self.rmsLevel = rms
        self.peakLevel = peak
        self.peakHoldLevel = peakHold
        self.needsDisplay = true
    }

    func reset() {
        self.rmsLevel = 0.0
        self.peakLevel = 0.0
        self.peakHoldLevel = 0.0
        self.needsDisplay = true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // Draw background
        backgroundColor.setFill()
        context.fill(bounds)

        // Draw RMS level bar
        drawLevelBar(context: context, level: rmsLevel, rect: bounds)

        // Draw peak hold indicator
        if showPeakHold && peakHoldLevel > 0.0 {
            drawPeakHold(context: context, level: peakHoldLevel, rect: bounds)
        }
    }

    private func drawLevelBar(context: CGContext, level: Float, rect: CGRect) {
        guard level > 0.0 else { return }

        let levelRect: CGRect
        switch orientation {
        case .horizontal:
            let width = rect.width * CGFloat(level)
            levelRect = CGRect(x: rect.minX, y: rect.minY, width: width, height: rect.height)
        case .vertical:
            let height = rect.height * CGFloat(level)
            levelRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: height)
        }

        // Choose color based on level
        let color = colorForLevel(level)
        color.setFill()
        context.fill(levelRect)

        // Add gradient effect for better visualization
        if let gradient = createGradient(for: color) {
            context.saveGState()
            context.clip(to: levelRect)

            let startPoint = CGPoint(x: levelRect.minX, y: levelRect.minY)
            let endPoint: CGPoint

            switch orientation {
            case .horizontal:
                endPoint = CGPoint(x: levelRect.maxX, y: levelRect.minY)
            case .vertical:
                endPoint = CGPoint(x: levelRect.minX, y: levelRect.maxY)
            }

            context.drawLinearGradient(
                gradient,
                start: startPoint,
                end: endPoint,
                options: []
            )

            context.restoreGState()
        }
    }

    private func drawPeakHold(context: CGContext, level: Float, rect: CGRect) {
        peakHoldColor.setStroke()

        let lineWidth: CGFloat = 2.0
        context.setLineWidth(lineWidth)

        switch orientation {
        case .horizontal:
            let xPosition = rect.minX + (rect.width * CGFloat(level))
            context.move(to: CGPoint(x: xPosition, y: rect.minY))
            context.addLine(to: CGPoint(x: xPosition, y: rect.maxY))
        case .vertical:
            let yPosition = rect.minY + (rect.height * CGFloat(level))
            context.move(to: CGPoint(x: rect.minX, y: yPosition))
            context.addLine(to: CGPoint(x: rect.maxX, y: yPosition))
        }

        context.strokePath()
    }

    private func colorForLevel(_ level: Float) -> NSColor {
        if level >= redThreshold {
            return redColor
        } else if level >= yellowThreshold {
            return yellowColor
        } else {
            return greenColor
        }
    }

    private func createGradient(for color: NSColor) -> CGGradient? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        let cgColor = color.cgColor

        let colors = [
            cgColor.copy(alpha: 0.8) as Any,
            cgColor as Any
        ]

        let locations: [CGFloat] = [0.0, 1.0]

        return CGGradient(
            colorsSpace: colorSpace,
            colors: colors as CFArray,
            locations: locations
        )
    }

    // MARK: - Intrinsic Size

    override var intrinsicContentSize: NSSize {
        switch orientation {
        case .horizontal:
            return NSSize(width: NSView.noIntrinsicMetric, height: 20)
        case .vertical:
            return NSSize(width: 20, height: NSView.noIntrinsicMetric)
        }
    }
}

// MARK: - Dual Channel Level Meter

@MainActor
final class DualChannelLevelMeterView: NSView {
    private let micMeter: AudioLevelMeterView
    private let appMeter: AudioLevelMeterView
    private let micLabel: NSTextField
    private let appLabel: NSTextField
    private let stackView: NSStackView

    init() {
        micMeter = AudioLevelMeterView(orientation: .horizontal, showPeakHold: true)
        appMeter = AudioLevelMeterView(orientation: .horizontal, showPeakHold: true)

        micLabel = NSTextField(labelWithString: "Mic:")
        appLabel = NSTextField(labelWithString: "App:")

        stackView = NSStackView()

        super.init(frame: .zero)

        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    private func setupUI() {
        // Configure labels
        for label in [micLabel, appLabel] {
            label.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
            label.textColor = .secondaryLabelColor
            label.alignment = .right
            label.setContentHuggingPriority(.required, for: .horizontal)
        }

        // Create rows
        let micRow = NSStackView(views: [micLabel, micMeter])
        micRow.orientation = .horizontal
        micRow.spacing = 8

        let appRow = NSStackView(views: [appLabel, appMeter])
        appRow.orientation = .horizontal
        appRow.spacing = 8

        // Create vertical stack
        stackView.orientation = .vertical
        stackView.spacing = 4
        stackView.addArrangedSubview(micRow)
        stackView.addArrangedSubview(appRow)

        addSubview(stackView)

        // Constraints
        stackView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor),

            micLabel.widthAnchor.constraint(equalToConstant: 40),
            appLabel.widthAnchor.constraint(equalToConstant: 40)
        ])
    }

    func updateMic(rms: Float, peak: Float, peakHold: Float) {
        micMeter.update(rms: rms, peak: peak, peakHold: peakHold)
    }

    func updateApp(rms: Float, peak: Float, peakHold: Float) {
        appMeter.update(rms: rms, peak: peak, peakHold: peakHold)
    }

    func setAppMeterVisible(_ visible: Bool) {
        appLabel.isHidden = !visible
        appMeter.isHidden = !visible
    }

    func reset() {
        micMeter.reset()
        appMeter.reset()
    }
}
