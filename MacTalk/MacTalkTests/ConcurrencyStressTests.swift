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

    func test_ownedAudioRingCopiesOwnedDataAndDropsNewestWhenFull() {
        let ring = OwnedAudioRing(slotCount: 2, maxFrames: 4)
        let source = makeConstantPCMBuffer(sampleRate: 48_000, channels: 1, frameCount: 4)
        source.floatChannelData![0].initialize(repeating: 0.25, count: 4)

        let staleSession = UUID()
        XCTAssertTrue(ring.push(buffer: source, sampleRate: 48_000, sessionID: staleSession))
        source.floatChannelData![0].initialize(repeating: 0.75, count: 4)
        XCTAssertFalse(ring.push(buffer: source, sampleRate: 48_000))

        let frame = ring.pop()
        XCTAssertEqual(frame?.sessionID, staleSession)
        XCTAssertEqual(frame?.frame.samples, [0.25, 0.25, 0.25, 0.25])
        XCTAssertEqual(frame?.frame.sampleRate, 48_000)
        XCTAssertEqual(ring.droppedCount, 1)
        XCTAssertNil(ring.pop())
    }

    func test_ownedAudioRingBoundedConcurrentProducerConsumerCompletes() async {
        let ring = OwnedAudioRing(slotCount: 8, maxFrames: 16)
        let produced = 500
        let accepted = TestCounter()
        let consumed = TestCounter()
        let producerDone = TestCounter()

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for _ in 0..<produced {
                    let buffer = makeConstantPCMBuffer(sampleRate: 16_000, channels: 1, frameCount: 16)
                    if ring.push(buffer: buffer, sampleRate: 16_000) { await accepted.increment() }
                }
                await producerDone.increment()
            }
            group.addTask {
                while true {
                    if ring.pop() != nil {
                        await consumed.increment()
                    } else if await producerDone.getCount() > 0 {
                        break
                    } else {
                        await Task.yield()
                    }
                }
            }
        }

        let consumedCount = await consumed.getCount()
        let acceptedCount = await accepted.getCount()
        XCTAssertEqual(consumedCount, acceptedCount)
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

}
