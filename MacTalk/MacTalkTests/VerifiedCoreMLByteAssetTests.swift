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
    private var manifest: FixtureManifest!

    override func setUpWithError() throws {
        let fixture = Bundle(for: Self.self).url(
            forResource: "fixture-manifest",
            withExtension: "json",
            subdirectory: "VerifiedCoreMLFixture"
        )?.deletingLastPathComponent()
            ?? URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .appendingPathComponent("Fixtures/VerifiedCoreMLFixture", isDirectory: true)
        fixtureDirectory = fixture
        manifest = try FixtureManifest(contentsOf: fixture.appendingPathComponent("fixture-manifest.json"))
        try manifest.validate()
        guard FileManager.default.fileExists(atPath: fixture.appendingPathComponent(manifest.model.path).path),
              FileManager.default.fileExists(atPath: fixture.appendingPathComponent(manifest.weights.path).path) else {
            XCTFail("verified CoreML fixture is not present in the test bundle or checkout")
            throw FixtureError.missing
        }
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacTalkCoreMLFixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try copyFixtureFile(manifest.model.path)
        try copyFixtureFile(manifest.weights.path)
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

        try assertDescription(loaded.model)
        XCTAssertEqual(try predict(loaded.model), manifest.prediction.output)
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
            _ = try await MLModel.load(asset: missingBlob, configuration: configuration)
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
        try Data("malicious replacement specification".utf8).write(to: rootURL.appendingPathComponent(manifest.model.path))
        try Data("malicious replacement weights".utf8).write(to: rootURL.appendingPathComponent(manifest.weights.path))

        let loaded = try await CoreMLByteAssetLoader().load(bytes, computeUnits: .cpuOnly)
        try assertDescription(loaded.model)
        XCTAssertEqual(try predict(loaded.model), manifest.prediction.output)
    }

    func test_fixtureManifestRejectsUnknownTopLevelFields() throws {
        let data = try Data(contentsOf: fixtureDirectory.appendingPathComponent("fixture-manifest.json"))
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["unexpected"] = true
        let mutated = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let url = rootURL.appendingPathComponent("mutated-manifest.json")
        try mutated.write(to: url)
        XCTAssertThrowsError(try FixtureManifest(contentsOf: url))
    }

    func test_fixtureManifestMatchesOwnedBytesAndInterface() async throws {
        let bytes = try readFixtureBytes()
        XCTAssertEqual(manifest.formatVersion, 1)
        XCTAssertEqual(manifest.model.path, "model.mlmodel")
        XCTAssertEqual(manifest.weights.path, "weights/weight.bin")
        XCTAssertEqual(manifest.model.size, bytes.specification.data.count)
        XCTAssertEqual(manifest.model.sha256, digest(bytes.specification.data))
        XCTAssertEqual(manifest.weights.size, bytes.weights.data.count)
        XCTAssertEqual(manifest.weights.sha256, digest(bytes.weights.data))

        let loaded = try await CoreMLByteAssetLoader().load(bytes, computeUnits: .cpuOnly)
        try assertDescription(loaded.model)
        XCTAssertEqual(try predict(loaded.model), manifest.prediction.output)
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

    private func copyFixtureFile(_ relativePath: String) throws {
        let source = fixtureDirectory.appendingPathComponent(relativePath)
        let destination = rootURL.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: destination)
    }

    private func readFixtureBytes() throws -> VerifiedCoreMLAssetBytes {
        let reader = VerifiedArtifactReader(rootFD: rootFD)
        let specification = try reader.read(GeneratedParakeetManifestEntry(
            path: manifest.model.path, size: Int64(manifest.model.size), sha256: manifest.model.sha256
        ))
        let weights = try reader.read(GeneratedParakeetManifestEntry(
            path: manifest.weights.path, size: Int64(manifest.weights.size), sha256: manifest.weights.sha256
        ))
        return VerifiedCoreMLAssetBytes(component: .preprocessor, specification: specification, weights: weights)
    }

    private func assertDescription(_ model: MLModel) throws {
        let input = try XCTUnwrap(model.modelDescription.inputDescriptionsByName[manifest.input.name])
        let output = try XCTUnwrap(model.modelDescription.outputDescriptionsByName[manifest.output.name])
        XCTAssertEqual(input.type, .multiArray)
        XCTAssertEqual(output.type, .multiArray)
        let inputConstraint = try XCTUnwrap(input.multiArrayConstraint)
        let outputConstraint = try XCTUnwrap(output.multiArrayConstraint)
        XCTAssertEqual(inputConstraint.dataType, manifest.input.mlDataType)
        XCTAssertEqual(outputConstraint.dataType, manifest.output.mlDataType)
        XCTAssertEqual(inputConstraint.shape.map(\.intValue), manifest.input.shape)
        XCTAssertEqual(outputConstraint.shape.map(\.intValue), manifest.output.shape)
    }

    private func predict(_ model: MLModel) throws -> [Double] {
        let input = try MLMultiArray(shape: manifest.input.shape.map(NSNumber.init), dataType: manifest.input.mlDataType)
        for (index, value) in manifest.prediction.input.enumerated() { input[index] = NSNumber(value: value) }
        let provider = try MLDictionaryFeatureProvider(dictionary: [
            manifest.input.name: MLFeatureValue(multiArray: input)
        ])
        let output = try model.prediction(from: provider)
        let array = try XCTUnwrap(output.featureValue(for: manifest.output.name)?.multiArrayValue)
        return (0..<manifest.prediction.output.count).map { (array[$0] as NSNumber).doubleValue }
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private enum FixtureError: Error { case missing }

    private struct FixtureManifest {
        let formatVersion: Int
        let model: Artifact
        let weights: Artifact
        let input: Interface
        let output: Interface
        let prediction: Prediction

        struct Artifact { let path: String; let size: Int; let sha256: String }
        struct Interface {
            let name: String
            let shape: [Int]
            let dtype: String
            var mlDataType: MLMultiArrayDataType {
                dtype == "float32" ? .float32 : .double
            }
        }
        struct Prediction { let input: [Double]; let output: [Double] }

        init(contentsOf url: URL) throws {
            let data = try Data(contentsOf: url)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys) == ["formatVersion", "model", "weights", "input", "output", "prediction"],
                  let formatVersion = object["formatVersion"] as? Int,
                  let model = try Self.artifact(object["model"]),
                  let weights = try Self.artifact(object["weights"]),
                  let input = try Self.interface(object["input"]),
                  let output = try Self.interface(object["output"]),
                  let prediction = try Self.prediction(object["prediction"]) else {
                throw FixtureError.missing
            }
            self.formatVersion = formatVersion
            self.model = model
            self.weights = weights
            self.input = input
            self.output = output
            self.prediction = prediction
        }

        func validate() throws {
            guard formatVersion == 1,
                  model.path == "model.mlmodel", weights.path == "weights/weight.bin",
                  model.size > 0, weights.size > 0,
                  model.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                  weights.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                  input.name == "x", output.name == "double",
                  input.shape == [10], output.shape == [10],
                  input.dtype == "float32", output.dtype == "float32",
                  prediction.input == [1,2,3,4,5,6,7,8,9,10],
                  prediction.output == [2,4,6,8,10,12,14,16,18,20] else {
                throw FixtureError.missing
            }
        }

        private static func artifact(_ value: Any?) throws -> Artifact? {
            guard let object = value as? [String: Any], Set(object.keys) == ["path", "size", "sha256"],
                  let path = object["path"] as? String, let size = object["size"] as? Int,
                  let sha256 = object["sha256"] as? String else { return nil }
            return Artifact(path: path, size: size, sha256: sha256)
        }

        private static func interface(_ value: Any?) throws -> Interface? {
            guard let object = value as? [String: Any], Set(object.keys) == ["name", "shape", "dtype"],
                  let name = object["name"] as? String, let shape = object["shape"] as? [Int],
                  let dtype = object["dtype"] as? String else { return nil }
            return Interface(name: name, shape: shape, dtype: dtype)
        }

        private static func prediction(_ value: Any?) throws -> Prediction? {
            guard let object = value as? [String: Any], Set(object.keys) == ["input", "output"],
                  let input = object["input"] as? [NSNumber], let output = object["output"] as? [NSNumber] else { return nil }
            return Prediction(input: input.map(\.doubleValue), output: output.map(\.doubleValue))
        }
    }
}
