//
//  DeterministicHarness.swift
//  MacTalkTests
//
//  Reusable, side-effect-free fakes for pipeline tests. These types deliberately
//  do not consult UserDefaults, TCC, model stores, or URLSession.
//

import Foundation
import XCTest
@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
@testable import MacTalk

struct DeterministicASRScript: Sendable {
    var partials: [ASRPartial?] = []
    var finals: [ASRFinalSegment?] = []
    var prepareError: DeterministicASRError?
    var processErrors: [DeterministicASRError?] = []
    var finalizeErrors: [DeterministicASRError?] = []
    var processDelayNanoseconds: UInt64 = 0
    var finalizeDelayNanoseconds: UInt64 = 0
    var processBarrier: DeterministicASRBarrier?
    var finalizeBarrier: DeterministicASRBarrier?

    init(
        partials: [ASRPartial?] = [],
        finals: [ASRFinalSegment?] = [],
        prepareError: DeterministicASRError? = nil,
        processErrors: [DeterministicASRError?] = [],
        finalizeErrors: [DeterministicASRError?] = [],
        processDelayNanoseconds: UInt64 = 0,
        finalizeDelayNanoseconds: UInt64 = 0,
        processBarrier: DeterministicASRBarrier? = nil,
        finalizeBarrier: DeterministicASRBarrier? = nil
    ) {
        self.partials = partials
        self.finals = finals
        self.prepareError = prepareError
        self.processErrors = processErrors
        self.finalizeErrors = finalizeErrors
        self.processDelayNanoseconds = processDelayNanoseconds
        self.finalizeDelayNanoseconds = finalizeDelayNanoseconds
        self.processBarrier = processBarrier
        self.finalizeBarrier = finalizeBarrier
    }
}

/// Manually released inference gate for adversarial ordering tests. Releasing
/// before a call arrives leaves a permit, so tests can release finalization
/// first without accidentally ordering the controller's callbacks.
final class DeterministicASRBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private var waiters: [CheckedContinuation<Void, Error>] = []

    func wait() async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if released {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func release() {
        let continuations: [CheckedContinuation<Void, Error>] = lock.withLock {
            released = true
            let result = waiters
            waiters.removeAll()
            return result
        }
        continuations.forEach { $0.resume() }
    }
}

enum DeterministicASRError: Error, Equatable, Sendable {
    case prepare
    case reset
    case process(Int)
    case finalize(Int)
}

enum DeterministicASREngineEvent: Equatable, Sendable {
    case prepare
    case reset
    case process(samples: [Float], language: String?)
    case finalize(samples: [Float], language: String?)
    case cancelled(operation: String)
}

/// A configurable ASR fake that records the exact sample payload and call
/// order. A cancellation-aware gate models a slow provider without wall-clock
/// sleeps or polling.
final class DeterministicASREngine: @unchecked Sendable, ASREngine {
    let provider: ASRProvider
    private let script: DeterministicASRScript
    private let lock = NSLock()
    private var recordedEvents: [DeterministicASREngineEvent] = []
    private var processCount = 0
    private var finalizeCount = 0
    private let cancellationGate = DeterministicCancellationGate()
    var onEvent: (@Sendable (DeterministicASREngineEvent) -> Void)?

    init(provider: ASRProvider = .whisper, script: DeterministicASRScript = .init()) {
        self.provider = provider
        self.script = script
    }

    var events: [DeterministicASREngineEvent] {
        lock.lock(); defer { lock.unlock() }
        return recordedEvents
    }

    var prepareCount: Int { events.filter { $0 == .prepare }.count }
    var resetCount: Int { events.filter { $0 == .reset }.count }
    var processCalls: [(samples: [Float], language: String?)] {
        events.compactMap {
            guard case let .process(samples, language) = $0 else { return nil }
            return (samples, language)
        }
    }
    var finalizeCalls: [(samples: [Float], language: String?)] {
        events.compactMap {
            guard case let .finalize(samples, language) = $0 else { return nil }
            return (samples, language)
        }
    }
    var cancellationCount: Int {
        events.reduce(into: 0) { count, event in
            if case .cancelled = event { count += 1 }
        }
    }

    func prepare() async throws {
        record(.prepare)
        try await waitIfNeeded(0, barrier: nil, operation: "prepare")
        if let prepareError = script.prepareError {
            throw prepareError
        }
    }

    func reset() async {
        record(.reset)
    }

