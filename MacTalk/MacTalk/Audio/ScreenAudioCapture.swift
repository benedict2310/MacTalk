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

enum ScreenCaptureLifecycleError: Error, Equatable, Sendable {
    case stopFailed
}

/// Owns one generation and every stream produced by that generation.
/// `requestStop` only performs synchronous retirement bookkeeping and may be
/// called from a callback/hot path. `stopAndWait` is the durable async
/// boundary used by replacement and explicit cleanup.
final class ScreenCaptureLifecycle<Driver: ScreenCaptureStreamDriver>: @unchecked Sendable {
    private final class Completion: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<Void, Error>?
        private var waiters: [CheckedContinuation<Void, Error>] = []

        func resolve(_ result: Result<Void, Error>) -> Bool {
            let (continuations, didResolve) = lock.withLock { () -> ([CheckedContinuation<Void, Error>], Bool) in
                guard self.result == nil else { return ([], false) }
                self.result = result
                defer { waiters.removeAll() }
                return (waiters, true)
            }
            for continuation in continuations {
                continuation.resume(with: result)
            }
            return didResolve
        }

        func wait() async throws {
            try await withCheckedThrowingContinuation { continuation in
                let immediateResult = lock.withLock { () -> Result<Void, Error>? in
                    if let result { return result }
                    waiters.append(continuation)
                    return nil
                }
                if let immediateResult { continuation.resume(with: immediateResult) }
            }
        }
    }

    private final class Operation: @unchecked Sendable {
        let generation: UInt64
        let sessionID: UUID
        let predecessor: Operation?
        let startCompletion = Completion()
        var retired = false
        var stream: Driver.Stream?
        var stopTask: Task<Void, Error>?
        var stopToken: UInt64 = 0
        var active = false

        init(generation: UInt64, sessionID: UUID, predecessor: Operation?) {
            self.generation = generation
            self.sessionID = sessionID
            self.predecessor = predecessor
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

    var currentGeneration: UInt64? {
        lock.withLock { current?.generation }
    }

    func start(
        request: Driver.Request,
        sessionID: UUID,
        onAudioSampleBuffer: @escaping @Sendable (UUID, CMSampleBuffer) -> Void,
        onStreamError: @escaping @Sendable (UUID, Error) -> Void
    ) async throws {
        let (operation, previous) = reserveOperation(sessionID: sessionID)
        do {
            if let previous {
                do {
                    try await awaitRetirement(previous)
                } catch {
                    // A replacement is not allowed to hide a generation whose
                    // shutdown is unproven. Restore it as current so a later
                    // stopAndWait can retry the same protected stream.
                    lock.withLock {
                        if current === operation { current = previous }
                    }
                    throw error
                }
            }
            guard lock.withLock({ current === operation && !operation.retired }) else {
                operation.startCompletion.resolve(.failure(CancellationError()))
                throw CancellationError()
            }

            do {
                try await run(
                    operation,
                    request: request,
                    sessionID: sessionID,
                    onAudioSampleBuffer: onAudioSampleBuffer,
                    onStreamError: onStreamError
                )
                operation.startCompletion.resolve(.success(()))
                if isRetired(operation) {
                    try await stopIfNeeded(operation)
                    clearIfCurrent(operation)
                    throw CancellationError()
                }
            } catch {
                let wasStartFailure = operation.startCompletion.resolve(.failure(error))
                if wasStartFailure {
                    try await stopIfNeeded(operation)
                    clearIfCurrent(operation)
                }
                throw error
            }
        } catch {
            operation.startCompletion.resolve(.failure(error))
            throw error
        }
    }

    /// Retires the current generation before any await. A late discovery
    /// continuation therefore cannot publish a stream as active. It does not
    /// issue a premature stop: only the durable boundary may do that.
    func requestStop() {
        _ = retireCurrent()
    }

    /// Waits for the generation's explicit start completion, then performs and
    /// awaits the single-flight shutdown. Failed shutdown retains ownership so
    /// the next call can retry it.
    func stopAndWait() async throws {
        guard let operation = retireCurrent() else { return }
        try await awaitRetirement(operation)
    }

    private func reserveOperation(sessionID: UUID) -> (Operation, Operation?) {
        lock.withLock {
            let previous = current
            previous?.retired = true
            nextGeneration &+= 1
            let operation = Operation(generation: nextGeneration, sessionID: sessionID, predecessor: previous)
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
        lock.withLock {
            operation.stream = stream
            // Conservatively retain ownership before start returns: a driver
            // may have activated hardware before reporting a partial failure.
            operation.active = true
        }
        try await driver.startCapture(stream)
    }

    private func isRetired(_ operation: Operation) -> Bool {
        lock.withLock { operation.retired }
    }

    private func awaitRetirement(_ operation: Operation) async throws {
        var candidate: Operation? = operation
        var firstStartFailure: Error?
        while let currentCandidate = candidate {
            do {
                try await currentCandidate.startCompletion.wait()
            } catch {
                if firstStartFailure == nil { firstStartFailure = error }
            }
            try await stopIfNeeded(currentCandidate)
            candidate = currentCandidate.predecessor
        }
        clearIfCurrent(operation)
        if let firstStartFailure { throw firstStartFailure }
    }

    private func stopIfNeeded(_ operation: Operation) async throws {
        let (task, token): (Task<Void, Error>?, UInt64) = lock.withLock {
            guard let stream = operation.stream else { return (nil, operation.stopToken) }
            if let stopTask = operation.stopTask {
                return (stopTask, operation.stopToken)
            }
            operation.stopToken &+= 1
            let token = operation.stopToken
            let driver = self.driver
            let stopTask = Task { try await driver.stopCapture(stream) }
            operation.stopTask = stopTask
            return (stopTask, token)
        }
        guard let task else { return }
        do {
            try await task.value
        } catch {
            lock.withLock {
                guard operation.stopToken == token else { return }
                operation.stopTask = nil
            }
            throw ScreenCaptureLifecycleError.stopFailed
        }
        lock.withLock {
            guard operation.stopToken == token else { return }
            operation.stopTask = nil
            operation.active = false
            operation.stream = nil
        }
    }

    private func clearIfCurrent(_ operation: Operation) {
        lock.withLock {
            guard current === operation, operation.stream == nil else { return }
            current = nil
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

    func stopAndWait() async throws {
        try await lifecycle.stopAndWait()
    }

    func stop() {
        requestStop()
    }

    deinit {
        requestStop()
    }
}
