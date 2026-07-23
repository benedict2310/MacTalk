import CoreML
import CryptoKit
import Foundation
import FluidAudio

/// Immutable compute-unit policy used when loading one Parakeet source snapshot.
enum ParakeetModelLoadPolicy: Sendable, Equatable {
    case cpuOnly
    case all
    case cpuAndGPU
    case cpuAndNeuralEngine

    static let production: Self = .cpuAndNeuralEngine

    fileprivate var coreMLPolicy: CoreMLComputeUnitPolicy {
        switch self {
        case .cpuOnly: return .cpuOnly
        case .all: return .all
        case .cpuAndGPU: return .cpuAndGPU
        case .cpuAndNeuralEngine: return .cpuAndNeuralEngine
        }
    }

    fileprivate var computeUnits: MLComputeUnits {
        coreMLPolicy.computeUnits
    }
}

struct ParakeetExpectedArtifact: Hashable, Sendable {
    let component: ParakeetSourceComponent?
    let role: String
    let entry: GeneratedParakeetManifestEntry
}

protocol VerifiedParakeetComponentLoading: Sendable {
    func load(_ bytes: VerifiedCoreMLAssetBytes, computeUnits: CoreMLComputeUnitPolicy) async throws -> LoadedCoreMLByteAsset
}

extension CoreMLByteAssetLoader: VerifiedParakeetComponentLoading {}

/// The complete retained result. CoreML's asset/model lifetime is SDK-dependent;
/// retaining the assets, exact owned bytes and complete verified snapshot keeps
/// the load boundary independent of mutable filesystem paths. The loader is
/// sequential to avoid adding unmeasured peak-memory claims for the large
/// production Encoder weight.
final class VerifiedParakeetLoadedModels: @unchecked Sendable {
    let models: AsrModels
    let assets: [ParakeetSourceComponent: LoadedCoreMLByteAsset]
    let snapshot: VerifiedParakeetSourceSnapshot
    let configuration: MLModelConfiguration

    init(models: AsrModels, assets: [ParakeetSourceComponent: LoadedCoreMLByteAsset], snapshot: VerifiedParakeetSourceSnapshot, configuration: MLModelConfiguration) {
        self.models = models
        self.assets = assets
        self.snapshot = snapshot
        self.configuration = configuration
    }
}

enum VerifiedParakeetModelLoaderError: Error, Equatable, Sendable {
    case identityMismatch
    case artifactMismatch
    case artifactByteMismatch
    case duplicateArtifact
    case vocabularyMalformed
    case cancelled
}

protocol VerifiedParakeetModelLoading: Sendable {
    func load(snapshot: VerifiedParakeetSourceSnapshot, policy: ParakeetModelLoadPolicy) async throws -> VerifiedParakeetLoadedModels
}

final class VerifiedParakeetModelLoader: VerifiedParakeetModelLoading, @unchecked Sendable {
    private let expectedIdentity: ParakeetSourceIdentity
    private let expectedArtifacts: [ParakeetExpectedArtifact]
    private let componentLoader: any VerifiedParakeetComponentLoading
    private let beforePublish: (@Sendable () async -> Void)?

    /// Production initialization is intentionally limited to the generated
    /// immutable source identity and nine generated source entries.
    convenience init() {
        self.init(
            expectedIdentity: .production,
            expectedArtifacts: Self.productionArtifacts,
            componentLoader: CoreMLByteAssetLoader()
        )
    }

    convenience init(expectedIdentity: ParakeetSourceIdentity, expectedArtifacts: [ParakeetExpectedArtifact]) {
        self.init(expectedIdentity: expectedIdentity, expectedArtifacts: expectedArtifacts, componentLoader: CoreMLByteAssetLoader())
    }

    init(expectedIdentity: ParakeetSourceIdentity, expectedArtifacts: [ParakeetExpectedArtifact], componentLoader: any VerifiedParakeetComponentLoading, beforePublish: (@Sendable () async -> Void)? = nil) {
        self.expectedIdentity = expectedIdentity
        self.expectedArtifacts = expectedArtifacts
        self.componentLoader = componentLoader
        self.beforePublish = beforePublish
    }

