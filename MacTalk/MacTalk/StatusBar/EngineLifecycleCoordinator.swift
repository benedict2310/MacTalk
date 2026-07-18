import Foundation

/// Immutable provider/model/revision identity for one engine lifecycle.
struct EngineSelection: Equatable, Sendable {
    let provider: ASRProvider
    let modelID: String
    let revision: String

    static func whisper(_ spec: ModelSpec) -> EngineSelection {
        EngineSelection(provider: .whisper, modelID: spec.id, revision: spec.sha256)
    }

    static let parakeet = EngineSelection(
        provider: .parakeet,
        modelID: "parakeet-tdt-0.6b-v3",
        revision: "aed02740059203c4a87495924f685de3722ae9ce"
    )
}

protocol EngineSelectionLoader: Sendable {
    func load(selection: EngineSelection) async throws -> any ASREngine
}

/// The result of resolving a selection. Resolution never performs a download;
/// callers must hand a requirement to ModelDownloadCoordinator first.
enum EngineResolution {
    case ready(any ASREngine)
    case requiresDownload(ModelRequirement)
    case failed(String)
    /// The request was superseded by a newer selection.
    case stale
    /// The request was explicitly cancelled or abandoned.
    case cancelled
}

enum EngineLifecycleState {
    case empty
    case loading(operationID: UUID, selection: EngineSelection)
    case ready(selection: EngineSelection, engine: any ASREngine)
    case failed(selection: EngineSelection, message: String)
}

@MainActor
protocol EngineResolving: AnyObject {
    func resolve(_ selection: EngineSelection, requestID: UUID) async -> EngineResolution
    func cancel(requestID: UUID)
    func recordingActivityChanged(_ active: Bool)
}

@MainActor
protocol EngineLifecycleCoordinating: EngineResolving {
    var state: EngineLifecycleState { get }
    var onEffect: ((StatusBarEffect) -> Void)? { get set }
    func prewarm(_ selection: EngineSelection)
    func settingsChanged(to snapshot: SettingsSnapshot, recordingActive: Bool)
    func clear()
}

/// Sole owner of the loaded ASR engine and its complete provider/model/revision
/// identity. The coordinator deliberately knows nothing about model stores or
/// network clients: those are supplied by the composition root.
@MainActor
final class EngineLifecycleCoordinator: EngineLifecycleCoordinating {
    private let loader: any EngineSelectionLoader
    private let availability: @MainActor (EngineSelection) -> Bool
    var state: EngineLifecycleState = .empty
    var onEffect: ((StatusBarEffect) -> Void)?

    private var operation: Task<EngineResolution, Never>?
    private var operationID: UUID?
    private var operationSelection: EngineSelection?
    private var requestOperations: [UUID: UUID] = [:]
    private var completedOperationID: UUID?
    private var supersededOperationIDs: Set<UUID> = []
    private var cancelledOperationIDs: Set<UUID> = []
    private var cancelledRequestIDs: Set<UUID> = []
    private var deferredSelection: EngineSelection?
    private var recordingActive = false

    init(
        loader: any EngineSelectionLoader,
        availability: @escaping @MainActor (EngineSelection) -> Bool = { _ in true }
    ) {
        self.loader = loader
        self.availability = availability
    }

    func resolve(_ selection: EngineSelection, requestID: UUID) async -> EngineResolution {
        cancelledRequestIDs.remove(requestID)
        requestOperations[requestID] = operationID

        if recordingActive,
           case let .ready(loadedSelection, engine) = state {
            // Settings edits never replace an engine used by an active session.
            // A new request will resolve normally after recordingActive is false.
            return loadedSelection == selection ? .ready(engine) : .failed("An active recording owns a different engine.")
        }

        if case let .ready(loadedSelection, engine) = state, loadedSelection == selection {
            // Preserve an operation tag even after the task has completed. This
            // lets callers reject a result if a newer selection is installed
            // before their continuation resumes.
            let completedID = completedOperationID ?? UUID()
            completedOperationID = completedID
            requestOperations[requestID] = completedID
            return .ready(engine)
        }

        guard availability(selection) else {
            let requirement = requirement(for: selection)
            state = .failed(selection: selection, message: "The selected model is not available locally.")
            return requirement.map(EngineResolution.requiresDownload) ?? .failed("The selected engine is not available locally.")
        }

        if let operation,
           operationSelection == selection,
           let operationID {
            requestOperations[requestID] = operationID
            let result = await operation.value
            return validated(result, requestID: requestID, operationID: operationID, selection: selection)
        }

        if let oldOperationID = operationID {
            supersededOperationIDs.insert(oldOperationID)
        }
        operation?.cancel()
        completedOperationID = nil
        let newID = UUID()
        operationID = newID
        operationSelection = selection
        requestOperations[requestID] = newID
        state = .loading(operationID: newID, selection: selection)

        let loader = self.loader
        let task: Task<EngineResolution, Never> = Task { @MainActor in
            do {
                let engine = try await loader.load(selection: selection)
                guard engine.provider == selection.provider else {
                    return .failed("Loaded engine provider does not match the selected provider.")
                }
                return .ready(engine)
            } catch is CancellationError {
                return .cancelled
            } catch {
                return .failed(error.localizedDescription)
            }
        }
        operation = task
        let result = await task.value

        guard operationID == newID,
              operationSelection == selection else {
            return validated(result, requestID: requestID, operationID: newID, selection: selection)
        }
        operation = nil
        operationID = nil
        operationSelection = nil
        completedOperationID = newID
        switch result {
        case let .ready(engine): state = .ready(selection: selection, engine: engine)
        case .requiresDownload: break
        case let .failed(message): state = .failed(selection: selection, message: message)
        case .stale, .cancelled: break
        }
        return validated(result, requestID: requestID, operationID: newID, selection: selection)
    }

