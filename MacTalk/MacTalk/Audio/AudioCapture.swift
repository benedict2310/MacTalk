//
//  AudioCapture.swift
//  MacTalk
//
//  Microphone audio capture using AVAudioEngine
//

@preconcurrency import AVFoundation
import Synchronization
import os

/// Owned microphone audio handed off after the tap returns.
///
/// `samples` is copied from the tap's memory into a bounded SPSC queue before
/// the render callback returns. Consumers therefore never retain or inspect
/// AVAudioPCMBuffer/AVAudioTime owned by AVAudioEngine. If the queue is full,
/// the newest buffer is dropped (and `droppedBufferCount` is incremented).
struct AudioCaptureFrame: Sendable, Equatable {
    let samples: [Float]
    let sampleRate: Double
}

/// Microphone audio capture using AVAudioEngine.
///
/// The render callback performs only a bounded slot check and a copy into
/// preallocated storage. It never locks, allocates, or invokes client code.
/// A serial worker drains owned frames through the injectable `schedule`
/// seam. The default scheduler is a serial user-initiated queue.
final class AudioCapture: NSObject, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let bus = 0
    private let lifecycleLock = NSLock()
    private let schedule: @Sendable (@escaping @Sendable () -> Void) -> Void
    private static let defaultDeliveryQueue = DispatchQueue(
        label: "com.mactalk.audio-capture.delivery", qos: .userInitiated
    )
    private let queue: OwnedAudioRing
    private var isRunning = false

    init(
        slotCount: Int = 8,
        maxFramesPerBuffer: Int = 2048,
        schedule: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void = { work in
            AudioCapture.defaultDeliveryQueue.async(execute: work)
        }
    ) {
        self.queue = OwnedAudioRing(slotCount: slotCount, maxFrames: maxFramesPerBuffer)
        self.schedule = schedule
        super.init()
    }

    /// Starts a capture session with immutable callback registration.
    /// Delivery receives only owned Swift values, never tap-owned AVFoundation
    /// objects. Calling `start` while running is a no-op.
    func start(
        sessionID: UUID,
        onPCMFloatBuffer: @escaping @Sendable (UUID, AudioCaptureFrame) -> Void
    ) throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard !isRunning else { return }
        isRunning = true

        engine.reset()
        let input = engine.inputNode
        let format = input.inputFormat(forBus: bus)
        let sampleRate = format.sampleRate

        input.installTap(onBus: bus, bufferSize: AVAudioFrameCount(queue.maxFrames), format: format) {
            [weak self] buffer, _ in
            guard let self else { return }
            // This is the complete render-thread handoff. No AVAudio object is
            // captured by the scheduled work and no lock/alloc occurs here.
            guard self.queue.push(buffer: buffer, sampleRate: sampleRate, sessionID: sessionID) else { return }
            self.schedule { [weak self] in self?.drain(delivery: onPCMFloatBuffer) }
        }
        engine.prepare()

        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: bus)
            engine.reset()
            isRunning = false
            throw error
        }
    }

    func stop() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard isRunning else { return }
        isRunning = false
        engine.inputNode.removeTap(onBus: bus)
        engine.stop()
        engine.reset()
    }

    var droppedBufferCount: UInt64 { queue.droppedCount }

    private func drain(delivery: @escaping @Sendable (UUID, AudioCaptureFrame) -> Void) {
        while let item = queue.pop() {
            delivery(item.sessionID, item.frame)
        }
    }

    func getCurrentLevel() -> Float {
        engine.inputNode.volume
    }

    deinit { stop() }
}

/// Single-producer/single-consumer bounded handoff. The producer is the audio
/// render callback; the consumer is the serial delivery worker. The queue's
/// policy is drop-newest on full, preserving already queued audio and keeping
/// render-time work bounded and nonblocking.
final class OwnedAudioRing: @unchecked Sendable {
    private final class Slot {
        let samples: UnsafeMutableBufferPointer<Float>
        var count = 0
        var sampleRate = 0.0
        var sessionID = UUID()

        init(capacity: Int) {
            samples = .allocate(capacity: capacity)
            samples.initialize(repeating: 0)
        }
        deinit {
            samples.deinitialize()
            samples.deallocate()
        }
    }

    let maxFrames: Int
    private let slots: [Slot]
    private let producerIndex = Atomic<Int>(0)
    private let consumerIndex = Atomic<Int>(0)
    private let dropped = Atomic<UInt64>(0)

    init(slotCount: Int, maxFrames: Int) {
        precondition(slotCount > 1 && maxFrames > 0)
        self.maxFrames = maxFrames
        slots = (0..<slotCount).map { _ in Slot(capacity: maxFrames) }
    }

    var droppedCount: UInt64 { dropped.load(ordering: .acquiring) }

    /// Called only by the render thread. AVAudioPCMBuffer is read only here.
    func push(buffer: AVAudioPCMBuffer, sampleRate: Double, sessionID: UUID = UUID()) -> Bool {
        let count = Int(buffer.frameLength)
        guard count > 0, count <= maxFrames, let channels = buffer.floatChannelData else {
            dropped.wrappingAdd(1, ordering: .relaxed)
            return false
        }
        let producer = producerIndex.load(ordering: .relaxed)
        let next = (producer + 1) % slots.count
        guard next != consumerIndex.load(ordering: .acquiring) else {
            dropped.wrappingAdd(1, ordering: .relaxed)
            return false
        }
        let slot = slots[producer]
        let channelCount = Int(buffer.format.channelCount)
        for frame in 0..<count {
            var value: Float = 0
            for channel in 0..<channelCount { value += channels[channel][frame] }
            slot.samples[frame] = value / Float(channelCount)
        }
        slot.count = count
        slot.sampleRate = sampleRate
        slot.sessionID = sessionID
        producerIndex.store(next, ordering: .releasing)
        return true
    }

    typealias Item = (sessionID: UUID, frame: AudioCaptureFrame)

    /// Called only by the serial worker.
    func pop() -> Item? {
        let consumer = consumerIndex.load(ordering: .relaxed)
        guard consumer != producerIndex.load(ordering: .acquiring) else { return nil }
        let slot = slots[consumer]
        let frame = AudioCaptureFrame(
            samples: Array(UnsafeBufferPointer(start: slot.samples.baseAddress, count: slot.count)),
            sampleRate: slot.sampleRate
        )
        let sessionID = slot.sessionID
        consumerIndex.store((consumer + 1) % slots.count, ordering: .releasing)
        return (sessionID, frame)
    }

}
