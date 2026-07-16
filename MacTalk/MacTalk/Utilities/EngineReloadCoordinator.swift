import Foundation

/// Stable identity for the engine loaded by the app.
///
/// The revision is deliberately separate from the model ID: a catalog entry can
/// point at a new artifact without changing its display name.
struct EngineSelection: Equatable, Sendable {
    let provider: ASRProvider
    let modelID: String
    let revision: String

    static func whisper(_ spec: ModelSpec) -> EngineSelection {
        return EngineSelection(provider: .whisper, modelID: spec.id, revision: spec.sha256)
    }

    static let parakeet = EngineSelection(
        provider: .parakeet,
        modelID: "parakeet-tdt-0.6b-v3",
        revision: "v3"
    )
}

struct PendingSettingsSnapshot: Equatable, Sendable {
    let engine: EngineSelection
}

protocol EngineSelectionLoader: Sendable {
    func load(selection: EngineSelection) async throws -> any ASREngine
}

/// Reconciles the selected engine only at recording-session boundaries.
/// Settings edits never replace the engine owned by an active recording.
@MainActor
final class EngineReloadCoordinator {
    private(set) var loadedSelection: EngineSelection?
    private(set) var loadedEngine: (any ASREngine)?
    private let loader: any EngineSelectionLoader

    init(loader: any EngineSelectionLoader) {
        self.loader = loader
    }

    func reconcile(
        pending: PendingSettingsSnapshot,
        isRecording: Bool
    ) async throws -> any ASREngine {
        if isRecording, let loadedEngine {
            return loadedEngine
        }
        if loadedSelection == pending.engine, let loadedEngine {
            return loadedEngine
        }

        let engine = try await loader.load(selection: pending.engine)
        loadedSelection = pending.engine
        loadedEngine = engine
        return engine
    }

    func adoptLoadedEngine(_ engine: any ASREngine, selection: EngineSelection) {
        loadedSelection = selection
        loadedEngine = engine
    }

    func clearLoadedEngine() {
        loadedSelection = nil
        loadedEngine = nil
    }
}
