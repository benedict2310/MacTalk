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

/// Execute an async operation with a timeout
/// Throws TimeoutError if the operation doesn't complete in time
func withTimeout<T>(
    seconds: TimeInterval,
    operation: @escaping () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        // Start the operation
        group.addTask {
            try await operation()
        }

        // Start the timeout timer
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError(seconds: seconds)
        }

        // Wait for the first task to complete
        guard let result = try await group.next() else {
            throw TimeoutError(seconds: seconds)
        }

        // Cancel the other task
        group.cancelAll()

        return result
    }
}