    func load(snapshot: VerifiedParakeetSourceSnapshot, policy: ParakeetModelLoadPolicy) async throws -> VerifiedParakeetLoadedModels {
        do {
            try checkCancellation()
            try validate(snapshot: snapshot)
            try validateVocabularyBytes(snapshot.vocabulary)
            let vocabulary = try parseVocabulary(snapshot.vocabulary.data)
            var loaded = [ParakeetSourceComponent: LoadedCoreMLByteAsset]()
            for component in ParakeetSourceComponent.allCases {
                try checkCancellation()
                guard let bytes = snapshot.assets[component] else { throw VerifiedParakeetModelLoaderError.artifactMismatch }
                let units: CoreMLComputeUnitPolicy = component == .preprocessor ? .cpuOnly : policy.coreMLPolicy
                let asset = try await componentLoader.load(bytes, computeUnits: units)
                loaded[component] = asset
                try checkCancellation()
            }
            try checkCancellation()
            if let beforePublish { await beforePublish() }
            try checkCancellation()
            guard let preprocessor = loaded[.preprocessor]?.model,
                  let encoder = loaded[.encoder]?.model,
                  let decoder = loaded[.decoder]?.model,
                  let joint = loaded[.joint]?.model else {
                throw VerifiedParakeetModelLoaderError.artifactMismatch
            }
            let configuration = MLModelConfiguration()
            configuration.computeUnits = policy.computeUnits
            let models = DirectAsrModelsFactory.make(
                encoder: encoder,
                preprocessor: preprocessor,
                decoder: decoder,
                joint: joint,
                configuration: configuration,
                vocabulary: vocabulary
            )
            try checkCancellation()
            return VerifiedParakeetLoadedModels(models: models, assets: loaded, snapshot: snapshot, configuration: configuration)
        } catch let error as VerifiedParakeetModelLoaderError {
            throw error
        } catch is CancellationError {
            throw VerifiedParakeetModelLoaderError.cancelled
        }
    }

    private func checkCancellation() throws {
        if Task.isCancelled { throw VerifiedParakeetModelLoaderError.cancelled }
    }

    private func validate(snapshot: VerifiedParakeetSourceSnapshot) throws {
        guard snapshot.identity == expectedIdentity else { throw VerifiedParakeetModelLoaderError.identityMismatch }
        guard expectedArtifacts.count == 9 else { throw VerifiedParakeetModelLoaderError.duplicateArtifact }
        let expectedKeys = expectedArtifacts.map { artifact in
            "\(artifact.component?.rawValue ?? "Vocabulary")|\(artifact.role)|\(artifact.entry.path)"
        }
        guard Set(expectedKeys).count == expectedKeys.count else { throw VerifiedParakeetModelLoaderError.duplicateArtifact }
        guard Set(snapshot.assets.keys) == Set(ParakeetSourceComponent.allCases), snapshot.assets.count == 4 else {
            throw VerifiedParakeetModelLoaderError.artifactMismatch
        }
        for component in ParakeetSourceComponent.allCases {
            guard let asset = snapshot.assets[component], asset.component == component else { throw VerifiedParakeetModelLoaderError.artifactMismatch }
            guard let spec = expectedArtifacts.first(where: { $0.component == component && $0.role == "specification" })?.entry,
                  let weights = expectedArtifacts.first(where: { $0.component == component && $0.role == "weights" })?.entry,
                  asset.specification.identity == spec,
                  asset.weights.identity == weights else {
                throw VerifiedParakeetModelLoaderError.artifactMismatch
            }
        }
        guard let vocabulary = expectedArtifacts.first(where: { $0.component == nil && $0.role == "vocabulary" })?.entry,
              snapshot.vocabulary.identity == vocabulary else {
            throw VerifiedParakeetModelLoaderError.artifactMismatch
        }
    }

    private func validateVocabularyBytes(_ bytes: VerifiedArtifactBytes) throws {
        guard let expected = expectedArtifacts.first(where: { $0.component == nil && $0.role == "vocabulary" })?.entry,
              bytes.identity == expected,
              Int64(bytes.data.count) == expected.size,
              digest(bytes.data) == expected.sha256 else {
            throw VerifiedParakeetModelLoaderError.artifactByteMismatch
        }
    }

