//
//  AudioMixer.swift
//  MacTalk
//
//  Audio format conversion and downmixing to 16kHz mono float32
//

@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
import Foundation

/// Audio format conversion and downmixing to the app's 16 kHz mono format.
final class AudioMixer: Sendable {
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16000,
        channels: 1,
        interleaved: false
    )!

    init() {}

    /// Creates an independently stateful converter for one audio source.
    ///
    /// A stream must not be shared by unrelated sources: its resampling phase
    /// belongs to the input sequence supplied to it. `Stream` serializes calls,
    /// so audio callbacks may safely hand buffers to their own source stream.
    func makeStream() -> Stream {
        Stream(targetFormat: targetFormat)
    }

    /// Convert one independent buffer to 16 kHz mono float32.
    ///
    /// This API is intentionally stateless. It ends the converter after this
    /// buffer and is therefore appropriate for standalone buffers, not for
    /// concatenating arbitrary chunks from a continuous source. Use
    /// ``makeStream()`` for microphone or app-audio callback sequences.
    func convert(buffer: AVAudioPCMBuffer) -> [Float]? {
        guard buffer.frameLength > 0 else { return [] }
        guard let inputBuffer = Self.makeMonoBuffer(from: buffer),
              let converter = AVAudioConverter(from: inputBuffer.format, to: targetFormat) else {
            DebugLogger.shared.log(.operationFailed)
            return nil
        }
        return Self.convert(inputBuffer: inputBuffer, converter: converter, endOfStream: true)
    }

    /// A serialized, stateful converter for one continuous source.
    final class Stream: @unchecked Sendable {
        private let targetFormat: AVAudioFormat
        private let lock = NSLock()
        private var converter: AVAudioConverter?
        private var inputFormat: AVAudioFormat?

        fileprivate init(targetFormat: AVAudioFormat) {
            self.targetFormat = targetFormat
        }

        /// Converts the next buffer in this stream, preserving resampling phase.
        func convert(buffer: AVAudioPCMBuffer) -> [Float]? {
            lock.lock()
            defer { lock.unlock() }
            return convertLocked(buffer: buffer)
        }

        /// Converts owned mono samples after the capture handoff. Buffer
        /// creation occurs on the worker, never on the audio render thread.
        func convert(samples: [Float], sampleRate: Double) -> [Float]? {
            guard !samples.isEmpty,
                  let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                              sampleRate: sampleRate,
                                              channels: 1,
                                              interleaved: false),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                                frameCapacity: AVAudioFrameCount(samples.count)),
                  let destination = buffer.floatChannelData?[0] else { return [] }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { source in
                destination.update(from: source.baseAddress!, count: samples.count)
            }
            return convert(buffer: buffer)
        }

        private func convertLocked(buffer: AVAudioPCMBuffer) -> [Float]? {
            guard buffer.frameLength > 0 else { return [] }
            guard let inputBuffer = AudioMixer.makeMonoBuffer(from: buffer) else { return nil }

            if converter == nil || inputFormat?.isEqual(inputBuffer.format) != true {
                guard let newConverter = AVAudioConverter(from: inputBuffer.format, to: targetFormat) else {
                    DebugLogger.shared.log(.operationFailed)
                    return nil
                }
                converter = newConverter
                inputFormat = inputBuffer.format
            }

            guard let converter else { return nil }
            return AudioMixer.convert(inputBuffer: inputBuffer, converter: converter, endOfStream: false)
        }

        /// Drains converter latency at the end of this source sequence.
        /// The stream is reset and can then be reused for a new sequence.
        func finish() -> [Float]? {
            lock.lock()
            defer { lock.unlock() }
            guard let converter else { return [] }
            let samples = AudioMixer.convert(
                inputBuffer: nil,
                converter: converter,
                endOfStream: true
            )
            converter.reset()
            self.converter = nil
            inputFormat = nil
            return samples
        }

        /// Starts a fresh source sequence while retaining this stream object.
        func reset() {
            lock.lock()
            converter?.reset()
            converter = nil
            inputFormat = nil
            lock.unlock()
        }
    }

    private static func convert(
        inputBuffer: AVAudioPCMBuffer?,
        converter: AVAudioConverter,
        endOfStream: Bool
    ) -> [Float]? {
        let targetFormat = converter.outputFormat
        let inputFormat = inputBuffer?.format ?? converter.inputFormat
        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let expectedFrames = Double(inputBuffer?.frameLength ?? 0) * ratio
        let outputFrameCapacity = AVAudioFrameCount(max(1024, ceil(expectedFrames) + 1024))
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputFrameCapacity
        ) else {
            DebugLogger.shared.log(.operationFailed)
            return nil
        }

        var error: NSError?
        nonisolated(unsafe) var inputConsumed = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            guard !inputConsumed, let inputBuffer else {
                outStatus.pointee = endOfStream ? .endOfStream : .noDataNow
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        let status = converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)
        guard status != .error, error == nil else {
            DebugLogger.shared.log(.operationFailed)
            return nil
        }

        guard let channelData = outputBuffer.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(
            start: channelData[0],
            count: Int(outputBuffer.frameLength)
        ))
    }

    private static func makeMonoBuffer(from buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
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

    /// Convert CMSampleBuffer (from ScreenCaptureKit) to float array.
    func convertSampleBuffer(_ sampleBuffer: CMSampleBuffer) -> [Float]? {
        guard let pcmBuffer = sampleBuffer.makePCMBuffer() else { return nil }
        return convert(buffer: pcmBuffer)
    }

    /// Convert a CMSampleBuffer using a continuous source stream.
    func convertSampleBuffer(_ sampleBuffer: CMSampleBuffer, using stream: Stream) -> [Float]? {
        guard let pcmBuffer = sampleBuffer.makePCMBuffer() else { return nil }
        return stream.convert(buffer: pcmBuffer)
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
        let framesPerPacket = UInt64(streamDescription.mFramesPerPacket)
        let bytesPerPacket = UInt64(bytesPerFrame) * framesPerPacket

        // The source data must describe packed Float32 PCM. Reject layouts whose
        // stride does not match the layout flags instead of copying one channel
        // and silently corrupting stereo audio. Packet metadata is validated too,
        // so a malformed or unsupported layout cannot make us reinterpret bytes
        // as a different number of channels or frames.
        guard streamDescription.mFramesPerPacket > 0,
              bytesPerPacket <= UInt64(UInt32.max),
              streamDescription.mBytesPerFrame == UInt32(bytesPerFrame),
              streamDescription.mBytesPerPacket == UInt32(bytesPerPacket),
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
