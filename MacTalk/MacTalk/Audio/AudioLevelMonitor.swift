//
//  AudioLevelMonitor.swift
//  MacTalk
//
//  Audio level monitoring with RMS, peak hold, and smoothing
//

import Foundation
import Accelerate
import os

/// Thread-safe audio level monitor.
///
/// ## Thread Safety
/// This class uses `OSAllocatedUnfairLock` for synchronization, which supports
/// priority inheritance to prevent priority inversion when called from audio threads.
///
/// ## Sendable Conformance
/// Marked `@unchecked Sendable` because:
/// - All mutable state is protected by `OSAllocatedUnfairLock`
/// - Configuration values are immutable after initialization
final class AudioLevelMonitor: @unchecked Sendable {
    // MARK: - Configuration

    private let smoothingFactor: Float = 0.3  // Lower = more smoothing
    private let peakHoldDuration: TimeInterval = 0.5  // Seconds to hold peak
    private let minDecibels: Float = -60.0  // Minimum dB level
    private let maxDecibels: Float = 0.0   // Maximum dB level

    // MARK: - State

    private struct State {
        var currentRMS: Float = 0.0
        var currentPeak: Float = 0.0
        var peakHoldValue: Float = 0.0
        var peakHoldTime: Date = .distantPast
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    // MARK: - Public Interface

    /// Audio level data for UI display.
    ///
    /// ## Sendable Conformance
    /// This struct is `Sendable` because all members are immutable value types (`Float`).
    struct LevelData: Equatable, Sendable {
        let rms: Float           // Root Mean Square (0.0 - 1.0)
        let peak: Float          // Current peak (0.0 - 1.0)
        let peakHold: Float      // Peak hold value (0.0 - 1.0)
        let decibels: Float      // RMS in decibels (-60.0 to 0.0)

        static let silent = LevelData(rms: 0, peak: 0, peakHold: 0, decibels: -60)
    }

    /// Update levels with new audio buffer
    func update(buffer: [Float]) -> LevelData {
        guard !buffer.isEmpty else {
            return LevelData.silent
        }

        // Calculate RMS (Root Mean Square) - pure function, no state needed
        let rms = calculateRMS(samples: buffer)

        // Calculate peak - pure function, no state needed
        let peak = calculatePeak(samples: buffer)

        return state.withLock { state in
            // Apply smoothing to RMS
            state.currentRMS = (smoothingFactor * rms) + ((1.0 - smoothingFactor) * state.currentRMS)

            // Update peak (no smoothing)
            state.currentPeak = peak

            // Update peak hold
            updatePeakHold(state: &state, peak: peak)

            // Convert to decibels
            let decibels = amplitudeToDecibels(state.currentRMS)

            return LevelData(
                rms: state.currentRMS,
                peak: state.currentPeak,
                peakHold: state.peakHoldValue,
                decibels: decibels
            )
        }
    }

    /// Reset all levels to zero
    func reset() {
        state.withLock { state in
            state.currentRMS = 0.0
            state.currentPeak = 0.0
            state.peakHoldValue = 0.0
            state.peakHoldTime = .distantPast
        }
    }

    // MARK: - Calculations

    private func calculateRMS(samples: [Float]) -> Float {
        var sum: Float = 0.0

        // Use Accelerate framework for performance
        vDSP_svesq(samples, 1, &sum, vDSP_Length(samples.count))

        let meanSquare = sum / Float(samples.count)
        let rms = sqrt(meanSquare)

        return min(max(rms, 0.0), 1.0)
    }

    private func calculatePeak(samples: [Float]) -> Float {
        var peak: Float = 0.0

        // Find maximum absolute value using Accelerate
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(samples.count))

        return min(max(peak, 0.0), 1.0)
    }

    private func updatePeakHold(state: inout State, peak: Float) {
        let now = Date()

        // If new peak is higher, update immediately
        if peak > state.peakHoldValue {
            state.peakHoldValue = peak
            state.peakHoldTime = now
            return
        }

        // If peak hold duration expired, decay towards current peak
        if now.timeIntervalSince(state.peakHoldTime) > peakHoldDuration {
            // Decay peak hold smoothly
            state.peakHoldValue = max(peak, state.peakHoldValue * 0.95)

            // If decayed close to current peak, reset hold time
            if abs(state.peakHoldValue - peak) < 0.01 {
                state.peakHoldTime = now
            }
        }
    }

    private func amplitudeToDecibels(_ amplitude: Float) -> Float {
        guard amplitude > 0.0 else {
            return minDecibels
        }

        let decibels = 20.0 * log10(amplitude)
        return min(max(decibels, minDecibels), maxDecibels)
    }

    // MARK: - Utility

    /// Normalize decibels to 0.0-1.0 range for UI display
    static func normalizeDecibels(_ db: Float, min: Float = -60.0, max: Float = 0.0) -> Float {
        let clamped = Swift.min(Swift.max(db, min), max)
        return (clamped - min) / (max - min)
    }

    /// Convert normalized level (0.0-1.0) to decibels
    static func normalizedToDecibels(_ normalized: Float, min: Float = -60.0, max: Float = 0.0) -> Float {
        return min + (normalized * (max - min))
    }
}

// MARK: - Multi-Channel Monitor

/// Thread-safe multi-channel level monitor.
///
/// ## Sendable Conformance
/// Marked `@unchecked Sendable` because:
/// - Contains only `Sendable` members (AudioLevelMonitor instances)
/// - No mutable state of its own
final class MultiChannelLevelMonitor: @unchecked Sendable {
    private let micMonitor = AudioLevelMonitor()
    private let appMonitor = AudioLevelMonitor()

    enum Channel: Sendable {
        case microphone
        case application
    }

    func update(channel: Channel, buffer: [Float]) -> AudioLevelMonitor.LevelData {
        switch channel {
        case .microphone:
            return micMonitor.update(buffer: buffer)
        case .application:
            return appMonitor.update(buffer: buffer)
        }
    }

    func reset(channel: Channel? = nil) {
        if let channel = channel {
            switch channel {
            case .microphone:
                micMonitor.reset()
            case .application:
                appMonitor.reset()
            }
        } else {
            micMonitor.reset()
            appMonitor.reset()
        }
    }
}
