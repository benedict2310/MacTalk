import Foundation

/// Stable provider/model/revision identity for one loaded engine.
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

struct PendingSettingsSnapshot: Equatable, Sendable {
    let engine: EngineSelection
}

/// Compatibility name for clients that have not yet moved to
/// EngineLifecycleCoordinator. It is an alias, not a second cache or owner.
typealias EngineReloadCoordinator = EngineLifecycleCoordinator

@MainActor
extension EngineLifecycleCoordinator {
    var loadedSelection: EngineSelection? {
        guard case let .ready(selection, _) = state else { return nil }
        return selection
    }

    var loadedEngine: (any ASREngine)? {
        guard case let .ready(_, engine) = state else { return nil }
        return engine
    }

    func reconcile(
        pending: PendingSettingsSnapshot,
        isRecording: Bool,
        requestID: UUID = UUID()
    ) async throws -> any ASREngine {
        if isRecording, let loadedEngine { return loadedEngine }
        switch await resolve(pending.engine, requestID: requestID) {
        case let .ready(engine): return engine
        case .requiresDownload:
            throw NSError(domain: "MacTalk.EngineSelection", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "The selected model is not available locally."
            ])
        case let .failed(message):
            throw NSError(domain: "MacTalk.EngineSelection", code: 1, userInfo: [
                NSLocalizedDescriptionKey: message
            ])
        case .stale, .cancelled:
            throw NSError(domain: "MacTalk.EngineSelection", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "The selected engine request was superseded or cancelled."
            ])
        }
    }

    func adoptLoadedEngine(_ engine: any ASREngine, selection: EngineSelection) {
        state = .ready(selection: selection, engine: engine)
    }

    func clearLoadedEngine() { clear() }
}
