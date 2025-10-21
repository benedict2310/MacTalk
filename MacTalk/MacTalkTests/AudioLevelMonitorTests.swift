//
//  AudioLevelMonitorTests.swift
//  MacTalkTests
//
//  Unit tests for AudioLevelMonitor component
//

import XCTest
@testable import MacTalk

final class AudioLevelMonitorTests: XCTestCase {

    var monitor: AudioLevelMonitor!

    override func setUp() {
        super.setUp()
        monitor = AudioLevelMonitor()
    }

    override func tearDown() {
        monitor = nil
        super.tearDown()
    }

    // MARK: - RMS Calculation Tests

    func testRMSCalculationSilence() {
        let silence: [Float] = Array(repeating: 0.0, count: 1000)

        let levelData = monitor.update(buffer: silence)

        XCTAssertEqual(levelData.rms, 0.0, accuracy: 0.001)
        XCTAssertEqual(levelData.peak, 0.0, accuracy: 0.001)
        XCTAssertEqual(levelData.decibels, -60.0, accuracy: 0.1)
    }

    func testRMSCalculationConstantSignal() {
        // Constant amplitude signal
        let signal: [Float] = Array(repeating: 0.5, count: 1000)

        let levelData = monitor.update(buffer: signal)

        // RMS of constant signal equals the value
        XCTAssertEqual(levelData.rms, 0.5, accuracy: 0.01)
        XCTAssertEqual(levelData.peak, 0.5, accuracy: 0.001)
    }

    func testRMSCalculationSineWave() {
        // Generate simple sine wave
        var samples: [Float] = []
        for i in 0..<1000 {
            let sample = sin(Float(i) * 0.1) * 0.5
            samples.append(sample)
        }

        let levelData = monitor.update(buffer: samples)

        // RMS of sine wave should be amplitude / sqrt(2)
        // For amplitude 0.5: RMS ≈ 0.353
        XCTAssertGreaterThan(levelData.rms, 0.2)
        XCTAssertLessThan(levelData.rms, 0.5)
    }

    // MARK: - Peak Detection Tests

    func testPeakDetection() {
        var samples: [Float] = Array(repeating: 0.1, count: 100)
        samples[50] = 0.9 // Peak value

        let levelData = monitor.update(buffer: samples)

        XCTAssertEqual(levelData.peak, 0.9, accuracy: 0.001)
    }

    func testPeakDetectionNegativeValues() {
        var samples: [Float] = Array(repeating: 0.1, count: 100)
        samples[50] = -0.8 // Negative peak

        let levelData = monitor.update(buffer: samples)

        // Peak should be absolute value
        XCTAssertEqual(levelData.peak, 0.8, accuracy: 0.001)
    }

    // MARK: - Peak Hold Tests

    func testPeakHold() {
        // First update with high peak
        let highSamples: [Float] = [0.8]
        let level1 = monitor.update(buffer: highSamples)
        XCTAssertEqual(level1.peakHold, 0.8, accuracy: 0.001)

        // Second update with lower peak (immediately)
        let lowSamples: [Float] = [0.3]
        let level2 = monitor.update(buffer: lowSamples)

        // Peak hold should maintain high value
        XCTAssertEqual(level2.peakHold, 0.8, accuracy: 0.01)
        XCTAssertEqual(level2.peak, 0.3, accuracy: 0.001)
    }

    func testPeakHoldDecay() {
        // High peak
        let highSamples: [Float] = [0.9]
        _ = monitor.update(buffer: highSamples)

        // Wait for decay (would need to mock time in real scenario)
        // For this test, we'll just verify multiple updates cause decay
        for _ in 0..<10 {
            let lowSamples: [Float] = [0.1]
            _ = monitor.update(buffer: lowSamples)
        }

        let finalLevel = monitor.update(buffer: [0.1])

        // Peak hold should have decayed towards actual peak
        XCTAssertLessThan(finalLevel.peakHold, 0.9)
    }

    func testPeakHoldReset() {
        let samples: [Float] = [0.8]
        _ = monitor.update(buffer: samples)

        monitor.reset()

        let samples2: [Float] = [0.1]
        let levelData = monitor.update(buffer: samples2)

        XCTAssertEqual(levelData.peakHold, 0.1, accuracy: 0.01)
    }

    // MARK: - Smoothing Tests

    func testSmoothing() {
        // First update
        let samples1: [Float] = Array(repeating: 0.5, count: 100)
        let level1 = monitor.update(buffer: samples1)

        // Second update with different amplitude
        let samples2: [Float] = Array(repeating: 0.8, count: 100)
        let level2 = monitor.update(buffer: samples2)

        // Due to smoothing, second RMS should not jump to 0.8 immediately
        XCTAssertGreaterThan(level2.rms, level1.rms)
        XCTAssertLessThan(level2.rms, 0.8)
    }

    func testSmoothingConvergence() {
        // Feed same signal multiple times
        let samples: [Float] = Array(repeating: 0.5, count: 100)

        var lastRMS: Float = 0.0
        for _ in 0..<20 {
            let levelData = monitor.update(buffer: samples)
            lastRMS = levelData.rms
        }

        // After many iterations, should converge to actual RMS
        XCTAssertEqual(lastRMS, 0.5, accuracy: 0.05)
    }

    // MARK: - Decibel Conversion Tests

    func testDecibelsForSilence() {
        let silence: [Float] = Array(repeating: 0.0, count: 100)
        let levelData = monitor.update(buffer: silence)

        XCTAssertEqual(levelData.decibels, -60.0, accuracy: 0.1)
    }