    func recordingActivityChanged(_ active: Bool) {
        recordingActive = active
        guard !active, let deferredSelection else { return }
        self.deferredSelection = nil
        prewarm(deferredSelection)
    }

    func cancel(requestID: UUID) {
        cancelledRequestIDs.insert(requestID)
        requestOperations.removeValue(forKey: requestID)
        guard let currentOperationID = operationID,
              requestOperations.values.allSatisfy({ $0 != currentOperationID }) else { return }
        cancelledOperationIDs.insert(currentOperationID)
        operation?.cancel()
        operation = nil
        operationID = nil
        operationSelection = nil
        completedOperationID = nil
        if case let .loading(_, selection) = state {
            state = .failed(selection: selection, message: "Engine loading was cancelled.")
        }
    }

    func prewarm(_ selection: EngineSelection) {
        guard !recordingActive else { return }
        let requestID = UUID()
        Task { @MainActor [weak self] in
            let result = await self?.resolve(selection, requestID: requestID)
            if case let .requiresDownload(requirement) = result {
                self?.onEffect?(.confirmDownload(requirement))
            }
            self?.requestOperations.removeValue(forKey: requestID)
        }
    }

    func settingsChanged(to snapshot: SettingsSnapshot, recordingActive: Bool) {
        self.recordingActive = recordingActive
        guard let selection = selection(for: snapshot) else { return }
        if recordingActive {
            deferredSelection = selection
            return
        }

        // Do not synchronously load on settings notifications. Idle prewarming
        // is cancellable and never blocks a recording start. A selection that
        // was deferred by an active recording owns this first idle prewarm.
        let selectionToPrewarm = deferredSelection ?? selection
        deferredSelection = nil
        prewarm(selectionToPrewarm)
    }

    func clear() {
        recordingActive = false
        if let currentOperationID = operationID {
            cancelledOperationIDs.insert(currentOperationID)
        }
        operation?.cancel()
        operation = nil
        operationID = nil
        operationSelection = nil
        completedOperationID = nil
        requestOperations.removeAll()
        cancelledRequestIDs.removeAll()
        deferredSelection = nil
        state = .empty
    }

    func isCurrent(requestID: UUID, selection: EngineSelection) -> Bool {
        guard case let .ready(loadedSelection, _) = state,
              loadedSelection == selection else { return false }
        return isCurrentRequest(requestID: requestID, selection: selection)
    }

    func isCurrentRequest(requestID: UUID, selection: EngineSelection) -> Bool {
        guard let completedOperationID,
              requestOperations[requestID] == completedOperationID else { return false }
        switch state {
        case let .ready(loadedSelection, _), let .failed(loadedSelection, _):
            return loadedSelection == selection
        case .empty, .loading:
            return false
        }
    }

    private func validated(
        _ result: EngineResolution,
        requestID: UUID,
        operationID: UUID,
        selection: EngineSelection
    ) -> EngineResolution {
        guard !cancelledRequestIDs.contains(requestID),
              requestOperations[requestID] == operationID,
              (self.operationID == operationID || completedOperationID == operationID),
              (operationSelection == selection || completedOperationID == operationID) else {
            return cancelledOperationIDs.contains(operationID) ? .cancelled : .stale
        }
        return result
    }

    private func selection(for snapshot: SettingsSnapshot) -> EngineSelection? {
        switch snapshot.provider {
        case .whisper:
            guard let spec = snapshot.whisperModel else { return nil }
            return .whisper(spec)
        case .parakeet:
            return .parakeet
        }
    }

    private func requirement(for selection: EngineSelection) -> ModelRequirement? {
        switch selection.provider {
        case .whisper:
            guard let spec = ModelCatalog.findById(selection.modelID) else { return nil }
            return .whisper(spec)
        case .parakeet:
            return .parakeet(modelID: selection.modelID, revision: selection.revision)
        }
    }
}
