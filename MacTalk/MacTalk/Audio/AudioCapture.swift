//
//  AudioCapture.swift
//  MacTalk
//
//  Microphone audio capture using AVAudioEngine
//

@preconcurrency import AVFoundation
import os

/// Microphone audio capture using AVAudioEngine.
///
/// ## Thread Safety
/// This class is marked `@unchecked Sendable` because:
/// - `AVAudioEngine` is documented as thread-safe by Apple
/// - Each tap captures an immutable, session-scoped callback at start time
/// - The tap callback safely passes audio buffers to the handler
///
/// ## Audio Callback
/// The `onPCMFloatBuffer` callback is invoked from the audio render thread
/// (high-priority real-time thread). Handlers must complete quickly and
/// avoid blocking operations.
final class AudioCapture: NSObject, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let bus = 0
    private let lifecycleLock = NSLock()
    private var isRunning = false

    /// Starts a capture session with an immutable callback registration.
    ///
    /// The callback is captured by the tap closure before the engine starts;
    /// the render thread never reads mutable callback storage or takes a lock.
    /// The session token is forwarded unchanged so the consumer can reject
    /// callbacks queued after stop or restart.
    func start(
        sessionID: UUID,
        onPCMFloatBuffer: @escaping @Sendable (UUID, AVAudioPCMBuffer, AVAudioTime) -> Void
    ) throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard !isRunning else { return }
        isRunning = true

        // Reset the graph left by the previous recording before reinstalling
        // the tap. Without this, a restarted AVAudioEngine can report itself as
        // running while delivering no input buffers.
        engine.reset()
        let input = engine.inputNode
        let format = input.inputFormat(forBus: bus)

        input.installTap(onBus: bus, bufferSize: 2048, format: format) { buffer, time in
            onPCMFloatBuffer(sessionID, buffer, time)
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

        engine.inputNode.removeTap(onBus: bus)
        engine.stop()
        engine.reset()
        isRunning = false
    }

    func getCurrentLevel() -> Float {
        // Simple RMS level calculation for the input
        // This can be enhanced with a dedicated level monitor
        return engine.inputNode.volume
    }

    deinit {
        stop()
    }
}
