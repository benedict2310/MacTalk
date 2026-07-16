import Foundation

struct DefaultEngineSelectionLoader: EngineSelectionLoader {
    func load(selection: EngineSelection) async throws -> any ASREngine {
        switch selection.provider {
        case .whisper:
            guard let spec = ModelCatalog.findById(selection.modelID), ModelStore.exists(spec) else {
                throw NSError(domain: "MacTalk.EngineSelection", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "The selected Whisper model is not available locally."
                ])
            }
            guard let engine = NativeWhisperEngine(modelURL: ModelStore.path(for: spec)) else {
                throw NSError(domain: "MacTalk.EngineSelection", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "The selected Whisper model could not be initialized."
                ])
            }
            return engine
        case .parakeet:
            guard ParakeetModelDownloader().modelsAvailable() else {
                throw NSError(domain: "MacTalk.EngineSelection", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "The selected Parakeet model is not available locally."
                ])
            }
            let engine = ParakeetEngine()
            try await engine.prepare()
            return engine
        }
    }
}
