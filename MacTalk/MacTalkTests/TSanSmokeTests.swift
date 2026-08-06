import XCTest

/// Small standalone launch target for the TSan lane. It intentionally uses
/// only Foundation/XCTest and is run before the larger deterministic selection.
final class TSanSmokeTests: XCTestCase {
    func test_instrumentedRuntimeCanExecuteConcurrentWork() async {
        let counter = LockedTSanCounter()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    for _ in 0..<100 {
                        counter.increment()
                    }
                }
            }
        }
        XCTAssertEqual(counter.value, 800)
    }
}

private final class LockedTSanCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}
