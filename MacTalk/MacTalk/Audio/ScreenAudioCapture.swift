//
//  ScreenAudioCapture.swift
//  MacTalk
//
//  App/System audio capture via ScreenCaptureKit
//

@preconcurrency import ScreenCaptureKit
@preconcurrency import AVFoundation
@preconcurrency import CoreMedia

extension AudioHostTimestamp {
    /// ScreenCaptureKit audio PTS is already in the host-clock timeline. Keep
    /// it integer and reject invalid/indefinite timestamps rather than using
    /// callback arrival time.
    init?(presentationTimeStamp: CMTime) {
        guard presentationTimeStamp.isNumeric else { return nil }
        let converted = CMTimeConvertScale(
            presentationTimeStamp,
            timescale: 1_000_000_000,
            method: .roundHalfAwayFromZero
        )
        guard converted.isNumeric, let nanos = Int64(exactly: converted.value) else {
            return nil
        }
        self.init(nanoseconds: nanos)
    }
}

/// App/System audio capture via ScreenCaptureKit.
///
/// Every SCStream gets an immutable output adapter. This avoids callback
/// mutation and locking on delivery queues; queued callbacks carry their
/// originating session token and are rejected by the controller gate when
/// they arrive after stop/restart.
final class ScreenAudioCapture: NSObject, @unchecked Sendable {
    private let streamLock = NSLock()
    private var stream: SCStream?
    /// ScreenCaptureKit callbacks for one source must stay ordered because its
    /// resampler is stateful. The adapter still carries its immutable session
    /// token, so queued callbacks remain safe across replacement.
    private let sampleHandlerQueue = DispatchQueue(
        label: "com.mactalk.screen-audio.samples", qos: .userInitiated
    )

    private final class OutputAdapter: NSObject, SCStreamDelegate, SCStreamOutput, @unchecked Sendable {
        let sessionID: UUID
        let onAudioSampleBuffer: @Sendable (UUID, CMSampleBuffer) -> Void
        let onStreamError: @Sendable (UUID, Error) -> Void

        init(
            sessionID: UUID,
            onAudioSampleBuffer: @escaping @Sendable (UUID, CMSampleBuffer) -> Void,
            onStreamError: @escaping @Sendable (UUID, Error) -> Void
        ) {
            self.sessionID = sessionID
            self.onAudioSampleBuffer = onAudioSampleBuffer
            self.onStreamError = onStreamError
        }

        func stream(
            _ stream: SCStream,
            didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
            of outputType: SCStreamOutputType
        ) {
            guard outputType == .audio else { return }
            onAudioSampleBuffer(sessionID, sampleBuffer)
        }

        func stream(_ stream: SCStream, didStopWithError error: Error) {
            onStreamError(sessionID, error)
        }
    }

    func selectFirstWindow(
        named name: String,
        sessionID: UUID,
        onAudioSampleBuffer: @escaping @Sendable (UUID, CMSampleBuffer) -> Void,
        onStreamError: @escaping @Sendable (UUID, Error) -> Void
    ) async throws {
        let content = try await SCShareableContent.current
        guard let app = content.applications.first(where: { $0.applicationName == name }) else {
            throw NSError(domain: "ScreenAudioCapture", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Could not find app named '\(name)'"
            ])
        }
        guard let window = content.windows.first(where: { $0.owningApplication == app }) else {
            throw NSError(domain: "ScreenAudioCapture", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "App '\(name)' has no windows"
            ])
        }
        try await startCapture(
            filter: SCContentFilter(desktopIndependentWindow: window),
            sessionID: sessionID,
            onAudioSampleBuffer: onAudioSampleBuffer,
            onStreamError: onStreamError
        )
    }

    func selectApp(
        app: SCRunningApplication,
        sessionID: UUID,
        onAudioSampleBuffer: @escaping @Sendable (UUID, CMSampleBuffer) -> Void,
        onStreamError: @escaping @Sendable (UUID, Error) -> Void
    ) async throws {
        let content = try await SCShareableContent.current
        guard let window = content.windows.first(where: { $0.owningApplication == app }) else {
            throw NSError(domain: "ScreenAudioCapture", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "App '\(app.applicationName)' has no windows"
            ])
        }
        try await startCapture(
            filter: SCContentFilter(desktopIndependentWindow: window),
            sessionID: sessionID,
            onAudioSampleBuffer: onAudioSampleBuffer,
            onStreamError: onStreamError
        )
    }

    func selectDisplay(
        display: SCDisplay,
        sessionID: UUID,
        onAudioSampleBuffer: @escaping @Sendable (UUID, CMSampleBuffer) -> Void,
        onStreamError: @escaping @Sendable (UUID, Error) -> Void
    ) async throws {
        try await startCapture(
            filter: SCContentFilter(display: display, excludingWindows: []),
            sessionID: sessionID,
            onAudioSampleBuffer: onAudioSampleBuffer,
            onStreamError: onStreamError
        )
    }

    func selectDisplay(
        sessionID: UUID,
        onAudioSampleBuffer: @escaping @Sendable (UUID, CMSampleBuffer) -> Void,
        onStreamError: @escaping @Sendable (UUID, Error) -> Void
    ) async throws {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            throw NSError(domain: "ScreenAudioCapture", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "No displays found"
            ])
        }
        try await startCapture(
            filter: SCContentFilter(display: display, excludingWindows: []),
            sessionID: sessionID,
            onAudioSampleBuffer: onAudioSampleBuffer,
            onStreamError: onStreamError
        )
    }

    private func startCapture(
        filter: SCContentFilter,
        sessionID: UUID,
        onAudioSampleBuffer: @escaping @Sendable (UUID, CMSampleBuffer) -> Void,
        onStreamError: @escaping @Sendable (UUID, Error) -> Void
    ) async throws {
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.queueDepth = 8

        let adapter = OutputAdapter(
            sessionID: sessionID,
            onAudioSampleBuffer: onAudioSampleBuffer,
            onStreamError: onStreamError
        )
        let stream = SCStream(filter: filter, configuration: config, delegate: adapter)
        let previousStream = streamLock.withLock {
            let previousStream = self.stream
            self.stream = stream
            return previousStream
        }
        stopCapture(previousStream)

        do {
            try stream.addStreamOutput(
                adapter,
                type: .audio,
                sampleHandlerQueue: sampleHandlerQueue
            )

            let stillCurrent = streamLock.withLock { self.stream === stream }
            guard stillCurrent else {
                stopCapture(stream)
                return
            }

            try await stream.startCapture()
        } catch {
            let shouldStop = streamLock.withLock { () -> Bool in
                guard self.stream === stream else { return false }
                self.stream = nil
                return true
            }
            if shouldStop { stopCapture(stream) }
            throw error
        }

        // A stop or replacement may have happened while startCapture awaited.
        if !streamLock.withLock({ self.stream === stream }) {
            stopCapture(stream)
        }
    }

    func stop() {
        let stream = streamLock.withLock {
            let stream = self.stream
            self.stream = nil
            return stream
        }
        stopCapture(stream)
    }

    private func stopCapture(_ stream: SCStream?) {
        guard let stream else { return }
        Task {
            try? await stream.stopCapture()
        }
    }

    deinit {
        stop()
    }
}
