//
//  AudioLevelMonitorTests.swift
//  MacTalkTests
//
//  Deterministic tests for metering, smoothing, clamping, and channel isolation.
//

import XCTest
@testable import MacTalk

final class AudioLevelMonitorTests: XCTestCase {
    func test_silenceProducesSilentLevel() {
        let monitor = AudioLevelMonitor()

        let level = monitor.update(buffer: [Float](repeating: 0, count: 1_000))

        XCTAssertEqual(level, .silent)
    }

    func test_firstConstantSignalUpdateAppliesSmoothing() {
        let monitor = AudioLevelMonitor()

        let level = monitor.update(buffer: [Float](repeating: 0.5, count: 1_000))

        XCTAssertEqual(level.rms, 0.15, accuracy: 0.001)
        XCTAssertEqual(level.peak, 0.5, accuracy: 0.001)
        XCTAssertEqual(level.decibels, 20 * log10(0.15), accuracy: 0.01)
    }

    func test_sineWaveRMSIsCalculatedBeforeSmoothing() {
        let monitor = AudioLevelMonitor()
        let samples = (0..<1_024).map { frame in
            0.5 * sin(2 * Float.pi * Float(frame) / 1_024)
        }

        let level = monitor.update(buffer: samples)

        XCTAssertEqual(level.rms, 0.5 / sqrt(2) * 0.3, accuracy: 0.001)
    }

    func test_peakUsesAbsoluteMagnitude() {
        let monitor = AudioLevelMonitor()

        let level = monitor.update(buffer: [0.1, -0.8, 0.3])

        XCTAssertEqual(level.peak, 0.8, accuracy: 0.001)
    }

    func test_peakHoldRetainsRecentHigherPeak() {
        let monitor = AudioLevelMonitor()
        _ = monitor.update(buffer: [0.9])

        let level = monitor.update(buffer: [0.2])

        XCTAssertEqual(level.peak, 0.2, accuracy: 0.001)
        XCTAssertEqual(level.peakHold, 0.9, accuracy: 0.001)
    }

    func test_smoothingConvergesTowardStableInput() {
        let monitor = AudioLevelMonitor()
        var level = AudioLevelMonitor.LevelData.silent

        for _ in 0..<20 {
            level = monitor.update(buffer: [Float](repeating: 0.5, count: 100))
        }

        XCTAssertEqual(level.rms, 0.5, accuracy: 0.001)
    }

    func test_resetClearsSmoothingAndPeakState() {
        let monitor = AudioLevelMonitor()
        for _ in 0..<10 {
            _ = monitor.update(buffer: [0.9])
        }

        monitor.reset()
        let level = monitor.update(buffer: [0.1])

        XCTAssertEqual(level.rms, 0.03, accuracy: 0.001)
        XCTAssertEqual(level.peak, 0.1, accuracy: 0.001)
        XCTAssertEqual(level.peakHold, 0.1, accuracy: 0.001)
    }

    func test_emptyInputReturnsSilentSentinel() {
        let monitor = AudioLevelMonitor()
        _ = monitor.update(buffer: [0.8])

        XCTAssertEqual(monitor.update(buffer: []), .silent)
    }

    func test_peakIsClampedToOne() {
        let monitor = AudioLevelMonitor()

        let level = monitor.update(buffer: [0.2, 1.5, -2.0])

        XCTAssertEqual(level.peak, 1.0, accuracy: 0.001)
    }

    func test_multiChannelMonitorKeepsIndependentSmoothingState() {
        let monitor = MultiChannelLevelMonitor()

        let mic = monitor.update(channel: .microphone, buffer: [Float](repeating: 0.2, count: 100))
        let app = monitor.update(channel: .application, buffer: [Float](repeating: 0.8, count: 100))

        XCTAssertEqual(mic.rms, 0.06, accuracy: 0.001)
        XCTAssertEqual(app.rms, 0.24, accuracy: 0.001)
    }

    func test_resettingOneChannelDoesNotResetTheOther() {
        let monitor = MultiChannelLevelMonitor()
        _ = monitor.update(channel: .microphone, buffer: [0.8])
        _ = monitor.update(channel: .application, buffer: [0.8])

        monitor.reset(channel: .microphone)
        let mic = monitor.update(channel: .microphone, buffer: [0.1])
        let app = monitor.update(channel: .application, buffer: [0.8])

        XCTAssertEqual(mic.rms, 0.03, accuracy: 0.001)
        XCTAssertGreaterThan(app.rms, mic.rms)
    }
}
