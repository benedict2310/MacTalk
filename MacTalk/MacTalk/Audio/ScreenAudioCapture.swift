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

struct ScreenAudioCaptureSession<Stream: AnyObject, Output: AnyObject> {
    let stream: Stream
    let output: Output
}

/// The platform-independent boundary for ScreenCaptureKit lifecycle tests.
/// Discovery and stream construction are deliberately one async operation;
/// this lets a driver suspend at discovery while the owner retires the exact
/// generation synchronously.
protocol ScreenCaptureStreamDriver: AnyObject, Sendable {
    associatedtype Stream: AnyObject & Sendable
    associatedtype Request: Sendable

    func makeStream(
        for request: Request,
        sessionID: UUID,
        onAudioSampleBuffer: @escaping @Sendable (UUID, CMSampleBuffer) -> Void,
        onStreamError: @escaping @Sendable (UUID, Error) -> Void
    ) async throws -> Stream
    func startCapture(_ stream: Stream) async throws
    func stopCapture(_ stream: Stream) async throws
}

/// Owns one start task and every stream produced by that task. `requestStop`
/// only performs synchronous retirement bookkeeping and may be called from a
/// callback/hot path. `stopAndWait` is the durable async boundary used by
/// replacement and explicit cleanup.
final class ScreenCaptureLifecycle<Driver: ScreenCaptureStreamDriver>: @unchecked Sendable {
    private final class Operation: @unchecked Sendable {
        let generation: UInt64
        let sessionID: UUID
        var retired = false
        var stream: Driver.Stream?
        var startTask: Task<Void, Error>?
        var stopTask: Task<Void, Never>?
        var active = false

        init(generation: UInt64, sessionID: UUID) {
            self.generation = generation
            self.sessionID = sessionID
        }
    }

    private let driver: Driver
    private let lock = NSLock()
    private var nextGeneration: UInt64 = 0
    private var current: Operation?

    init(driver: Driver) {
        self.driver = driver
    }

    var hasActiveStream: Bool {
        lock.withLock { current?.active == true && current?.retired == false }
    }

    func start(
        request: Driver.Request,
        sessionID: UUID,
        onAudioSampleBuffer: @escaping @Sendable (UUID, CMSampleBuffer) -> Void,
        onStreamError: @escaping @Sendable (UUID, Error) -> Void
    ) async throws {
        let (operation, previous) = reserveOperation(sessionID: sessionID)
        if let previous {
            issueStopIfStreamExists(previous)
            await awaitRetirement(previous)
        }
        guard lock.withLock({ current === operation && !operation.retired }) else {
            throw CancellationError()
        }

        let task = Task { [self] in
            try await run(
                operation,
                request: request,
                sessionID: sessionID,
                onAudioSampleBuffer: onAudioSampleBuffer,
                onStreamError: onStreamError
            )
        }
        lock.withLock { operation.startTask = task }

        do {
            try await task.value
        } catch {
            await stopIfNeeded(operation)
            clearIfCurrent(operation)
            throw error
        }
    }

    /// Retires the current generation before any await. A late discovery
    /// continuation therefore cannot publish a stream as active.
    func requestStop() {
        guard let operation = retireCurrent() else { return }
        issueStopIfStreamExists(operation)
    }

    /// Waits for the retired start task, then waits for the one and only stop
    /// operation for every stream that task produced.
    func stopAndWait() async {
        guard let operation = retireCurrent() else { return }
        await awaitRetirement(operation)
    }

    private func reserveOperation(sessionID: UUID) -> (Operation, Operation?) {
        lock.withLock {
            let previous = current
            previous?.retired = true
            nextGeneration &+= 1
            let operation = Operation(generation: nextGeneration, sessionID: sessionID)
            current = operation
            return (operation, previous)
        }
    }

    private func retireCurrent() -> Operation? {
        lock.withLock {
            guard let operation = current else { return nil }
            operation.retired = true
            return operation
        }
    }

    private func run(
        _ operation: Operation,
        request: Driver.Request,
        sessionID: UUID,
        onAudioSampleBuffer: @escaping @Sendable (UUID, CMSampleBuffer) -> Void,
        onStreamError: @escaping @Sendable (UUID, Error) -> Void
    ) async throws {
        let stream = try await driver.makeStream(
            for: request,
            sessionID: sessionID,
            onAudioSampleBuffer: onAudioSampleBuffer,
            onStreamError: onStreamError
        )
        let canStart = lock.withLock { () -> Bool in
            guard current === operation, !operation.retired else { return false }
            operation.stream = stream
            return true
        }
        guard canStart else {
            await stopIfNeeded(operation, stream: stream)
            throw CancellationError()
        }

        try await driver.startCapture(stream)
        let canPublish = lock.withLock { () -> Bool in
            guard current === operation, !operation.retired else { return false }
            operation.active = true
            return true
        }
        guard canPublish else {
            await stopIfNeeded(operation, stream: stream)
            throw CancellationError()
        }
    }

    private func awaitRetirement(_ operation: Operation) async {
        if let startTask = lock.withLock({ operation.startTask }) {
            _ = await startTask.result
        }
        await stopIfNeeded(operation)
        clearIfCurrent(operation)
    }

