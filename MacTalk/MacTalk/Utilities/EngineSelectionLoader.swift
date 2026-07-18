import Foundation

struct DefaultEngineSelectionLoader: EngineSelectionLoader {
    typealias IntegrityValidator = @Sendable (URL, ModelSpec) throws -> Void
    typealias WhisperEngineFactory = @Sendable (ModelSpec, URL) -> (any ASREngine)?
    typealias ParakeetEngineFactory = @Sendable () -> any ASREngine

    private let integrityValidator: IntegrityValidator
    private let modelPath: @Sendable (ModelSpec) -> URL
    private let whisperEngineFactory: WhisperEngineFactory
    private let parakeetEngineFactory: ParakeetEngineFactory

    init(
        integrityValidator: @escaping IntegrityValidator = { source, spec in
            try ModelIntegrityVerifier.validate(source: source, spec: spec)
        },
        modelPath: @escaping @Sendable (ModelSpec) -> URL = { spec in
            ModelStore.path(for: spec)
        },
        whisperEngineFactory: @escaping WhisperEngineFactory = { spec, url in
            NativeWhisperEngine(modelSpec: spec, modelURL: url)
        },
        parakeetEngineFactory: @escaping ParakeetEngineFactory = { ParakeetEngine() }
    ) {
        self.integrityValidator = integrityValidator
        self.modelPath = modelPath
        self.whisperEngineFactory = whisperEngineFactory
        self.parakeetEngineFactory = parakeetEngineFactory
    }

    func isAvailable(selection: EngineSelection) -> Bool {
        switch selection.provider {
        case .whisper:
            guard let spec = ModelCatalog.findById(selection.modelID), spec.sha256 == selection.revision else { return false }
            return (try? integrityValidator(modelPath(spec), spec)) != nil
        case .parakeet:
            return ParakeetModelDownloader.modelsAvailable()
        }
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
            guard selection.modelID == EngineSelection.parakeet.modelID,
                  selection.revision == EngineSelection.parakeet.revision,
                  ParakeetModelDownloader.modelsAvailable() else {
                throw NSError(domain: "MacTalk.EngineSelection", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "The selected Parakeet model is not available locally."
                ])
            }
            // Parakeet is intentionally lazy: microphone capture may begin
            // before its expensive CoreML preparation is performed.
            return parakeetEngineFactory()
        }
    }
}
