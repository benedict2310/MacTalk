import Foundation

protocol EngineSelectionLoader: Sendable {
    func load(selection: EngineSelection) async throws -> any ASREngine
}

/// The result of resolving a selection. Resolution never performs a download;
/// callers must hand a requirement to ModelDownloadCoordinator first.
enum EngineResolution {
    case ready(any ASREngine)
    case requiresDownload(ModelRequirement)
    case failed(String)
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
}

@MainActor
protocol EngineLifecycleCoordinating: EngineResolving {
    var state: EngineLifecycleState { get }
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

    private var operation: Task<EngineResolution, Never>?
    private var operationID: UUID?
    private var operationSelection: EngineSelection?
    private var requestOperations: [UUID: UUID] = [:]
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
        requestOperations[requestID] = operationID

        if recordingActive,
           case let .ready(loadedSelection, engine) = state {
            // Settings edits never replace an engine used by an active session.
            // A new request will resolve normally after recordingActive is false.
            return loadedSelection == selection ? .ready(engine) : .failed("An active recording owns a different engine.")
        }

        if case let .ready(loadedSelection, engine) = state, loadedSelection == selection {
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
            return await operation.value
        }

        operation?.cancel()
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
            } catch {
                return .failed(error.localizedDescription)
            }
        }
        operation = task
        let result = await task.value

        guard operationID == newID,
              operationSelection == selection else {
            return result
        }
        operation = nil
        operationID = nil
        operationSelection = nil
        switch result {
        case let .ready(engine): state = .ready(selection: selection, engine: engine)
        case .requiresDownload: break
        case let .failed(message): state = .failed(selection: selection, message: message)
        }
        return result
    }

    func cancel(requestID: UUID) {
        requestOperations.removeValue(forKey: requestID)
        guard requestOperations.values.allSatisfy({ $0 != operationID }) else { return }
        operation?.cancel()
        operation = nil
        operationID = nil
        operationSelection = nil
        if case let .loading(_, selection) = state {
            state = .failed(selection: selection, message: "Engine loading was cancelled.")
        }
    }

    func prewarm(_ selection: EngineSelection) {
        guard !recordingActive else { return }
        let requestID = UUID()
        Task { @MainActor [weak self] in
            _ = await self?.resolve(selection, requestID: requestID)
            self?.requestOperations.removeValue(forKey: requestID)
        }
    }

    func settingsChanged(to snapshot: SettingsSnapshot, recordingActive: Bool) {
        self.recordingActive = recordingActive
        guard let selection = selection(for: snapshot) else { return }
        if recordingActive {
            deferredSelection = selection
        } else if deferredSelection != selection {
            deferredSelection = nil
            // Do not synchronously load on settings notifications. Idle
            // prewarming is cancellable and never blocks a recording start.
            prewarm(selection)
        }
    }

    func clear() {
        operation?.cancel()
        operation = nil
        operationID = nil
        operationSelection = nil
        requestOperations.removeAll()
        deferredSelection = nil
        state = .empty
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
