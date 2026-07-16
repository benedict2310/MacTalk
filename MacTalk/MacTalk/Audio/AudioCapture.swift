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
/// - The callback closure is only set during setup, before concurrent usage
/// - The tap callback safely passes audio buffers to the handler
///
/// ## Audio Callback
/// The `onPCMFloatBuffer` callback is invoked from the audio render thread
/// (high-priority real-time thread). Handlers must complete quickly and
/// avoid blocking operations.
final class AudioCapture: NSObject, @unchecked Sendable {
    private struct CallbackState {
        var callback: (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)?
    }

    private let engine = AVAudioEngine()
    private let bus = 0
    private let callbackState = OSAllocatedUnfairLock(initialState: CallbackState())
    private let lifecycleLock = NSLock()
    private var isRunning = false

    /// Callback invoked with each audio buffer from the microphone.
    ///
    /// - Note: Called from the audio render thread. Must complete quickly.
    /// - Note: `AVAudioPCMBuffer` and `AVAudioTime` are not Sendable, but are
    ///   safe to use within the callback scope as ownership is transferred.
    var onPCMFloatBuffer: (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)? {
        get { callbackState.withLock { $0.callback } }
        set { callbackState.withLock { $0.callback = newValue } }
    }

    func start() throws {
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

        input.installTap(onBus: bus, bufferSize: 2048, format: format) { [weak self] buffer, time in
            let callback = self?.callbackState.withLock { $0.callback }
            callback?(buffer, time)
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