    func process(_ buffer: AVAudioPCMBuffer, language: String?) async throws -> ASRPartial? {
        let samples = copySamples(from: buffer)
        let index = lock.withLock {
            let value = processCount
            processCount += 1
            return value
        }
        record(.process(samples: samples, language: language))
        try await waitIfNeeded(script.processDelayNanoseconds, barrier: script.processBarrier, operation: "process")
        if let scriptedError = script.processErrors[safe: index], let error = scriptedError {
            throw error
        }
        return script.partials[safe: index] ?? nil
    }

    func finalize(_ buffer: AVAudioPCMBuffer, language: String?) async throws -> ASRFinalSegment? {
        let samples = copySamples(from: buffer)
        let index = lock.withLock {
            let value = finalizeCount
            finalizeCount += 1
            return value
        }
        record(.finalize(samples: samples, language: language))
        try await waitIfNeeded(script.finalizeDelayNanoseconds, barrier: script.finalizeBarrier, operation: "finalize")
        if let scriptedError = script.finalizeErrors[safe: index], let error = scriptedError {
            throw error
        }
        return script.finals[safe: index] ?? nil
    }

    private func waitIfNeeded(
        _ nanoseconds: UInt64,
        barrier: DeterministicASRBarrier?,
        operation: String
    ) async throws {
        do {
            if let barrier {
                try await barrier.wait()
            } else if nanoseconds > 0 {
                try await cancellationGate.wait()
            }
            try Task.checkCancellation()
        } catch {
            record(.cancelled(operation: operation))
            throw error
        }
    }

    private func record(_ event: DeterministicASREngineEvent) {
        let callback = lock.withLock {
            recordedEvents.append(event)
            return onEvent
        }
        callback?(event)
    }

    private func copySamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channel = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}

private final class DeterministicCancellationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var cancelled = false

    func wait() async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if cancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else {
                    self.continuation = continuation
                    lock.unlock()
                }
            }
        }, onCancel: {
            lock.lock()
            cancelled = true
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(throwing: CancellationError())
        })
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// Capture fake retaining callbacks so tests can deliver frames synchronously
/// and replay stale callbacks after a restart.
final class DeterministicCaptureSession: @unchecked Sendable, TranscriptionCaptureSession {
    enum Error: Swift.Error, Equatable, Sendable { case microphoneStart, appStart }

    private(set) var microphoneCallbacks: [@Sendable (UUID, AudioCaptureFrame) -> Void] = []
    private(set) var appCallbacks: [@Sendable (UUID, CMSampleBuffer) -> Void] = []
    private(set) var errorCallbacks: [@Sendable (UUID, Swift.Error) -> Void] = []
    private(set) var microphoneSessionIDs: [UUID] = []
    private(set) var appSessionIDs: [UUID] = []
    private(set) var stopCount = 0
    private(set) var stopAppAudioCount = 0
    var microphoneStartError: Swift.Error?
    var appStartError: Swift.Error?

    func startMicrophone(sessionID: UUID, callback: @escaping @Sendable (UUID, AudioCaptureFrame) -> Void) throws {
        if let microphoneStartError { throw microphoneStartError }
        microphoneSessionIDs.append(sessionID)
        microphoneCallbacks.append(callback)
    }

    func startAppAudio(
        sessionID: UUID,
        source: AppPickerWindowController.AudioSource,
        callback: @escaping @Sendable (UUID, CMSampleBuffer) -> Void,
        errorCallback: @escaping @Sendable (UUID, Swift.Error) -> Void
    ) async throws {
        if let appStartError { throw appStartError }
        appSessionIDs.append(sessionID)
        appCallbacks.append(callback)
        errorCallbacks.append(errorCallback)
    }

    func stop() { stopCount += 1 }
    func stopAppAudio() { stopAppAudioCount += 1 }

    func emitMicrophone(_ frame: AudioCaptureFrame, at index: Int = -1) {
        let i = index >= 0 ? index : microphoneCallbacks.count - 1
        precondition(microphoneCallbacks.indices.contains(i), "No microphone callback at index \(i)")
        microphoneCallbacks[i](microphoneSessionIDs[i], frame)
    }

    func emitAppAudio(_ buffer: CMSampleBuffer, at index: Int = -1) {
        let i = index >= 0 ? index : appCallbacks.count - 1
        precondition(appCallbacks.indices.contains(i), "No app callback at index \(i)")
        appCallbacks[i](appSessionIDs[i], buffer)
    }

