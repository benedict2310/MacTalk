//
//  TestHelpers.swift
//  MacTalkTests
//
//  Test utilities for Swift 6 concurrency support (S.02.3a)
//

import XCTest
import AVFoundation
@testable import MacTalk

// MARK: - Thread-Safe Test State Collection

/// Thread-safe wrapper for mutable state in tests.
/// Use this when collecting results from @Sendable callbacks or concurrent tasks.
final class LockIsolated<Value>: @unchecked Sendable {
    private var _value: Value
    private let lock = NSLock()

    init(_ value: Value) {
        self._value = value
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    func withValue<T>(_ operation: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation(&_value)
    }

    func setValue(_ newValue: Value) {
        lock.lock()
        defer { lock.unlock() }
        _value = newValue
    }
}

// MARK: - Async Test Expectations

/// Actor-based expectation for async tests.
/// Provides a thread-safe way to signal test completion without XCTestExpectation.
actor AsyncExpectation {
    private var fulfilled = false

    func fulfill() {
        fulfilled = true
    }

    func isFulfilled() -> Bool {
        fulfilled
    }

    func wait(timeout: Duration = .seconds(5)) async throws {
        let deadline = ContinuousClock.now + timeout
        while !fulfilled {
            if ContinuousClock.now > deadline {
                throw TestError.timeout
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// Test-specific errors
enum TestError: Error, LocalizedError {
    case timeout
    case setupFailed(String)
    case assertionFailed(String)

    var errorDescription: String? {
        switch self {
        case .timeout:
            return "Test timed out waiting for expectation"
        case .setupFailed(let message):
            return "Test setup failed: \(message)"
        case .assertionFailed(let message):
            return "Assertion failed: \(message)"
        }
    }
}

// MARK: - MainActor Utilities

/// Wait for MainActor to process pending work
@MainActor
func flushMainActor() async {
    await Task.yield()
}

// MARK: - Audio Test Buffer Helpers

/// Create a test audio buffer with specified parameters
func createTestBuffer(
    sampleRate: Double = 48000,
    channels: UInt32 = 1,
    frameCount: AVAudioFrameCount = 2048
) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(
        standardFormatWithSampleRate: sampleRate,
        channels: channels
    )!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
    buffer.frameLength = frameCount

    // Fill with silence
    if let channelData = buffer.floatChannelData {
        for channel in 0..<Int(channels) {
            memset(channelData[channel], 0, Int(frameCount) * MemoryLayout<Float>.size)
        }
    }

    return buffer
}

/// Create a test audio buffer with a sine wave
func createTestBufferWithTone(
    sampleRate: Double = 48000,
    channels: UInt32 = 1,
    frameCount: AVAudioFrameCount = 2048,
    frequency: Float = 440.0,
    amplitude: Float = 0.5
) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(
        standardFormatWithSampleRate: sampleRate,
        channels: channels
    )!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
    buffer.frameLength = frameCount

    if let channelData = buffer.floatChannelData {
        let omega = 2.0 * Float.pi * frequency / Float(sampleRate)
        for channel in 0..<Int(channels) {
            for frame in 0..<Int(frameCount) {
                channelData[channel][frame] = amplitude * sin(omega * Float(frame))
            }
        }
    }

    return buffer
}

/// Create a test audio buffer with random noise
func createTestBufferWithNoise(
    sampleRate: Double = 48000,
    channels: UInt32 = 1,
    frameCount: AVAudioFrameCount = 2048,
    amplitude: Float = 0.5
) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(
        standardFormatWithSampleRate: sampleRate,
        channels: channels
    )!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
    buffer.frameLength = frameCount

    if let channelData = buffer.floatChannelData {
        for channel in 0..<Int(channels) {
            for frame in 0..<Int(frameCount) {
                channelData[channel][frame] = Float.random(in: -amplitude...amplitude)
            }
        }
    }

    return buffer
}

// MARK: - Counter Actor for Thread-Safe Counting

/// Actor for safely counting events in concurrent tests
actor TestCounter {
    private var count: Int = 0

    func increment() {
        count += 1
    }

    func decrement() {
        count -= 1
    }

    func getCount() -> Int {
        count
    }

    func reset() {
        count = 0
    }
}

// MARK: - Generic Results Collector Actor

/// Actor to safely collect results from concurrent test tasks.
/// Generic version for collecting any Sendable type.
actor GenericResultsCollector<T: Sendable> {
    private var results: [T] = []

    func add(_ result: T) {
        results.append(result)
    }

    func addAll(_ newResults: [T]) {
        results.append(contentsOf: newResults)
    }

    func getResults() -> [T] {
        results
    }

    func count() -> Int {
        results.count
    }

    func clear() {
        results.removeAll()
    }
}

// MARK: - Test Model Helper

/// Get a test NativeWhisperEngine, returning nil if no valid model available.
/// Use this in tests that need a real engine but should skip gracefully.
func getTestNativeWhisperEngine() -> NativeWhisperEngine? {
    let modelURL = URL(fileURLWithPath: "/tmp/test-model.gguf")

    // Check if model file exists
    guard FileManager.default.fileExists(atPath: modelURL.path) else {
        return nil
    }

    // Try to create engine
    return NativeWhisperEngine(modelURL: modelURL)
}

/// Get a test NativeWhisperEngine, throwing XCTSkip if not available
func requireTestNativeWhisperEngine() throws -> NativeWhisperEngine {
    guard let engine = getTestNativeWhisperEngine() else {
        throw XCTSkip("Test model not available. Download a model to /tmp/test-model.gguf to run NativeWhisperEngine tests.")
    }
    return engine
}

// MARK: - XCTestCase Async Extensions

// Note: Modern XCTest natively supports async test methods.
// Use `func testExample() async throws` directly instead of these helpers.
// These are kept as reference patterns for Swift 6 concurrency in tests.
