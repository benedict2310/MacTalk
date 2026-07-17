import Foundation

struct DefaultEngineSelectionLoader: EngineSelectionLoader {
    typealias IntegrityValidator = @Sendable (URL, ModelSpec) throws -> Void
    typealias WhisperEngineFactory = @Sendable (ModelSpec, URL) -> (any ASREngine)?

    private let integrityValidator: IntegrityValidator
    private let modelPath: @Sendable (ModelSpec) -> URL
    private let whisperEngineFactory: WhisperEngineFactory

    init(
        integrityValidator: @escaping IntegrityValidator = { source, spec in
            try ModelIntegrityVerifier.validate(source: source, spec: spec)
        },
        modelPath: @escaping @Sendable (ModelSpec) -> URL = { spec in
            ModelStore.path(for: spec)
        },
        whisperEngineFactory: @escaping WhisperEngineFactory = { spec, url in
            NativeWhisperEngine(modelSpec: spec, modelURL: url)
        }
    ) {
        self.integrityValidator = integrityValidator
        self.modelPath = modelPath
        self.whisperEngineFactory = whisperEngineFactory
    }

    func load(selection: EngineSelection) async throws -> any ASREngine {
        switch selection.provider {
        case .whisper:
            guard let spec = ModelCatalog.findById(selection.modelID) else {
                throw NSError(domain: "MacTalk.EngineSelection", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "The selected Whisper model is not available in the model catalog."
                ])
            }

            let modelURL = modelPath(spec)
            do {
                // A path is not evidence that a model is safe to load. Validate
                // the catalog-selected artifact immediately before initialization.
                try integrityValidator(modelURL, spec)
            } catch {
                throw NSError(domain: "MacTalk.EngineSelection", code: 4, userInfo: [
                    NSLocalizedDescriptionKey: "The selected Whisper model failed integrity validation.",
                    NSUnderlyingErrorKey: error
                ])
            }

            guard let engine = whisperEngineFactory(spec, modelURL) else {
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
