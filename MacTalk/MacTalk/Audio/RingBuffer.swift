//
//  RingBuffer.swift
//  MacTalk
//
//  Thread-safe circular buffer for audio chunking
//

import Foundation
import os

/// Thread-safe circular buffer for audio samples.
///
/// ## Thread Safety
/// This class uses `OSAllocatedUnfairLock` for synchronization, which supports
/// priority inheritance to prevent priority inversion when called from real-time
/// audio threads.
///
/// ## Sendable Conformance
/// Marked `@unchecked Sendable` because:
/// - All mutable state is protected by `OSAllocatedUnfairLock`
/// - Generic type `T` is constrained to `Sendable`
/// - Lock provides full memory barrier ensuring visibility across threads
final class RingBuffer<T>: @unchecked Sendable where T: Sendable {
    private struct State {
        var buffer: [T?]
        var head: Int = 0
        var tail: Int = 0
        var count: Int = 0

        init(capacity: Int) {
            self.buffer = Array(repeating: nil, count: capacity)
        }
    }

    private let state: OSAllocatedUnfairLock<State>

    init(capacity: Int) {
        self.state = OSAllocatedUnfairLock(initialState: State(capacity: capacity))
    }

    var capacity: Int {
        return state.withLock { $0.buffer.count }
    }

    var availableSpace: Int {
        return state.withLock { state in
            state.buffer.count - state.count
        }
    }

    var availableData: Int {
        return state.withLock { $0.count }
    }

    func push(_ element: T) {
        state.withLock { state in
            state.buffer[state.head] = element
            state.head = (state.head + 1) % state.buffer.count

            if state.count == state.buffer.count {
                // Buffer is full, overwrite oldest data
                state.tail = (state.tail + 1) % state.buffer.count
            } else {
                state.count += 1
            }
        }
    }

    func pop() -> T? {
        return state.withLock { state in
            guard state.count > 0 else { return nil }

            let element = state.buffer[state.tail]
            state.buffer[state.tail] = nil
            state.tail = (state.tail + 1) % state.buffer.count
            state.count -= 1

            return element
        }
    }

    func peek() -> T? {
        return state.withLock { state in
            guard state.count > 0 else { return nil }
            return state.buffer[state.tail]
        }
    }

    func clear() {
        state.withLock { state in
            state.buffer = Array(repeating: nil, count: state.buffer.count)
            state.head = 0
            state.tail = 0
            state.count = 0
        }
    }

    func popMultiple(_ maxCount: Int) -> [T] {
        return state.withLock { state in
            let actualCount = min(maxCount, state.count)
            var result: [T] = []
            result.reserveCapacity(actualCount)

            for _ in 0..<actualCount {
                if let element = state.buffer[state.tail] {
                    result.append(element)
                }
                state.buffer[state.tail] = nil
                state.tail = (state.tail + 1) % state.buffer.count
                state.count -= 1
            }

            return result
        }
    }
}

// Specialized version for Float samples
extension RingBuffer where T == Float {
    func pushSamples(_ samples: [Float]) {
        for sample in samples {
            push(sample)
        }
    }

    func popSamples(_ count: Int) -> [Float] {
        return popMultiple(count)
    }
}
