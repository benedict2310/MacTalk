import XCTest
@testable import MacTalk

/// Explicit opt-in lane only. It never resolves a model, downloads, or uses
/// the application model store; the caller supplies an already provisioned
/// verified path and its catalog filename.
final class RealModelLaneTests: XCTestCase {
    func test_existing_local_whisper_model_prepares_offline() async throws {
        guard let path = ProcessInfo.processInfo.environment["MACTALK_EXISTING_MODEL_PATH"], !path.isEmpty else {
            throw XCTSkip("Set MACTALK_EXISTING_MODEL_PATH to run the opt-in local-model lane")
        }
        let modelURL = URL(fileURLWithPath: path)
        let filename = modelURL.lastPathComponent
        guard let spec = ModelCatalog.findByFilename(filename) else {
            throw XCTSkip("Model filename is not in the pinned catalog: \(filename)")
        }
        guard let engine = NativeWhisperEngine(modelSpec: spec, modelURL: modelURL) else {
            throw XCTSkip("Existing model failed pinned integrity validation")
        }
        try await engine.prepare()
        await engine.reset()
    }
}
