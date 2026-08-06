import CoreML
import CryptoKit
import Foundation
import FluidAudio

/// The compute-unit policy is immutable so a loaded byte asset cannot change
/// policy as it crosses an async boundary.
enum CoreMLComputeUnitPolicy: Sendable {
    case cpuOnly
    case all
    case cpuAndGPU
    case cpuAndNeuralEngine

    var computeUnits: MLComputeUnits {
        switch self {
        case .cpuOnly: return .cpuOnly
        case .all: return .all
        case .cpuAndGPU: return .cpuAndGPU
        case .cpuAndNeuralEngine: return .cpuAndNeuralEngine
        }
    }
}

/// Retains the exact source bytes and MLModelAsset alongside CoreML's loaded
/// model. Retention is deliberate: CoreML asset lifetime behavior is SDK
/// dependent, and keeping the owned buffers prevents a later path lookup or
/// mutable file mapping from becoming the model's source.
final class LoadedCoreMLByteAsset: @unchecked Sendable {
    let model: MLModel
    let asset: MLModelAsset
    let bytes: VerifiedCoreMLAssetBytes

    init(model: MLModel, asset: MLModelAsset, bytes: VerifiedCoreMLAssetBytes) {
        self.model = model
        self.asset = asset
        self.bytes = bytes
    }
}

/// Production CoreML byte-loader primitive for verified Parakeet snapshots.
/// Callers must first obtain `VerifiedCoreMLAssetBytes` from the
/// descriptor-bound source snapshot provider.
struct CoreMLByteAssetLoader: Sendable {
    private static let blobKey = URL(string: "weights/weight.bin")!

    func load(
        _ bytes: VerifiedCoreMLAssetBytes,
        computeUnits: CoreMLComputeUnitPolicy
    ) async throws -> LoadedCoreMLByteAsset {
        try validate(bytes.specification)
        try validate(bytes.weights)
        var configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits.computeUnits
        let asset = try MLModelAsset(
            specification: bytes.specification.data,
            blobMapping: [Self.blobKey: bytes.weights.data]
        )
        let model = try await MLModel.load(asset: asset, configuration: configuration)
        return LoadedCoreMLByteAsset(model: model, asset: asset, bytes: bytes)
    }

    private func validate(_ bytes: VerifiedArtifactBytes) throws {
        guard Int64(bytes.data.count) == bytes.identity.size,
              SHA256.hash(data: bytes.data).map({ String(format: "%02x", $0) }).joined() == bytes.identity.sha256 else {
            throw CoreMLByteAssetLoaderError.integrityFailure(bytes.identity.path)
        }
    }
}

enum CoreMLByteAssetLoaderError: Error, Equatable {
    case integrityFailure(String)
}

/// Narrow compatibility seam for FluidAudio 0.15.5. It intentionally only
/// exercises the public initializer; inference remains owned by later engine
/// wiring and is not part of this fixture task.
enum DirectAsrModelsFactory {
    static func make(
        encoder: MLModel,
        preprocessor: MLModel,
        decoder: MLModel,
        joint: MLModel,
        configuration: MLModelConfiguration,
        vocabulary: [Int: String]
    ) -> AsrModels {
        AsrModels(
            encoder: encoder,
            preprocessor: preprocessor,
            decoder: decoder,
            joint: joint,
            configuration: configuration,
            vocabulary: vocabulary,
            version: .v3
        )
    }
}
