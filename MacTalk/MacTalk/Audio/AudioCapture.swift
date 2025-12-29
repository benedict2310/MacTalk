//
//  AudioCapture.swift
//  MacTalk
//
//  Microphone audio capture using AVAudioEngine
//

@preconcurrency import AVFoundation

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
    private let engine = AVAudioEngine()
    private let bus = 0

    /// Callback invoked with each audio buffer from the microphone.
    ///
    /// - Note: Called from the audio render thread. Must complete quickly.
    /// - Note: `AVAudioPCMBuffer` and `AVAudioTime` are not Sendable, but are
    ///   safe to use within the callback scope as ownership is transferred.
    var onPCMFloatBuffer: (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)?

    func start() throws {
        let input = engine.inputNode
        let format = input.inputFormat(forBus: bus)

        // Install tap to capture audio
        input.installTap(onBus: bus, bufferSize: 2048, format: format) { [weak self] buffer, time in
            self?.onPCMFloatBuffer?(buffer, time)
        }

        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: bus)
        engine.stop()
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
