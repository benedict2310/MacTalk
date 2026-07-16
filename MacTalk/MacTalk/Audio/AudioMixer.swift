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
        guard let formatDescription = CMSampleBufferGetFormatDescription(self),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee,
              streamDescription.mFormatID == kAudioFormatLinearPCM,
              streamDescription.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              streamDescription.mFormatFlags & kAudioFormatFlagIsPacked != 0,
              streamDescription.mBitsPerChannel == 32,
              streamDescription.mChannelsPerFrame > 0,
              let blockBuffer = CMSampleBufferGetDataBuffer(self) else {
            return nil
        }

        let channelCount = Int(streamDescription.mChannelsPerFrame)
        let bytesPerSample = MemoryLayout<Float>.size
        let isInterleaved = streamDescription.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let bytesPerFrame = isInterleaved ? bytesPerSample * channelCount : bytesPerSample

        // The source data must describe packed Float32 PCM. Reject layouts whose
        // stride does not match the layout flags instead of copying one channel
        // and silently corrupting stereo audio.
        guard streamDescription.mBytesPerFrame == UInt32(bytesPerFrame),
              streamDescription.mBytesPerPacket == UInt32(bytesPerFrame),
              let dataLength = Int(exactly: CMBlockBufferGetDataLength(blockBuffer)),
              dataLength % (bytesPerSample * channelCount) == 0 else {
            return nil
        }

        let frameCount = dataLength / (bytesPerSample * channelCount)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: streamDescription.mSampleRate,
            channels: streamDescription.mChannelsPerFrame,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ), let channelData = buffer.floatChannelData else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)

        // CMSampleBuffer data can be segmented. Copying through CMBlockBuffer
        // preserves the complete payload before interpreting its declared
        // interleaved or planar layout.
        var pcmData = [UInt8](repeating: 0, count: dataLength)
        let copyStatus = pcmData.withUnsafeMutableBytes { destination in
            CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: dataLength,
                destination: destination.baseAddress!
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else { return nil }

        pcmData.withUnsafeBytes { rawBytes in
            let source = rawBytes.bindMemory(to: Float.self)
            for channel in 0..<channelCount {
                let destination = channelData[channel]
                for frame in 0..<frameCount {
                    let sourceIndex = isInterleaved
                        ? frame * channelCount + channel
                        : channel * frameCount + frame
                    destination[frame] = source[sourceIndex]
                }
            }
        }

        return buffer
    }
}
