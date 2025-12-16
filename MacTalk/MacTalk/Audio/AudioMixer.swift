//
//  AudioMixer.swift
//  MacTalk
//
//  Audio format conversion and downmixing to 16kHz mono float32
//

@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
import os

/// Thread-safe audio format converter.
///
/// ## Thread Safety
/// This class uses `OSAllocatedUnfairLock` to protect the converter cache,
/// preventing data races when called from multiple audio threads (mic + app audio).
///
/// ## Sendable Conformance
/// Marked `@unchecked Sendable` because:
/// - The converter cache is protected by `OSAllocatedUnfairLock`
/// - `targetFormat` is immutable after initialization
/// - AVAudioConverter instances are thread-safe for conversion operations
final class AudioMixer: @unchecked Sendable {
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16000,
        channels: 1,
        interleaved: false
    )!

    /// Cache of converters keyed by input format's ObjectIdentifier.
    /// Protected by OSAllocatedUnfairLock for thread-safe access.
    private let converterCache = OSAllocatedUnfairLock<[ObjectIdentifier: AVAudioConverter]>(
        initialState: [:]
    )

    init() {}

    /// Convert an AVAudioPCMBuffer to 16kHz mono float32 array
    func convert(buffer: AVAudioPCMBuffer) -> [Float]? {
        // Get or create converter for this format (thread-safe)
        let formatID = ObjectIdentifier(buffer.format)

        let converter: AVAudioConverter? = converterCache.withLock { cache in
            if let existing = cache[formatID] {
                return existing
            }
            guard let newConverter = AVAudioConverter(from: buffer.format, to: targetFormat) else {
                print("Failed to create audio converter")
                return nil
            }
            cache[formatID] = newConverter
            return newConverter
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