    func testDecibelsForMaxLevel() {
        let maxSignal: [Float] = Array(repeating: 1.0, count: 100)

        // Reset first to avoid smoothing effects
        monitor.reset()

        var levelData = AudioLevelMonitor.LevelData.silent
        for _ in 0..<10 {
            levelData = monitor.update(buffer: maxSignal)
        }

        // 1.0 amplitude should be 0 dB (after convergence)
        XCTAssertGreaterThan(levelData.decibels, -5.0)
        XCTAssertLessThanOrEqual(levelData.decibels, 0.0)
    }

    func testDecibelsConversionUtility() {
        XCTAssertEqual(
            AudioLevelMonitor.normalizeDecibels(-60.0, min: -60.0, max: 0.0),
            0.0,
            accuracy: 0.001
        )

        XCTAssertEqual(
            AudioLevelMonitor.normalizeDecibels(0.0, min: -60.0, max: 0.0),
            1.0,
            accuracy: 0.001
        )

        XCTAssertEqual(
            AudioLevelMonitor.normalizeDecibels(-30.0, min: -60.0, max: 0.0),
            0.5,
            accuracy: 0.001
        )
    }

    func testNormalizedToDecibels() {
        XCTAssertEqual(
            AudioLevelMonitor.normalizedToDecibels(0.0, min: -60.0, max: 0.0),
            -60.0,
            accuracy: 0.001
        )

        XCTAssertEqual(
            AudioLevelMonitor.normalizedToDecibels(1.0, min: -60.0, max: 0.0),
            0.0,
            accuracy: 0.001
        )

        XCTAssertEqual(
            AudioLevelMonitor.normalizedToDecibels(0.5, min: -60.0, max: 0.0),
            -30.0,
            accuracy: 0.001
        )
    }

    // MARK: - Edge Cases

    func testEmptyBuffer() {
        let emptyBuffer: [Float] = []
        let levelData = monitor.update(buffer: emptyBuffer)

        XCTAssertEqual(levelData, AudioLevelMonitor.LevelData.silent)
    }

    func testSingleSample() {
        let singleSample: [Float] = [0.5]
        let levelData = monitor.update(buffer: singleSample)

        XCTAssertGreaterThan(levelData.rms, 0.0)
    }

    func testClipping() {
        // Values over 1.0 should be clamped
        let clippedSamples: [Float] = [1.5, 2.0, 0.8]
        let levelData = monitor.update(buffer: clippedSamples)

        // Peak should be clamped to 1.0
        XCTAssertLessThanOrEqual(levelData.peak, 1.0)
        XCTAssertLessThanOrEqual(levelData.rms, 1.0)
    }

    func testReset() {
        // Build up some state
        let samples: [Float] = Array(repeating: 0.8, count: 100)
        _ = monitor.update(buffer: samples)
        _ = monitor.update(buffer: samples)

        monitor.reset()

        // After reset, should start fresh
        let levelData = monitor.update(buffer: [0.1])

        // Should be close to 0.1, not influenced by previous state
        XCTAssertLessThan(levelData.rms, 0.2)
    }

    // MARK: - Multi-Channel Monitor Tests

    func testMultiChannelMonitor() {
        let multiMonitor = MultiChannelLevelMonitor()

        let micSamples: [Float] = Array(repeating: 0.5, count: 100)
        let appSamples: [Float] = Array(repeating: 0.3, count: 100)

        let micLevel = multiMonitor.update(channel: .microphone, buffer: micSamples)
        let appLevel = multiMonitor.update(channel: .application, buffer: appSamples)

        XCTAssertNotEqual(micLevel.rms, appLevel.rms)
        XCTAssertGreaterThan(micLevel.rms, appLevel.rms)
    }

    func testMultiChannelReset() {
        let multiMonitor = MultiChannelLevelMonitor()

        let samples: [Float] = Array(repeating: 0.8, count: 100)
        _ = multiMonitor.update(channel: .microphone, buffer: samples)
        _ = multiMonitor.update(channel: .application, buffer: samples)

        multiMonitor.reset(channel: .microphone)

        let micLevel = multiMonitor.update(channel: .microphone, buffer: [0.1])
        let appLevel = multiMonitor.update(channel: .application, buffer: [0.1])

        // Mic should be reset, app should still have smoothing history
        XCTAssertLessThan(micLevel.rms, appLevel.rms)
    }

    func testMultiChannelResetAll() {
        let multiMonitor = MultiChannelLevelMonitor()

        let samples: [Float] = Array(repeating: 0.8, count: 100)
        _ = multiMonitor.update(channel: .microphone, buffer: samples)
        _ = multiMonitor.update(channel: .application, buffer: samples)

        multiMonitor.reset() // Reset all channels

        let micLevel = multiMonitor.update(channel: .microphone, buffer: [0.1])
        let appLevel = multiMonitor.update(channel: .application, buffer: [0.1])

        // Both should be reset
        XCTAssertLessThan(micLevel.rms, 0.2)
        XCTAssertLessThan(appLevel.rms, 0.2)
    }

    // MARK: - Performance Tests

    func testPerformanceRMSCalculation() {
        let samples: [Float] = (0..<16000).map { _ in Float.random(in: -1.0...1.0) }

        measure {
            for _ in 0..<100 {
                _ = monitor.update(buffer: samples)
            }
        }
    }

    func testPerformanceSmallBuffers() {
        measure {
            for _ in 0..<10000 {
                let samples: [Float] = Array(repeating: 0.5, count: 256)
                _ = monitor.update(buffer: samples)
            }
        }
    }
}
