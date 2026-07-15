//
//  ConcurrencyStressTests.swift
//  MacTalkTests
//
//  Focused regression tests for production synchronization boundaries.
//

import XCTest
@testable import MacTalk

final class ConcurrencyStressTests: XCTestCase {
    func test_audioMixerConcurrentConversionsCompleteWithValidOutput() async {
        let mixer = AudioMixer()
        let validResults = TestCounter()

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<100 {
                group.addTask {
                    let buffer = index.isMultiple(of: 2)
                        ? makeConstantPCMBuffer(sampleRate: 48_000, channels: 1, frameCount: 1_200)
                        : makeConstantPCMBuffer(sampleRate: 44_100, channels: 2, frameCount: 1_103)
                    if let output = mixer.convert(buffer: buffer),
                       !output.isEmpty,
                       output.allSatisfy({ $0.isFinite }) {
                        await validResults.increment()
                    }
                }
            }
        }

        let validCount = await validResults.getCount()
        XCTAssertEqual(validCount, 100)
    }

    func test_audioLevelMonitorConcurrentUpdatesStayInRange() async {
        let monitor = AudioLevelMonitor()
        let validResults = TestCounter()

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<100 {
                group.addTask {
                    let amplitude = Float((index % 10) + 1) / 10
                    let result = monitor.update(buffer: [Float](repeating: amplitude, count: 128))
                    if result.rms.isFinite,
                       (0...1).contains(result.rms),
                       (0...1).contains(result.peak),
                       (0...1).contains(result.peakHold) {
                        await validResults.increment()
                    }
                }
            }
        }

        let validCount = await validResults.getCount()
        XCTAssertEqual(validCount, 100)
    }

    func test_multiChannelMonitorConcurrentUpdatesStayIndependent() async {
        let monitor = MultiChannelLevelMonitor()
        let micUpdates = TestCounter()
        let appUpdates = TestCounter()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<50 {
                group.addTask {
                    let result = monitor.update(channel: .microphone, buffer: [Float](repeating: 0.2, count: 128))
                    if (0...1).contains(result.rms) { await micUpdates.increment() }
                }
                group.addTask {
                    let result = monitor.update(channel: .application, buffer: [Float](repeating: 0.8, count: 128))
                    if (0...1).contains(result.rms) { await appUpdates.increment() }
                }
            }
        }

        let micCount = await micUpdates.getCount()
        let appCount = await appUpdates.getCount()
        XCTAssertEqual(micCount, 50)
        XCTAssertEqual(appCount, 50)
    }

    func test_audioCaptureCallbackAssignmentIsRaceFree() async {
        let capture = AudioCapture()
        let assignments = TestCounter()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    capture.onPCMFloatBuffer = { _, _ in }
                    await assignments.increment()
                }
            }
        }

        let assignmentCount = await assignments.getCount()
        XCTAssertEqual(assignmentCount, 100)
    }

    func test_screenAudioCaptureCallbackAssignmentIsRaceFree() async {
        let capture = ScreenAudioCapture()
        let assignments = TestCounter()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    capture.onAudioSampleBuffer = { _ in }
                    capture.onStreamError = { _ in }
                    await assignments.increment()
                }
            }
        }

        let assignmentCount = await assignments.getCount()
        XCTAssertEqual(assignmentCount, 100)
    }

    func test_appSettingsConcurrentProviderWritesRemainValid() async {
        let suiteName = "AppSettingsConcurrencyTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings.makeForTesting(defaults: defaults)
        let writes = TestCounter()

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<50 {
                group.addTask {
                    settings.provider = index.isMultiple(of: 2) ? .whisper : .parakeet
                    await writes.increment()
                }
            }
        }

        let writeCount = await writes.getCount()
        let finalProvider = settings.provider
        XCTAssertEqual(writeCount, 50)
        XCTAssertEqual(defaults.string(forKey: "asrProvider"), finalProvider.rawValue)
    }
}
