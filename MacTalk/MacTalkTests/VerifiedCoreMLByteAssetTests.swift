import CoreML
import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import MacTalk

final class VerifiedCoreMLByteAssetTests: XCTestCase {
    private var fixtureDirectory: URL!
    private var rootFD: Int32 = -1
    private var rootURL: URL!

    override func setUpWithError() throws {
        let fixture = Bundle(for: Self.self).url(
            forResource: "model",
            withExtension: "mlmodel",
            subdirectory: "VerifiedCoreMLFixture"
        )?.deletingLastPathComponent()
            ?? URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .appendingPathComponent("Fixtures/VerifiedCoreMLFixture", isDirectory: true)
        guard FileManager.default.fileExists(atPath: fixture.appendingPathComponent("model.mlmodel").path) else {
            XCTFail("verified CoreML fixture is not present in the test bundle or checkout")
            throw FixtureError.missing
        }
        fixtureDirectory = fixture
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacTalkCoreMLFixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture.appendingPathComponent("model.mlmodel"), to: rootURL.appendingPathComponent("model.mlmodel"))
        try FileManager.default.createDirectory(at: rootURL.appendingPathComponent("weights"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture.appendingPathComponent("weights/weight.bin"), to: rootURL.appendingPathComponent("weights/weight.bin"))
        rootFD = open(rootURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(rootFD, 0)
    }

    override func tearDownWithError() throws {
        if rootFD >= 0 { _ = close(rootFD); rootFD = -1 }
        if let rootURL { try? FileManager.default.removeItem(at: rootURL) }
    }

    func test_loadsOwnedBytesAndPredictsWithRelativeBlobMapping() async throws {
        let assetBytes = try readFixtureBytes()
        let loaded = try await CoreMLByteAssetLoader().load(assetBytes, computeUnits: .cpuOnly)

        XCTAssertEqual(Set(loaded.model.modelDescription.inputDescriptionsByName.keys), ["x"])
        XCTAssertEqual(Set(loaded.model.modelDescription.outputDescriptionsByName.keys), ["double"])
        XCTAssertEqual(try predict(loaded.model), [2, 4, 6, 8, 10, 12, 14, 16, 18, 20])
    }

    func test_mappingKeyMustBeRelativeWeightsPath() async throws {
        let assetBytes = try readFixtureBytes()
        let specification = assetBytes.specification.data
        let weights = assetBytes.weights.data
        let relativeAsset = try MLModelAsset(
            specification: specification,
            blobMapping: [URL(string: "weights/weight.bin")!: weights]
        )
        _ = try await MLModel.load(asset: relativeAsset, configuration: MLModelConfiguration())

        do {
            let wrongAsset = try MLModelAsset(
                specification: specification,
                blobMapping: [URL(string: "@model_path/weights/weight.bin")!: weights]
            )
            _ = try await MLModel.load(asset: wrongAsset, configuration: MLModelConfiguration())
            XCTFail("CoreML must not accept the @model_path mapping key")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    func test_missingOrCorruptInputsFailClosed() async throws {
        let bytes = try readFixtureBytes()
        let configuration = MLModelConfiguration()
        do {
            let missingBlob = try MLModelAsset(specification: bytes.specification.data, blobMapping: [:])
            _ = try await awaitLoad(missingBlob, configuration: configuration)
            XCTFail("missing blob must fail")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }

        var corruptSpecification = bytes.specification.data
        corruptSpecification[0] ^= 0xff
        do {
            let corruptSpecificationBytes = VerifiedArtifactBytes(
                identity: bytes.specification.identity,
                data: corruptSpecification
            )
            let corruptAssetBytes = VerifiedCoreMLAssetBytes(
                component: .preprocessor,
                specification: corruptSpecificationBytes,
                weights: bytes.weights
            )
            _ = try await CoreMLByteAssetLoader().load(corruptAssetBytes, computeUnits: .cpuOnly)
            XCTFail("corrupt specification must fail")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }

        var corruptWeights = bytes.weights.data
        corruptWeights[0] ^= 0xff
        do {
            let corruptWeightsBytes = VerifiedArtifactBytes(
                identity: bytes.weights.identity,
                data: corruptWeights
            )
            let corruptAssetBytes = VerifiedCoreMLAssetBytes(
                component: .preprocessor,
                specification: bytes.specification,
                weights: corruptWeightsBytes
            )
            _ = try await CoreMLByteAssetLoader().load(corruptAssetBytes, computeUnits: .cpuOnly)
            XCTFail("corrupt weight must fail")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    func test_ownedBytesSurviveReplacingFilesystemPaths() async throws {
        let bytes = try readFixtureBytes()
        try FileManager.default.removeItem(at: rootURL.appendingPathComponent("model.mlmodel"))
        try FileManager.default.removeItem(at: rootURL.appendingPathComponent("weights/weight.bin"))
        let loaded = try await CoreMLByteAssetLoader().load(bytes, computeUnits: .cpuOnly)
        XCTAssertEqual(try predict(loaded.model), [2, 4, 6, 8, 10, 12, 14, 16, 18, 20])
    }

    func test_fixtureManifestMatchesOwnedBytesAndInterface() throws {
        let manifestURL = Bundle(for: Self.self).url(
            forResource: "fixture-manifest",
            withExtension: "json",
            subdirectory: "VerifiedCoreMLFixture"
        ) ?? URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/VerifiedCoreMLFixture/fixture-manifest.json")
        let manifest = try JSONDecoder().decode(FixtureManifest.self, from: Data(contentsOf: manifestURL))
        let bytes = try readFixtureBytes()
        XCTAssertEqual(manifest.model.size, bytes.specification.data.count)
        XCTAssertEqual(manifest.model.sha256, digest(bytes.specification.data))
        XCTAssertEqual(manifest.weights.size, bytes.weights.data.count)
        XCTAssertEqual(manifest.weights.sha256, digest(bytes.weights.data))
        XCTAssertEqual(manifest.input.name, "x")
        XCTAssertEqual(manifest.output.name, "double")
        XCTAssertEqual(manifest.prediction.output, [2, 4, 6, 8, 10, 12, 14, 16, 18, 20])
    }

    func test_directFluidAudioAsrModelsInitializerIsCompatible() async throws {
        let bytes = try readFixtureBytes()
        let loaded = try await CoreMLByteAssetLoader().load(bytes, computeUnits: .cpuOnly)
        let models = DirectAsrModelsFactory.make(
            encoder: loaded.model,
            preprocessor: loaded.model,
            decoder: loaded.model,
            joint: loaded.model,
            configuration: MLModelConfiguration(),
            vocabulary: [0: "<blank>", 1: "fixture"]
        )
        XCTAssertTrue(models.encoder === loaded.model)
        XCTAssertTrue(models.preprocessor === loaded.model)
        XCTAssertTrue(models.decoder === loaded.model)
        XCTAssertTrue(models.joint === loaded.model)
        XCTAssertEqual(models.vocabulary[1], "fixture")
        if case .v3 = models.version {
            // Expected source-loader version.
        } else {
            XCTFail("direct factory must construct v3 AsrModels")
        }
    }

    private func readFixtureBytes() throws -> VerifiedCoreMLAssetBytes {
        let specification = try VerifiedArtifactReader(rootFD: rootFD).read(
            GeneratedParakeetManifestEntry(
                path: "model.mlmodel",
                size: 1182,
                sha256: "c2d71cf780e53498f7c5c741f7bfd7809f417ba09434e490a57fc6341e3f30d8"
            )
        )
        let weights = try VerifiedArtifactReader(rootFD: rootFD).read(
            GeneratedParakeetManifestEntry(
                path: "weights/weight.bin",
                size: 148,
                sha256: "86ea2eefa543a095b45c410ca4daddc2f9c605f7f3ac7822d528c2aa49b8d366"
            )
        )
        return VerifiedCoreMLAssetBytes(component: .preprocessor, specification: specification, weights: weights)
    }

    private func predict(_ model: MLModel) throws -> [Int] {
        let input = try MLMultiArray(shape: [10], dataType: .float32)
        for index in 0..<10 { input[index] = NSNumber(value: index + 1) }
        let provider = try MLDictionaryFeatureProvider(dictionary: ["x": MLFeatureValue(multiArray: input)])
        let output = try model.prediction(from: provider)
        let array = try XCTUnwrap(output.featureValue(for: "double")?.multiArrayValue)
        return (0..<10).map { Int((array[$0] as NSNumber).doubleValue.rounded()) }
    }

    private func awaitLoad(_ asset: MLModelAsset, configuration: MLModelConfiguration) async throws -> MLModel {
        try await MLModel.load(asset: asset, configuration: configuration)
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private enum FixtureError: Error {
        case missing
    }

    private struct FixtureManifest: Decodable {
        let model: Artifact
        let weights: Artifact
        let input: Interface
        let output: Interface
        let prediction: Prediction
        struct Artifact: Decodable { let size: Int; let sha256: String }
        struct Interface: Decodable { let name: String }
        struct Prediction: Decodable { let output: [Int] }
    }
}
