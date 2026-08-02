//
//  ConcurrencyStressTests.swift
//  MacTalkTests
//
//  Focused regression tests for production synchronization boundaries.
//

import XCTest
@preconcurrency import AVFoundation
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
        XCTAssertEqual(frame?.frame.firstSampleHostTime, 1)

        let timestamped = OwnedAudioRing(slotCount: 3, maxFrames: 4)
        XCTAssertTrue(timestamped.push(
            buffer: source,
            sampleRate: 48_000,
            sessionID: staleSession,
            firstSampleHostTime: 987_654_321
        ))
        XCTAssertEqual(timestamped.pop()?.frame.firstSampleHostTime, 987_654_321)
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

    func test_defaultAudioCaptureUsesAppleSafeTapBufferCapacity() {
        XCTAssertEqual(AudioCapture.defaultMaxFramesPerBuffer, 8_192)
    }

    func test_audioCaptureCoalescesScheduledDrainsAndDropsNewestWhenDeliveryIsBlocked() {
        let scheduler = ManualDrainScheduler()
        let delivered = LockedValue<[Float]>([])
        let coordinator = AudioCaptureDeliveryCoordinator(
            slotCount: 3,
            maxFramesPerBuffer: 4,
            schedule: scheduler.schedule,
            delivery: { _, frame in
                delivered.withValue { $0.append(frame.samples[0]) }
            }
        )

        for index in 0..<20 {
            let source = makeConstantPCMBuffer(
                sampleRate: 48_000, channels: 1, frameCount: 4, value: Float(index)
            )
            _ = coordinator.push(buffer: source, sampleRate: 48_000, sessionID: UUID())
        }

        XCTAssertEqual(scheduler.scheduledCount, 1)
        XCTAssertEqual(scheduler.pendingCount, 1)
        XCTAssertEqual(coordinator.droppedBufferCount, 18)
        XCTAssertTrue(delivered.value.isEmpty)

        scheduler.runNext()

        XCTAssertEqual(delivered.value, [0, 1])
        XCTAssertEqual(scheduler.scheduledCount, 1)
        XCTAssertEqual(scheduler.pendingCount, 0)

        let followUp = makeConstantPCMBuffer(sampleRate: 48_000, channels: 1, frameCount: 4)
        _ = coordinator.push(buffer: followUp, sampleRate: 48_000, sessionID: UUID())
        XCTAssertEqual(scheduler.scheduledCount, 2)
        XCTAssertEqual(scheduler.pendingCount, 1)
    }

    func test_invalidMicrophoneHostTimeIsDropped() {
        let scheduler = ManualDrainScheduler()
        let coordinator = AudioCaptureDeliveryCoordinator(
            slotCount: 3,
            maxFramesPerBuffer: 4,
            schedule: scheduler.schedule,
            delivery: { _, _ in XCTFail("invalid timestamp must not be delivered") }
        )
        let source = makeConstantPCMBuffer(sampleRate: 16_000, channels: 1, frameCount: 4)
        XCTAssertFalse(coordinator.push(
            buffer: source,
            sampleRate: 16_000,
            sessionID: UUID(),
            firstSampleHostTime: 0
        ))
        XCTAssertEqual(coordinator.droppedBufferCount, 1)
    }

    func test_audioCaptureDrainDoesNotLoseBufferEnqueuedDuringDelivery() {
        let scheduler = ManualDrainScheduler()
        let source = SendableAudioBuffer(
            makeConstantPCMBuffer(sampleRate: 48_000, channels: 1, frameCount: 4)
        )
        let coordinatorBox = LockedValue<AudioCaptureDeliveryCoordinator?>(nil)
        let didEnqueueDuringDelivery = LockedValue(false)
        let enqueueSucceeded = LockedValue(false)
        let coordinator = AudioCaptureDeliveryCoordinator(
            slotCount: 4,
            maxFramesPerBuffer: 4,
            schedule: scheduler.schedule,
            delivery: { _, _ in
                if !didEnqueueDuringDelivery.value {
                    didEnqueueDuringDelivery.withValue { $0 = true }
                    let succeeded = coordinatorBox.value!.push(
                        buffer: source.value, sampleRate: 48_000, sessionID: UUID()
                    )
                    enqueueSucceeded.withValue { $0 = succeeded }
                }
            }
        )
        coordinatorBox.withValue { $0 = coordinator }

        XCTAssertTrue(coordinator.push(buffer: source.value, sampleRate: 48_000, sessionID: UUID()))
        scheduler.runNext()

        XCTAssertTrue(didEnqueueDuringDelivery.value)
        XCTAssertTrue(enqueueSucceeded.value)
        XCTAssertEqual(scheduler.scheduledCount, 1)
        XCTAssertEqual(scheduler.pendingCount, 0)
        XCTAssertEqual(coordinator.droppedBufferCount, 0)
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

private final class SendableAudioBuffer: @unchecked Sendable {
    let value: AVAudioPCMBuffer

    init(_ value: AVAudioPCMBuffer) {
        self.value = value
    }
}

private final class ManualDrainScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [@Sendable () -> Void] = []
    private(set) var scheduledCount = 0

    var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pending.count
    }

    func schedule(_ work: @escaping @Sendable () -> Void) {
        lock.lock()
        scheduledCount += 1
        pending.append(work)
        lock.unlock()
    }

    func runNext() {
        lock.lock()
        let work = pending.removeFirst()
        lock.unlock()
        work()
    }
}

private final class LockedValue<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T

    init(_ value: T) {
        storage = value
    }

    var value: T {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func withValue(_ update: (inout T) -> Void) {
        lock.lock()
        update(&storage)
        lock.unlock()
    }
}