    func emitAppError(_ error: Swift.Error = NSError(domain: "DeterministicCaptureSession", code: 1), at index: Int = -1) {
        let i = index >= 0 ? index : errorCallbacks.count - 1
        precondition(errorCallbacks.indices.contains(i), "No app error callback at index \(i)")
        errorCallbacks[i](appSessionIDs[i], error)
    }
}

final class DeterministicManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    var nowNanoseconds: UInt64 { lock.withLock { value } }
    func advance(nanoseconds: UInt64) { lock.withLock { value += nanoseconds } }
}

final class DeterministicManualScheduler: TranscriptionScheduler, @unchecked Sendable {
    private final class Entry: @unchecked Sendable {
        let deadline: UInt64
        let operation: @Sendable () -> Void
        var cancelled = false
        init(deadline: UInt64, operation: @escaping @Sendable () -> Void) {
            self.deadline = deadline; self.operation = operation
        }
    }
    private final class Token: AudioCompositionScheduledTask, @unchecked Sendable {
        weak var owner: DeterministicManualScheduler?
        let entry: Entry
        init(owner: DeterministicManualScheduler, entry: Entry) { self.owner = owner; self.entry = entry }
        func cancel() { owner?.cancel(entry) }
    }
    let clock: DeterministicManualClock
    var nowNanoseconds: UInt64 { clock.nowNanoseconds }
    private let lock = NSLock()
    private var entries: [Entry] = []
    init(clock: DeterministicManualClock) { self.clock = clock }
    var activeCount: Int { lock.withLock { entries.filter { !$0.cancelled }.count } }
    func schedule(deadlineNanoseconds: UInt64, operation: @escaping @Sendable () -> Void) -> any AudioCompositionScheduledTask {
        let entry = Entry(deadline: deadlineNanoseconds, operation: operation)
        lock.withLock { entries.append(entry) }
        return Token(owner: self, entry: entry)
    }
    func fireDue() {
        while let entry = lock.withLock({ () -> Entry? in
            guard let index = entries.firstIndex(where: { !$0.cancelled && $0.deadline <= clock.nowNanoseconds }) else { return nil }
            return entries.remove(at: index)
        }) { entry.operation() }
    }
    private func cancel(_ entry: Entry) { lock.withLock { entry.cancelled = true } }
}

enum DeterministicAudioFixtures {
    static func silence(count: Int) -> [Float] { [Float](repeating: 0, count: count) }
    static func impulse(count: Int, amplitude: Float = 1) -> [Float] {
        guard count > 0 else { return [] }
        var result = silence(count: count); result[0] = amplitude; return result
    }
    static func tone(count: Int, frequency: Double = 440, sampleRate: Double = 16_000, amplitude: Float = 0.25) -> [Float] {
        (0..<max(0, count)).map { amplitude * Float(sin(2 * Double.pi * frequency * Double($0) / sampleRate)) }
    }
    static func hostTime(nanoseconds: UInt64) -> UInt64 { AudioConvertNanosToHostTime(nanoseconds) }
}

final class DeterministicModelDownloader: @unchecked Sendable {
    private(set) var requestedModels: [String] = []
    func download(filename: String) throws -> URL {
        requestedModels.append(filename)
        throw NSError(domain: "DeterministicModelDownloader", code: 1, userInfo: [NSLocalizedDescriptionKey: "Model downloads are disabled in deterministic tests"])
    }
}

final class DeterministicValueBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func set(_ value: Value) { lock.withLock { self.value = value } }
    func get() -> Value { lock.withLock { value } }
}

final class DeterministicNetworkTrap: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [URLRequest] = []

    func record(_ request: URLRequest) {
        lock.withLock { requests.append(request) }
    }

    var requestCount: Int { lock.withLock { requests.count } }

    func session() -> URLSession {
        DeterministicNetworkTrapURLProtocol.trap = self
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeterministicNetworkTrapURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class DeterministicNetworkTrapURLProtocol: URLProtocol {
    nonisolated(unsafe) static var trap: DeterministicNetworkTrap?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.trap?.record(request)
        let error = NSError(
            domain: "DeterministicNetworkTrap",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Unexpected network request in deterministic lane"]
        )
        client?.urlProtocol(self, didFailWithError: error)
    }

    override func stopLoading() {}
}

func makeIsolatedTestDefaults(_ name: String = UUID().uuidString) -> (defaults: UserDefaults, suiteName: String) {
    let suiteName = "MacTalk.DeterministicTests.\(name)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
}
