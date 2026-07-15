//
//  TestHelpers.swift
//  MacTalkTests
//
//  Small deterministic helpers shared by behavior-focused tests.
//

@preconcurrency import AVFoundation

func makeConstantPCMBuffer(
    sampleRate: Double,
    channels: AVAudioChannelCount,
    frameCount: AVAudioFrameCount,
    value: Float = 0.25
) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: channels,
        interleaved: false
    )!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
    buffer.frameLength = frameCount

    if let channelData = buffer.floatChannelData {
        for channel in 0..<Int(channels) {
            for frame in 0..<Int(frameCount) {
                channelData[channel][frame] = value
            }
        }
    }
    return buffer
}

actor TestCounter {
    private var count = 0

    func increment() {
        count += 1
    }

    func getCount() -> Int {
        count
    }
}