    private func issueStopIfStreamExists(_ operation: Operation) {
        let stream = lock.withLock { operation.stream }
        guard let stream else { return }
        let driver = self.driver
        lock.withLock {
            guard operation.stopTask == nil else { return }
            operation.stopTask = Task {
                do { try await driver.stopCapture(stream) } catch { }
            }
        }
    }

    private func stopIfNeeded(_ operation: Operation, stream: Driver.Stream? = nil) async {
        let stopTask: Task<Void, Never>? = lock.withLock {
            if let stream, operation.stream == nil {
                operation.stream = stream
            }
            guard let stream = operation.stream else { return operation.stopTask }
            if let stopTask = operation.stopTask { return stopTask }
            let driver = self.driver
            let stopTask = Task {
                do { try await driver.stopCapture(stream) } catch { }
            }
            operation.stopTask = stopTask
            return stopTask
        }
        await stopTask?.value
    }

    private func clearIfCurrent(_ operation: Operation) {
        lock.withLock {
            if current === operation { current = nil }
        }
    }
}

/// Requests understood by the production ScreenCaptureKit driver. The wrapper
/// is unchecked-sendable because ScreenCaptureKit's object annotations lag the
/// Swift concurrency annotations, while access remains serialized by the
/// lifecycle owner.
final class ScreenCaptureRequest: @unchecked Sendable {
    enum Kind {
        case app(SCRunningApplication)
        case display(SCDisplay)
        case firstDisplay
    }

    let kind: Kind
    init(kind: Kind) { self.kind = kind }
}

private final class ScreenCaptureKitStream: NSObject, @unchecked Sendable {
    let stream: SCStream
    let output: ScreenCaptureOutputAdapter

    init(stream: SCStream, output: ScreenCaptureOutputAdapter) {
        self.stream = stream
        self.output = output
    }
}

private final class ScreenCaptureOutputAdapter: NSObject, SCStreamDelegate, SCStreamOutput, @unchecked Sendable {
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

private final class ScreenCaptureKitDriver: ScreenCaptureStreamDriver, @unchecked Sendable {
    typealias Stream = ScreenCaptureKitStream
    typealias Request = ScreenCaptureRequest

    private let sampleHandlerQueue = DispatchQueue(
        label: "com.mactalk.screen-audio.samples", qos: .userInitiated
    )

    func makeStream(
        for request: ScreenCaptureRequest,
        sessionID: UUID,
        onAudioSampleBuffer: @escaping @Sendable (UUID, CMSampleBuffer) -> Void,
        onStreamError: @escaping @Sendable (UUID, Error) -> Void
    ) async throws -> ScreenCaptureKitStream {
        let filter: SCContentFilter
        switch request.kind {
        case .app(let app):
            let content = try await SCShareableContent.current
            guard let window = content.windows.first(where: { $0.owningApplication == app }) else {
                throw NSError(domain: "ScreenAudioCapture", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "App '\(app.applicationName)' has no windows"
                ])
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
        case .display(let display):
            filter = SCContentFilter(display: display, excludingWindows: [])
        case .firstDisplay:
            let content = try await SCShareableContent.current
            guard let display = content.displays.first else {
                throw NSError(domain: "ScreenAudioCapture", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "No displays found"
                ])
            }
            filter = SCContentFilter(display: display, excludingWindows: [])
        }

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.queueDepth = 8
        let output = ScreenCaptureOutputAdapter(
            sessionID: sessionID,
            onAudioSampleBuffer: onAudioSampleBuffer,
            onStreamError: onStreamError
        )
        let stream = SCStream(filter: filter, configuration: config, delegate: output)
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: sampleHandlerQueue)
        return ScreenCaptureKitStream(stream: stream, output: output)
    }

    func startCapture(_ stream: ScreenCaptureKitStream) async throws {
        try await stream.stream.startCapture()
    }

    func stopCapture(_ stream: ScreenCaptureKitStream) async throws {
        try await stream.stream.stopCapture()
    }
}

/// App/System audio capture via ScreenCaptureKit.
final class ScreenAudioCapture: NSObject, @unchecked Sendable {
    private let lifecycle = ScreenCaptureLifecycle(driver: ScreenCaptureKitDriver())

    func selectApp(
        app: SCRunningApplication,
        sessionID: UUID,
        onAudioSampleBuffer: @escaping @Sendable (UUID, CMSampleBuffer) -> Void,
        onStreamError: @escaping @Sendable (UUID, Error) -> Void
    ) async throws {
        try await lifecycle.start(
            request: ScreenCaptureRequest(kind: .app(app)),
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
        try await lifecycle.start(
            request: ScreenCaptureRequest(kind: .display(display)),
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
        try await lifecycle.start(
            request: ScreenCaptureRequest(kind: .firstDisplay),
            sessionID: sessionID,
            onAudioSampleBuffer: onAudioSampleBuffer,
            onStreamError: onStreamError
        )
    }

    func requestStop() {
        lifecycle.requestStop()
    }

    func stopAndWait() async {
        await lifecycle.stopAndWait()
    }

    func stop() {
        requestStop()
    }

    deinit {
        requestStop()
    }
}
