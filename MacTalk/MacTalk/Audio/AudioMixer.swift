//
//  AudioMixer.swift
//  MacTalk
//
//  Audio format conversion and downmixing to 16kHz mono float32
//

@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
/// Audio format converter.
///
/// Each call is a complete, stateless conversion of one input buffer. A fresh
/// `AVAudioConverter` is used for every call so microphone and app-audio
/// callbacks cannot share converter state or race while draining it. Callers
/// that need stream continuity should pass buffers from one source in order;
/// output from separate calls can then be concatenated without frame loss.
final class AudioMixer: Sendable {
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16000,
        channels: 1,
        interleaved: false
    )!

    init() {}

    /// Convert an AVAudioPCMBuffer to 16kHz mono float32 array.
    ///
    /// Empty input is intentionally represented as a non-nil empty array. The
    /// converter receives `.endOfStream` after the one input buffer, allowing
    /// it to emit all pending resampler frames before the call returns.
    func convert(buffer: AVAudioPCMBuffer) -> [Float]? {
        guard buffer.frameLength > 0 else { return [] }

        guard let inputBuffer = makeMonoBuffer(from: buffer),
              let converter = AVAudioConverter(from: inputBuffer.format, to: targetFormat) else {
            DebugLogger.shared.log(.error(description: "Failed to create audio converter"))
            return nil
        }

        // Leave room for converter priming/trailing frames. The returned frame
        // length is still determined by AVAudioConverter, not this capacity.
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let expectedFrames = Double(buffer.frameLength) * ratio
        let outputFrameCapacity = AVAudioFrameCount(ceil(expectedFrames) + 1024)
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputFrameCapacity
        ) else {
            DebugLogger.shared.log(.error(description: "Failed to create output buffer"))
            return nil
        }

        var error: NSError?
        nonisolated(unsafe) var inputConsumed = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            guard !inputConsumed else {
                outStatus.pointee = .endOfStream
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        let status = converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)
        guard status != .error, error == nil else {
            DebugLogger.shared.log(.error(description: error?.localizedDescription ?? "unknown"))
            return nil
        }

        guard let channelData = outputBuffer.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(
            start: channelData[0],
            count: Int(outputBuffer.frameLength)
        ))
    }

    private func makeMonoBuffer(from buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.format.channelCount > 1 else { return buffer }
        guard let source = buffer.floatChannelData else { return nil }

        let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: buffer.format.sampleRate,
            channels: 1,
            interleaved: false
        )!
        guard let monoBuffer = AVAudioPCMBuffer(
            pcmFormat: monoFormat,
            frameCapacity: buffer.frameLength
        ), let destination = monoBuffer.floatChannelData?[0] else {
            return nil
        }

        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        for frame in 0..<frameCount {
            var sum: Float = 0
            for channel in 0..<channelCount {
                sum += source[channel][frame]
            }
            destination[frame] = sum / Float(channelCount)
        }
        monoBuffer.frameLength = buffer.frameLength
        return monoBuffer
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
