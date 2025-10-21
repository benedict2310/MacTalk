//
//  RingBufferTests.swift
//  MacTalkTests
//
//  Unit tests for RingBuffer component
//

import XCTest
@testable import MacTalk

final class RingBufferTests: XCTestCase {

    // MARK: - Basic Operations

    func testInitialization() {
        let buffer = RingBuffer<Int>(capacity: 10)

        XCTAssertEqual(buffer.capacity, 10)
        XCTAssertEqual(buffer.availableData, 0)
        XCTAssertEqual(buffer.availableSpace, 10)
    }

    func testPushAndPop() {
        let buffer = RingBuffer<Int>(capacity: 5)

        buffer.push(1)
        buffer.push(2)
        buffer.push(3)

        XCTAssertEqual(buffer.availableData, 3)
        XCTAssertEqual(buffer.availableSpace, 2)

        XCTAssertEqual(buffer.pop(), 1)
        XCTAssertEqual(buffer.pop(), 2)
        XCTAssertEqual(buffer.pop(), 3)
        XCTAssertNil(buffer.pop())
    }

    func testPeek() {
        let buffer = RingBuffer<String>(capacity: 5)

        XCTAssertNil(buffer.peek())

        buffer.push("first")
        buffer.push("second")

        XCTAssertEqual(buffer.peek(), "first")
        XCTAssertEqual(buffer.peek(), "first") // Should not remove
        XCTAssertEqual(buffer.availableData, 2)
    }

    // MARK: - Overflow Handling

    func testOverflow() {
        let buffer = RingBuffer<Int>(capacity: 3)

        buffer.push(1)
        buffer.push(2)
        buffer.push(3)
        buffer.push(4) // Should overwrite 1
        buffer.push(5) // Should overwrite 2

        XCTAssertEqual(buffer.availableData, 3)
        XCTAssertEqual(buffer.pop(), 3)
        XCTAssertEqual(buffer.pop(), 4)
        XCTAssertEqual(buffer.pop(), 5)
    }

    func testClear() {
        let buffer = RingBuffer<Int>(capacity: 5)

        buffer.push(1)
        buffer.push(2)
        buffer.push(3)

        XCTAssertEqual(buffer.availableData, 3)

        buffer.clear()

        XCTAssertEqual(buffer.availableData, 0)
        XCTAssertEqual(buffer.availableSpace, 5)
        XCTAssertNil(buffer.pop())
    }

    // MARK: - Multiple Operations

    func testPopMultiple() {
        let buffer = RingBuffer<Int>(capacity: 10)

        for i in 1...5 {
            buffer.push(i)
        }

        let result = buffer.popMultiple(3)

        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result, [1, 2, 3])
        XCTAssertEqual(buffer.availableData, 2)
    }

    func testPopMultipleExceedsAvailable() {
        let buffer = RingBuffer<Int>(capacity: 10)

        buffer.push(1)
        buffer.push(2)

        let result = buffer.popMultiple(5)

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result, [1, 2])
        XCTAssertEqual(buffer.availableData, 0)
    }

    // MARK: - Float Sample Extensions

    func testPushSamples() {
        let buffer = RingBuffer<Float>(capacity: 10)

        let samples: [Float] = [1.0, 2.0, 3.0, 4.0, 5.0]
        buffer.pushSamples(samples)

        XCTAssertEqual(buffer.availableData, 5)

        let result = buffer.popSamples(3)
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0], 1.0, accuracy: 0.001)
        XCTAssertEqual(result[1], 2.0, accuracy: 0.001)
        XCTAssertEqual(result[2], 3.0, accuracy: 0.001)
    }

    // MARK: - Thread Safety Tests

    func testConcurrentPushAndPop() {
        let buffer = RingBuffer<Int>(capacity: 1000)
        let expectation = XCTestExpectation(description: "Concurrent operations complete")
        expectation.expectedFulfillmentCount = 2

        var poppedValues: [Int] = []
        let lock = NSLock()

        // Writer thread
        DispatchQueue.global(qos: .userInitiated).async {
            for i in 0..<500 {
                buffer.push(i)
                Thread.sleep(forTimeInterval: 0.0001)
            }
            expectation.fulfill()
        }

        // Reader thread
        DispatchQueue.global(qos: .userInitiated).async {
            for _ in 0..<500 {
                if let value = buffer.pop() {
                    lock.lock()
                    poppedValues.append(value)
                    lock.unlock()
                }
                Thread.sleep(forTimeInterval: 0.0001)
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 10.0)

        // Should have popped some values without crashes
        XCTAssertGreaterThan(poppedValues.count, 0)
    }

    func testMultipleWriters() {
        let buffer = RingBuffer<Int>(capacity: 10000)
        let expectation = XCTestExpectation(description: "Multiple writers complete")
        expectation.expectedFulfillmentCount = 5

        for threadId in 0..<5 {
            DispatchQueue.global(qos: .userInitiated).async {
                for i in 0..<100 {
                    buffer.push(threadId * 1000 + i)
                }
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 5.0)

        // Should have written 500 values total
        XCTAssertEqual(buffer.availableData, 500)
    }

    // MARK: - Edge Cases

    func testEmptyBufferOperations() {
        let buffer = RingBuffer<Int>(capacity: 5)

        XCTAssertNil(buffer.pop())
        XCTAssertNil(buffer.peek())

        let result = buffer.popMultiple(3)
        XCTAssertEqual(result.count, 0)
    }

    func testSingleElementCapacity() {
        let buffer = RingBuffer<String>(capacity: 1)

        buffer.push("first")
        XCTAssertEqual(buffer.availableData, 1)
        XCTAssertEqual(buffer.availableSpace, 0)

        buffer.push("second") // Should overwrite first
        XCTAssertEqual(buffer.pop(), "second")
    }

    func testWrapAround() {
        let buffer = RingBuffer<Int>(capacity: 3)

        // Fill buffer
        buffer.push(1)
        buffer.push(2)
        buffer.push(3)

        // Pop some
        _ = buffer.pop()
        _ = buffer.pop()

        // Push more (will wrap around)
        buffer.push(4)
        buffer.push(5)

        // Should have: 3, 4, 5
        XCTAssertEqual(buffer.pop(), 3)
        XCTAssertEqual(buffer.pop(), 4)
        XCTAssertEqual(buffer.pop(), 5)
        XCTAssertNil(buffer.pop())
    }

    // MARK: - Performance Tests

    func testPerformancePush() {
        let buffer = RingBuffer<Int>(capacity: 100000)

        measure {
            for i in 0..<10000 {
                buffer.push(i)
            }
        }
    }

    func testPerformancePop() {
        let buffer = RingBuffer<Int>(capacity: 100000)

        // Fill buffer first
        for i in 0..<10000 {
            buffer.push(i)
        }

        measure {
            for _ in 0..<10000 {
                _ = buffer.pop()
            }
        }
    }
}
