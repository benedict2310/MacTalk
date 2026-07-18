//
//  AsyncTimeout.swift
//  MacTalk
//
//  Timeout utility for async operations to prevent infinite hangs
//

import Foundation

/// Error thrown when an async operation times out
struct TimeoutError: Error, LocalizedError {
    let seconds: TimeInterval

    var errorDescription: String? {
        return "Operation timed out after \(seconds) seconds"
    }
}

/// Execute an async operation with a timeout.
///
/// This deliberately does not use a task group. Task groups wait for all of
/// their children when leaving the scope, so a cancellation-ignoring operation
/// would turn a timeout into another indefinite wait. The operation and timer
/// are unstructured tasks instead: whichever completes first resumes the
/// continuation, cancels the loser, and the caller never awaits that loser.
/// Late completion is ignored by `TimeoutGate`.
///
/// Throws TimeoutError if the operation doesn't complete in time.
func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let gate = TimeoutGate<T>()

    return try await withTaskCancellationHandler(operation: {
        try await withCheckedThrowingContinuation { continuation in
            let operationTask = Task { [weak gate] in
                do {
                    let value = try await operation()
                    await gate?.finish(.success(value))
                } catch {
                    await gate?.finish(.failure(error))
                }
            }
            let timeoutTask = Task { [weak gate] in
                do {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds(seconds))
                } catch {
                    return
                }
                await gate?.finish(.failure(TimeoutError(seconds: seconds)))
            }

            // Installing asynchronously lets the actor own the continuation
            // before either task can publish its result, while its pending
            // result handles the opposite scheduling order safely.
            Task { [weak gate] in
                await gate?.install(
                    continuation: continuation,
                    operationTask: operationTask,
                    timeoutTask: timeoutTask
                )
            }
        }
    }, onCancel: {
        Task { await gate.finish(.failure(CancellationError())) }
    })
}

private func timeoutNanoseconds(_ seconds: TimeInterval) -> UInt64 {
    guard seconds > 0 else { return 0 }
    let maximum = Double(UInt64.max) / 1_000_000_000
    return UInt64(min(seconds, maximum) * 1_000_000_000)
}

/// Serializes continuation completion and task cleanup. The gate does not
/// retain the tasks after completion, and task closures hold it weakly, so a
/// non-cooperative underlying operation cannot keep the timeout machinery
/// alive indefinitely.
private actor TimeoutGate<T: Sendable> {
    private var continuation: CheckedContinuation<T, Error>?
    private var pendingResult: Result<T, Error>?
    private var completed = false
    private var operationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    func install(
        continuation: CheckedContinuation<T, Error>,
        operationTask: Task<Void, Never>,
        timeoutTask: Task<Void, Never>
    ) {
        self.continuation = continuation
        self.operationTask = operationTask
        self.timeoutTask = timeoutTask

        guard completed else { return }
        cancelTasks()
        resumePendingResultIfNeeded()
    }

    func finish(_ result: Result<T, Error>) {
        guard !completed else { return }
        completed = true
        pendingResult = result
        cancelTasks()
        resumePendingResultIfNeeded()
    }

    private func cancelTasks() {
        operationTask?.cancel()
        timeoutTask?.cancel()
        operationTask = nil
        timeoutTask = nil
    }

    private func resumePendingResultIfNeeded() {
        guard let continuation, let pendingResult else { return }
        self.continuation = nil
        self.pendingResult = nil
        continuation.resume(with: pendingResult)
    }
}
