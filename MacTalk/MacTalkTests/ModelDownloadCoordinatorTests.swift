import XCTest
@testable import MacTalk

@MainActor
final class ModelDownloadCoordinatorTests: XCTestCase {
    func test_normalizesProgressAndPublishesVerifyingAndReady() async throws {
        let client = DownloadClientFake()
        let scheduler = DownloadSchedulerFake()
        let coordinator = ModelDownloadCoordinator(client: client, scheduler: scheduler)
        var states: [ModelDownloadViewState] = []
        coordinator.onStateChanged = { states.append($0) }
        let spec = try XCTUnwrap(ModelCatalog.bundled().first)
        let requestID = UUID()

        try await coordinator.download(.whisper(spec), requestID: requestID)

        XCTAssertEqual(states.first?.requestID, requestID)
        XCTAssertEqual(states.compactMap { phase in
            if case let .downloading(fraction, _, _) = phase.phase { return fraction }
            return nil
        }, [0, 1])
        XCTAssertTrue(states.contains { $0.phase == .verifying })
        XCTAssertTrue(states.contains { $0.phase == .ready })
        XCTAssertEqual(client.requirements, [.whisper(spec)])
        XCTAssertEqual(scheduler.delays, [2])
    }

    func test_cancelIsTerminalAndDoesNotAllowLateReadyEvent() async throws {
        let client = DownloadClientFake()
        let coordinator = ModelDownloadCoordinator(client: client, scheduler: DownloadSchedulerFake())
        let requestID = UUID()
        let spec = try XCTUnwrap(ModelCatalog.bundled().first)
        try await coordinator.download(.whisper(spec), requestID: requestID)
        coordinator.cancel(requestID: requestID)
        client.emit(.ready)
        guard case .failed = coordinator.state.phase else {
            return XCTFail("cancel must remain terminal")
        }
    }

    func test_changedRequirementSupersedesDelayedDownload() async throws {
        let client = DelayedDownloadClient()
        let coordinator = ModelDownloadCoordinator(client: client, scheduler: DownloadSchedulerFake())
        let specs = Array(ModelCatalog.bundled().prefix(2))
        let first = try XCTUnwrap(specs.first)
        let second = try XCTUnwrap(specs.dropFirst().first)
        let firstID = UUID()
        let secondID = UUID()

        let firstTask = Task {
            try? await coordinator.download(.whisper(first), requestID: firstID)
        }
        await client.waitUntilStarted(.whisper(first))
        let secondTask = Task {
            try? await coordinator.download(.whisper(second), requestID: secondID)
        }
        await client.waitUntilStarted(.whisper(second))
        client.finish(.whisper(first))
        client.finish(.whisper(second))
        _ = await firstTask.value
        _ = await secondTask.value

        XCTAssertEqual(client.requirements, [.whisper(first), .whisper(second)])
        XCTAssertEqual(coordinator.state.requirement, .whisper(second))
        XCTAssertEqual(coordinator.state.requestID, secondID)
    }
}

@MainActor
private final class DownloadClientFake: ModelDownloadClient {
    var requirements: [ModelRequirement] = []
    var eventHandler: ((ModelDownloadClientEvent) -> Void)?

    func download(_ requirement: ModelRequirement, onEvent: @escaping @MainActor (ModelDownloadClientEvent) -> Void) async throws {
        requirements.append(requirement)
        eventHandler = onEvent
        onEvent(.downloading(fraction: 1.5, fileIndex: 1, fileCount: 1))
        onEvent(.verifying)
        onEvent(.ready)
    }

    func emit(_ event: ModelDownloadClientEvent) { eventHandler?(event) }
    func cancel() {}
}

@MainActor
private final class DelayedDownloadClient: ModelDownloadClient {
    var requirements: [ModelRequirement] = []
    var handlers: [String: (@MainActor (ModelDownloadClientEvent) -> Void)] = [:]
    var waiters: [String: CheckedContinuation<Void, Error>] = [:]

    func download(_ requirement: ModelRequirement, onEvent: @escaping @MainActor (ModelDownloadClientEvent) -> Void) async throws {
        requirements.append(requirement)
        handlers[key(requirement)] = onEvent
        try await withCheckedThrowingContinuation { continuation in
            waiters[key(requirement)] = continuation
        }
    }

    func waitUntilStarted(_ requirement: ModelRequirement) async {
        while !requirements.contains(requirement) { await Task.yield() }
    }

    func finish(_ requirement: ModelRequirement) {
        handlers[key(requirement)]?(.ready)
        waiters.removeValue(forKey: key(requirement))?.resume()
    }

    func cancel() {}

    private func key(_ requirement: ModelRequirement) -> String {
        switch requirement {
        case let .whisper(spec): return "whisper:\(spec.id)"
        case let .parakeet(modelID, revision): return "parakeet:\(modelID):\(revision)"
        }
    }
}

@MainActor
private final class DownloadSchedulerFake: ModelDownloadScheduling {
    var delays: [TimeInterval] = []
    func schedule(after delay: TimeInterval, _ operation: @escaping @MainActor () -> Void) {
        delays.append(delay)
    }
}
