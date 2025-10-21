//
//  AudioMixer.swift
//  MacTalk
//
//  Audio format conversion and downmixing to 16kHz mono float32
//

import AVFoundation
import CoreMedia

final class AudioMixer {
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16000,
        channels: 1,
        interleaved: false
    )!

    private var converter: AVAudioConverter?
    private var lastInputFormat: AVAudioFormat?

    init() {}

    /// Convert an AVAudioPCMBuffer to 16kHz mono float32 array
    func convert(buffer: AVAudioPCMBuffer) -> [Float]? {
        // Create or update converter if format changed
        if lastInputFormat == nil || lastInputFormat != buffer.format {
            guard let newConverter = AVAudioConverter(from: buffer.format, to: targetFormat) else {
                print("Failed to create audio converter")
                return nil
            }
            converter = newConverter
            lastInputFormat = buffer.format
        }

        guard let converter = converter else { return nil }

        // Calculate output buffer size
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio)

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputFrameCapacity
        ) else {
            print("Failed to create output buffer")
            return nil
        }

        var error: NSError?
        var inputConsumed = false

        let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        let status = converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)

        guard status != .error, error == nil else {
            print("Audio conversion error: \(error?.localizedDescription ?? "unknown")")
            return nil
        }

        // Extract float samples from first channel
        guard let channelData = outputBuffer.floatChannelData else { return nil }
        let samples = Array(UnsafeBufferPointer(
            start: channelData[0],
            count: Int(outputBuffer.frameLength)
        ))

        return samples
    }

    /// Convert CMSampleBuffer (from ScreenCaptureKit) to float array
    func convertSampleBuffer(_ sampleBuffer: CMSampleBuffer) -> [Float]? {
        guard let pcmBuffer = sampleBuffer.makePCMBuffer() else {
            return nil
        }
        return convert(buffer: pcmBuffer)
    }
}

// MARK: - CMSampleBuffer Helpers

extension CMSampleBuffer {
    func makePCMBuffer() -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(self) else {
            return nil
        }

        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee
        guard let streamDescription = asbd else { return nil }

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: streamDescription.mSampleRate,
            channels: streamDescription.mChannelsPerFrame,
            interleaved: false
        ) else {
            return nil
        }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(self) else {
            return nil
        }

        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?

        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &length,
            dataPointerOut: &dataPointer
        )

        guard status == kCMBlockBufferNoErr, let data = dataPointer else {
            return nil
        }

        let frameCount = UInt32(length) / UInt32(streamDescription.mBytesPerFrame)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }

        buffer.frameLength = frameCount

        // Copy audio data
        if let channelData = buffer.floatChannelData {
            let byteCount = Int(frameCount) * MemoryLayout<Float>.size
            memcpy(channelData[0], data, byteCount)
        }

        return buffer
    }
}
