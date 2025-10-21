//
//  AudioCapture.swift
//  MacTalk
//
//  Microphone audio capture using AVAudioEngine
//

import AVFoundation

final class AudioCapture: NSObject {
    private let engine = AVAudioEngine()
    private let bus = 0

    var onPCMFloatBuffer: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?

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