    private func parseVocabulary(_ data: Data) throws -> [Int: String] {
        var parser = StrictVocabularyParser(data: data)
        return try parser.parse()
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static let productionArtifacts: [ParakeetExpectedArtifact] = {
        var result = [ParakeetExpectedArtifact]()
        for component in ParakeetSourceComponent.allCases {
            for role in ["specification", "weights"] {
                guard let expectedPath = ParakeetSourcePathContract.expectedPath(component: component, role: role),
                      let entry = GeneratedModelProvenance.parakeetSource.first(where: {
                          $0.component == component.rawValue &&
                          $0.role == role &&
                          $0.path == expectedPath
                      }) else {
                    continue
                }
                result.append(ParakeetExpectedArtifact(component: component, role: role, entry: entry))
            }
        }
        if let vocabulary = GeneratedModelProvenance.parakeetSource.first(where: {
            $0.component == "Vocabulary" &&
            $0.role == "vocabulary" &&
            $0.path == "parakeet_vocab.json"
        }) {
            result.append(ParakeetExpectedArtifact(component: nil, role: "vocabulary", entry: vocabulary))
        }
        return result
    }()
}

private struct StrictVocabularyParser {
    let bytes: [UInt8]
    var index = 0

    init(data: Data) { self.bytes = Array(data) }

    mutating func parse() throws -> [Int: String] {
        skipWhitespace()
        guard consume(123) else { throw VerifiedParakeetModelLoaderError.vocabularyMalformed }
        skipWhitespace()
        guard peek != 125 else { throw VerifiedParakeetModelLoaderError.vocabularyMalformed }
        var result = [Int: String]()
        while true {
            let rawKey = try parseString()
            guard isCanonicalInteger(rawKey), let key = Int(rawKey), result[key] == nil else { throw VerifiedParakeetModelLoaderError.vocabularyMalformed }
            skipWhitespace()
            guard consume(58) else { throw VerifiedParakeetModelLoaderError.vocabularyMalformed }
            skipWhitespace()
            let value = try parseString()
            result[key] = value
            skipWhitespace()
            if consume(125) { break }
            guard consume(44) else { throw VerifiedParakeetModelLoaderError.vocabularyMalformed }
            skipWhitespace()
        }
        skipWhitespace()
        guard index == bytes.count else { throw VerifiedParakeetModelLoaderError.vocabularyMalformed }
        return result
    }

    private var peek: UInt8? { index < bytes.count ? bytes[index] : nil }
    private mutating func consume(_ value: UInt8) -> Bool { guard peek == value else { return false }; index += 1; return true }
    private mutating func skipWhitespace() { while let value = peek, value == 32 || value == 9 || value == 10 || value == 13 { index += 1 } }

    private mutating func parseString() throws -> String {
        guard consume(34) else { throw VerifiedParakeetModelLoaderError.vocabularyMalformed }
        let start = index - 1
        var escaped = false
        while index < bytes.count {
            let value = bytes[index]; index += 1
            if value < 0x20 && !escaped { throw VerifiedParakeetModelLoaderError.vocabularyMalformed }
            if escaped { escaped = false; continue }
            if value == 92 { escaped = true; continue }
            if value == 34 {
                let data = Data(bytes[start..<index])
                guard let string = try? JSONDecoder().decode(String.self, from: data) else { throw VerifiedParakeetModelLoaderError.vocabularyMalformed }
                return string
            }
        }
        throw VerifiedParakeetModelLoaderError.vocabularyMalformed
    }

    private func isCanonicalInteger(_ string: String) -> Bool {
        let utf8 = Array(string.utf8)
        guard !utf8.isEmpty else { return false }
        if utf8.count > 1 && utf8[0] == 48 { return false }
        guard utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return false }
        var value: UInt64 = 0
        for digit in utf8 {
            let next = value.multipliedReportingOverflow(by: 10)
            let sum = next.partialValue.addingReportingOverflow(UInt64(digit - 48))
            if next.overflow || sum.overflow || sum.partialValue > UInt64(Int.max) { return false }
            value = sum.partialValue
        }
        return true
    }
}
