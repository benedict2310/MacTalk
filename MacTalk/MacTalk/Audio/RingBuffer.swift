//
//  RingBuffer.swift
//  MacTalk
//
//  Thread-safe circular buffer for audio chunking
//

import Foundation

final class RingBuffer<T> {
    private var buffer: [T?]
    private var head = 0
    private var tail = 0
    private var count = 0
    private let lock = NSLock()

    init(capacity: Int) {
        buffer = Array(repeating: nil, count: capacity)
    }

    var capacity: Int {
        return buffer.count
    }

    var availableSpace: Int {
        lock.lock()
        defer { lock.unlock() }
        return buffer.count - count
    }

    var availableData: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func push(_ element: T) {
        lock.lock()
        defer { lock.unlock() }

        buffer[head] = element
        head = (head + 1) % buffer.count

        if count == buffer.count {
            // Buffer is full, overwrite oldest data
            tail = (tail + 1) % buffer.count
        } else {
            count += 1
        }
    }

    func pop() -> T? {
        lock.lock()
        defer { lock.unlock() }

        guard count > 0 else { return nil }

        let element = buffer[tail]
        buffer[tail] = nil
        tail = (tail + 1) % buffer.count
        count -= 1

        return element
    }

    func peek() -> T? {
        lock.lock()
        defer { lock.unlock() }

        guard count > 0 else { return nil }
        return buffer[tail]
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }

        buffer = Array(repeating: nil, count: buffer.count)
        head = 0
        tail = 0
        count = 0
    }

    func popMultiple(_ count: Int) -> [T] {
        lock.lock()
        defer { lock.unlock() }

        let actualCount = min(count, self.count)
        var result: [T] = []
        result.reserveCapacity(actualCount)

        for _ in 0..<actualCount {
            if let element = buffer[tail] {
                result.append(element)
            }
            buffer[tail] = nil
            tail = (tail + 1) % buffer.count
            count -= 1
        }

        return result
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
