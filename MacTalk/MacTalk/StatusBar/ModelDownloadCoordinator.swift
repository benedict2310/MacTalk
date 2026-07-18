import Foundation

enum ModelDownloadPhase: Equatable {
    case idle
    case downloading(fraction: Double, fileIndex: Int?, fileCount: Int?)
    case verifying
    case ready
    case failed(message: String)
}

struct ModelDownloadViewState: Equatable {
    let operationID: UUID?
    let requestID: UUID?
    let requirement: ModelRequirement?
    let phase: ModelDownloadPhase

    init(
        operationID: UUID?,
        requirement: ModelRequirement?,
        phase: ModelDownloadPhase,
        requestID: UUID? = nil
    ) {
        self.operationID = operationID
        self.requestID = requestID
        self.requirement = requirement
        self.phase = phase
    }

    static let idle = ModelDownloadViewState(
        operationID: nil, requirement: nil, phase: .idle
    )
}

enum ModelDownloadClientEvent: Equatable {
    case downloading(fraction: Double, fileIndex: Int?, fileCount: Int?)
    case verifying
    case ready
}

@MainActor
protocol ModelDownloadClient: AnyObject {
    func download(
        _ requirement: ModelRequirement,
        onEvent: @escaping @MainActor (ModelDownloadClientEvent) -> Void
    ) async throws
    func cancel()
}

@MainActor
protocol ModelDownloadScheduling: AnyObject {
    func schedule(after delay: TimeInterval, _ operation: @escaping @MainActor () -> Void)
}

@MainActor
final class DispatchModelDownloadScheduler: ModelDownloadScheduling {
    func schedule(after delay: TimeInterval, _ operation: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + max(delay, 0), execute: operation)
    }
}

@MainActor
protocol ModelDownloadCoordinating: AnyObject {
    var state: ModelDownloadViewState { get }
    var onStateChanged: ((ModelDownloadViewState) -> Void)? { get set }
    func download(_ requirement: ModelRequirement, requestID: UUID) async throws
    func cancel(requestID: UUID)
}

/// Owns one tagged download operation. Downloader callbacks are accepted only
/// while both operation and request identifiers still match.
@MainActor
final class ModelDownloadCoordinator: ModelDownloadCoordinating {
    private let client: any ModelDownloadClient
    private let scheduler: any ModelDownloadScheduling
    private let autoHideDelay: TimeInterval
    private(set) var state: ModelDownloadViewState = .idle
    var onStateChanged: ((ModelDownloadViewState) -> Void)?

    private var operation: Task<Void, Error>?
    private var activeOperationID: UUID?
    private var activeRequestID: UUID?
    private var activeRequirement: ModelRequirement?
    private var terminal = false

    init(
        client: any ModelDownloadClient,
        scheduler: any ModelDownloadScheduling = DispatchModelDownloadScheduler(),
        autoHideDelay: TimeInterval = 2
    ) {
        self.client = client
        self.scheduler = scheduler
        self.autoHideDelay = autoHideDelay
    }

    func download(_ requirement: ModelRequirement, requestID: UUID) async throws {
        if let activeRequirement, activeRequirement != requirement {
            throw ModelDownloadCoordinatorError.anotherOperationInProgress
        }
        if activeOperationID != nil, activeRequestID == requestID, let operation {
            return try await operation.value
        }

        operation?.cancel()
        client.cancel()
        let operationID = UUID()
        activeOperationID = operationID
        activeRequestID = requestID
        activeRequirement = requirement
        terminal = false
        publish(operationID: operationID, requestID: requestID, requirement: requirement, phase: .downloading(fraction: 0, fileIndex: nil, fileCount: nil))

        let client = self.client
        let task = Task { @MainActor [weak self] in
            do {
                try await client.download(requirement) { [weak self] event in
                    guard let self,
                          self.activeOperationID == operationID,
                          self.activeRequestID == requestID,
                          self.activeRequirement == requirement,
                          !self.terminal else { return }
                    switch event {
                    case let .downloading(fraction, index, count):
                        self.publish(operationID: operationID, requestID: requestID, requirement: requirement, phase: .downloading(fraction: min(max(fraction, 0), 1), fileIndex: index, fileCount: count))
                    case .verifying:
                        self.publish(operationID: operationID, requestID: requestID, requirement: requirement, phase: .verifying)
                    case .ready:
                        self.publish(operationID: operationID, requestID: requestID, requirement: requirement, phase: .ready)
                    }
                }
                guard self?.isCurrent(operationID, requestID, requirement) == true else { return }
                self?.terminal = true
                self?.publish(operationID: operationID, requestID: requestID, requirement: requirement, phase: .ready)
                self?.scheduleHide(operationID: operationID)
            } catch {
                guard let self, self.isCurrent(operationID, requestID, requirement), !self.terminal else { return }
                self.terminal = true
                self.publish(operationID: operationID, requestID: requestID, requirement: requirement, phase: .failed(message: error.localizedDescription))
                self.scheduleHide(operationID: operationID)
                throw error
            }
        }
        operation = task
        do {
            try await task.value
        } catch {
            // Keep the terminal failure visible; callers receive the original
            // error so recording state can decide whether to retry.
            throw error
        }
    }

    func cancel(requestID: UUID) {
        guard activeRequestID == requestID, activeOperationID != nil else { return }
        terminal = true
        operation?.cancel()
        operation = nil
        client.cancel()
        let operationID = activeOperationID!
        guard let requirement = activeRequirement else { return }
        activeOperationID = nil
        activeRequestID = nil
        activeRequirement = nil
        publish(operationID: operationID, requestID: requestID, requirement: requirement, phase: .failed(message: "Model download was cancelled."))
    }

    private func isCurrent(_ operationID: UUID, _ requestID: UUID, _ requirement: ModelRequirement) -> Bool {
        activeOperationID == operationID && activeRequestID == requestID && activeRequirement == requirement
    }

    private func publish(operationID: UUID, requestID: UUID, requirement: ModelRequirement, phase: ModelDownloadPhase) {
        state = ModelDownloadViewState(operationID: operationID, requirement: requirement, phase: phase, requestID: requestID)
        onStateChanged?(state)
    }

    private func scheduleHide(operationID: UUID) {
        scheduler.schedule(after: autoHideDelay) { [weak self] in
            guard let self, self.activeOperationID == operationID, self.terminal else { return }
            self.operation = nil
            self.activeOperationID = nil
            self.activeRequestID = nil
            self.activeRequirement = nil
            self.state = .idle
            self.onStateChanged?(self.state)
        }
    }
}

enum ModelDownloadCoordinatorError: Error, LocalizedError, Equatable {
    case anotherOperationInProgress
    case cancelled

    var errorDescription: String? {
        switch self {
        case .anotherOperationInProgress: return "Another model download is currently in progress."
        case .cancelled: return "Model download was cancelled."
        }
    }
}

