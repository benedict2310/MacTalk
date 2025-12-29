//
//  AudioWaveView.swift
//  MacTalk
//
//  Audio-reactive wave visualization for liquid glass bubble UI
//

import AppKit
import QuartzCore

@MainActor
final class AudioWaveView: NSView {
    // MARK: - Configuration

    private let numberOfWaves = 3  // Multiple layers for depth
    private let maxAmplitude: CGFloat = 120.0  // Maximum wave height (dramatically increased!)
    private let numberOfPoints = 100  // Sample points per wave

    // MARK: - State

    private var waveLayers: [CAShapeLayer] = []
    private var currentAudioLevel: Float = 0.0
    private var smoothedLevel: Float = 0.0
    private let smoothingFactor: Float = 0.08  // Very responsive (minimal smoothing for instant reaction)

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setupWaveLayers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        setupWaveLayers()
    }

    // MARK: - Setup

    private func setupWaveLayers() {
        for i in 0..<numberOfWaves {
            let layer = CAShapeLayer()

            // Decreasing opacity for depth effect (increased base opacity for better visibility)
            let opacity = 0.5 - CGFloat(i) * 0.15
            layer.strokeColor = NSColor.white.withAlphaComponent(opacity).cgColor
            layer.fillColor = nil
            layer.lineWidth = 2.5  // Slightly thicker for better visibility
            layer.lineCap = .round
            layer.lineJoin = .round

            self.layer?.addSublayer(layer)
            waveLayers.append(layer)
        }
    }

    // MARK: - Public Interface

    /// Update wave visualization with current audio level
    /// - Parameter level: Audio level from 0.0 (silent) to 1.0 (max)
    func updateAudioLevel(_ level: Float) {
        // Apply smoothing to avoid jittery waves
        smoothedLevel = smoothedLevel * (1.0 - smoothingFactor) + level * smoothingFactor

        let amplitude = CGFloat(smoothedLevel) * maxAmplitude

        for (index, layer) in waveLayers.enumerated() {
            // Different frequencies for depth
            let frequency = 2.0 + CGFloat(index) * 1.0
            // Offset phases for visual variety
            let phase = CGFloat(index) * 0.5
            // Decrease amplitude per layer for depth effect
            let layerAmplitude = amplitude * (1.0 - CGFloat(index) * 0.2)

            updateWavePath(layer, amplitude: layerAmplitude, frequency: frequency, phase: phase)
        }
    }

    /// Reset wave visualization to idle state
    func reset() {
        smoothedLevel = 0.0
        updateAudioLevel(0.0)
    }

    // MARK: - Wave Generation

    private func updateWavePath(_ layer: CAShapeLayer, amplitude: CGFloat,
                               frequency: CGFloat, phase: CGFloat) {
        let width = bounds.width
        let height = bounds.height
        let midY = height / 2

        let path = NSBezierPath()
        path.move(to: NSPoint(x: 0, y: midY))

        // Generate smooth sine wave
        for i in 0...numberOfPoints {
            let x = CGFloat(i) / CGFloat(numberOfPoints) * width
            let normalizedX = x / width

            // Sine wave calculation: y = A * sin(f * 2π * x + φ) + offset
            let y = sin((normalizedX * frequency * 2 * .pi) + phase) * amplitude + midY

            path.line(to: NSPoint(x: x, y: y))
        }

        // Smoothly animate path changes with very fast updates
        let animation = CABasicAnimation(keyPath: "path")
        animation.duration = 0.05  // Very fast update for instant response
        animation.timingFunction = CAMediaTimingFunction(name: .linear)  // Linear for snappier feel
        animation.fromValue = layer.path
        animation.toValue = path.cgPath

        layer.add(animation, forKey: "waveAnimation")
        layer.path = path.cgPath
    }
}
