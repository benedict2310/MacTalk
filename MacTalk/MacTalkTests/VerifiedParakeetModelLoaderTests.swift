import CoreML
import CryptoKit
import Foundation
import XCTest
@testable import MacTalk

final class VerifiedParakeetModelLoaderTests: XCTestCase {
    private var fixture: Fixture!

    override func setUpWithError() throws {
        fixture = try Fixture()
    }

    func test_loadsFourComponentsInOrderAndRetainsOwnedModels() async throws {
        let recorder = RecordingComponentLoader(real: true)
        let loader = VerifiedParakeetModelLoader(
            expectedIdentity: fixture.identity,
            expectedArtifacts: fixture.artifacts,
            componentLoader: recorder
        )
        let result = try await loader.load(snapshot: fixture.snapshot, policy: .cpuAndNeuralEngine)

        let recordedComponents = await recorder.components()
        let recordedPolicies = await recorder.policies()
        XCTAssertEqual(recordedComponents, [.preprocessor, .encoder, .decoder, .joint])
        XCTAssertEqual(recordedPolicies, [.cpuOnly, .cpuAndNeuralEngine, .cpuAndNeuralEngine, .cpuAndNeuralEngine])
        XCTAssertEqual(result.assets.count, 4)
        XCTAssertEqual(result.snapshot.identity, fixture.identity)
        for component in ParakeetSourceComponent.allCases {
            XCTAssertEqual(result.assets[component]?.bytes.specification.identity, fixture.snapshot.assets[component]?.specification.identity)
            XCTAssertEqual(result.assets[component]?.bytes.weights.identity, fixture.snapshot.assets[component]?.weights.identity)
            XCTAssertEqual(Set(result.assets[component]!.model.modelDescription.inputDescriptionsByName.keys), Set(["x"]))
            XCTAssertEqual(Set(result.assets[component]!.model.modelDescription.outputDescriptionsByName.keys), Set(["double"]))
        }
        XCTAssertEqual(result.snapshot.vocabulary.data, fixture.vocabulary.data)
        if case .v3 = result.models.version {} else { XCTFail("loader must construct v3 models") }
        XCTAssertEqual(result.models.vocabulary[0], "<blank>")
        XCTAssertEqual(result.models.vocabulary[1], "fixture")
        XCTAssertNotNil(result.assets[.preprocessor]?.model)
        XCTAssertNotNil(result.assets[.encoder]?.asset)
    }

    func test_defaultLoaderLoadsTinyFixtureThroughCoreMLSequentially() async throws {
        let loader = VerifiedParakeetModelLoader(
            expectedIdentity: fixture.identity,
            expectedArtifacts: fixture.artifacts
        )
        let result = try await loader.load(snapshot: fixture.snapshot, policy: .cpuOnly)
        try fixture.removeSourceFiles()
        if case .v3 = result.models.version {} else { XCTFail("loader must construct v3 models") }
        XCTAssertEqual(try predict(result.assets[.preprocessor]!.model), [2,4,6,8,10,12,14,16,18,20])
        XCTAssertEqual(try predict(result.assets[.joint]!.model), [2,4,6,8,10,12,14,16,18,20])
    }

    func test_policyUsesCpuOnlyForPreprocessorAndSelectedPolicyForOtherComponents() async throws {
        let recorder = RecordingComponentLoader(real: false)
        let loader = VerifiedParakeetModelLoader(expectedIdentity: fixture.identity, expectedArtifacts: fixture.artifacts, componentLoader: recorder)
        _ = try await loader.load(snapshot: fixture.snapshot, policy: .cpuAndGPU)
        let recordedPolicies = await recorder.policies()
        let maximumOverlap = await recorder.maximumOverlap()
        XCTAssertEqual(recordedPolicies, [.cpuOnly, .cpuAndGPU, .cpuAndGPU, .cpuAndGPU])
        XCTAssertEqual(maximumOverlap, 1)
    }

    func test_identityMismatchFailsBeforeCoreML() async throws {
        let recorder = RecordingComponentLoader(real: false)
        let loader = VerifiedParakeetModelLoader(expectedIdentity: fixture.identity, expectedArtifacts: fixture.artifacts, componentLoader: recorder)
        var bad = fixture.snapshot
        bad = VerifiedParakeetSourceSnapshot(identity: ParakeetSourceIdentity(formatVersion: 1, repository: "wrong", revision: fixture.identity.revision, fluidAudioRevision: fixture.identity.fluidAudioRevision, canonicalProvenanceSHA256: fixture.identity.canonicalProvenanceSHA256), assets: bad.assets, vocabulary: bad.vocabulary)
        try await assertRejected(loader, snapshot: bad, error: .identityMismatch)
        let recordedComponents = await recorder.components()
        XCTAssertTrue(recordedComponents.isEmpty)
    }

    func test_everyArtifactIdentityFieldMismatchFailsBeforeCoreML() async throws {
        for mutate in [
            { (s: VerifiedParakeetSourceSnapshot) in self.mutateFirst(s, path: "wrong.mlmodel", size: nil, digest: nil, component: nil, role: nil) },
            { (s: VerifiedParakeetSourceSnapshot) in self.mutateFirst(s, path: nil, size: 1, digest: nil, component: nil, role: nil) },
            { (s: VerifiedParakeetSourceSnapshot) in self.mutateFirst(s, path: nil, size: nil, digest: String(repeating: "0", count: 64), component: nil, role: nil) },
            { (s: VerifiedParakeetSourceSnapshot) in self.mutateFirst(s, path: nil, size: nil, digest: nil, component: .encoder, role: nil) },
            { (s: VerifiedParakeetSourceSnapshot) in self.mutateFirst(s, path: "weights/weight.bin", size: nil, digest: nil, component: nil, role: "weights") }
        ] {
            let recorder = RecordingComponentLoader(real: false)
            let loader = VerifiedParakeetModelLoader(expectedIdentity: fixture.identity, expectedArtifacts: fixture.artifacts, componentLoader: recorder)
            try await assertRejected(loader, snapshot: mutate(fixture.snapshot), error: .artifactMismatch)
            let recordedComponents = await recorder.components()
            XCTAssertTrue(recordedComponents.isEmpty)
        }
    }

    func test_strictVocabularyRejectsInvalidForms() async throws {
        let invalid = ["", "{}", "{\"1\":\"a\",\"01\":\"b\"}", "{\"-1\":\"a\"}", "{\"x\":\"a\"}", "{\"999999999999999999999999999999\":\"a\"}", "{\"1\":1}", "{\"1\":{}}", "{\"1\":\"a\"} trailing", "{\"1\":\"a\""]
        for text in invalid {
            let recorder = RecordingComponentLoader(real: false)
            let snapshot = fixture.snapshotWithVocabulary(Data(text.utf8))
            let loader = VerifiedParakeetModelLoader(expectedIdentity: fixture.identity, expectedArtifacts: fixture.artifactsFor(snapshot), componentLoader: recorder)
            try await assertRejected(loader, snapshot: snapshot, error: .vocabularyMalformed)
            let recordedComponents = await recorder.components()
            XCTAssertTrue(recordedComponents.isEmpty)
        }
    }

    func test_validVocabularyParsesStringKeysAndValues() async throws {
        let snapshot = fixture.snapshotWithVocabulary(Data(#"{"0":"zero","2":"two"}"#.utf8))
        let loader = VerifiedParakeetModelLoader(expectedIdentity: fixture.identity, expectedArtifacts: fixture.artifactsFor(snapshot), componentLoader: RecordingComponentLoader(real: false))
        let result = try await loader.load(snapshot: snapshot, policy: .cpuOnly)
        XCTAssertEqual(result.models.vocabulary, [0: "zero", 2: "two"])
    }

    func test_cancellationIsTypedAndProducesNoResult() async throws {
        let recorder = RecordingComponentLoader(real: false, delay: .milliseconds(200))
        let loader = VerifiedParakeetModelLoader(expectedIdentity: fixture.identity, expectedArtifacts: fixture.artifacts, componentLoader: recorder)
        let snapshot = fixture.snapshot
        let task = Task { try await loader.load(snapshot: snapshot, policy: .cpuOnly) }
        task.cancel()
        do { _ = try await task.value; XCTFail("cancellation must fail") }
        catch let error as VerifiedParakeetModelLoaderError { XCTAssertEqual(error, .cancelled) }
        catch { XCTFail("wrong cancellation error: \(error)") }
    }

    func test_cancellationDuringComponentLoadIsTyped() async throws {
        let recorder = RecordingComponentLoader(real: false, delay: .milliseconds(200))
        let loader = VerifiedParakeetModelLoader(expectedIdentity: fixture.identity, expectedArtifacts: fixture.artifacts, componentLoader: recorder)
        let snapshot = fixture.snapshot
        let task = Task { try await loader.load(snapshot: snapshot, policy: .cpuOnly) }
        await recorder.waitForCount(1)
        task.cancel()
        do { _ = try await task.value; XCTFail("cancellation must fail") }
        catch let error as VerifiedParakeetModelLoaderError { XCTAssertEqual(error, .cancelled) }
        catch { XCTFail("wrong cancellation error: \\(error)") }
    }

    func test_cancellationBeforePublishIsTyped() async throws {
        let gate = AsyncGate()
        let loader = VerifiedParakeetModelLoader(expectedIdentity: fixture.identity, expectedArtifacts: fixture.artifacts, componentLoader: RecordingComponentLoader(real: false), beforePublish: { await gate.wait() })
        let snapshot = fixture.snapshot
        let task = Task { try await loader.load(snapshot: snapshot, policy: .cpuOnly) }
        await gate.waitUntilEntered()
        task.cancel()
        await gate.open()
        do { _ = try await task.value; XCTFail("cancellation must fail") }
        catch let error as VerifiedParakeetModelLoaderError { XCTAssertEqual(error, .cancelled) }
        catch { XCTFail("wrong cancellation error: \(error)") }
    }

    func test_staticGuardRejectsPathBasedProductionLoading() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("MacTalk/MacTalk/Whisper/VerifiedParakeetModelLoader.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("AsrModels.load"))
        XCTAssertFalse(source.contains("ModelHub.loadModels"))
        XCTAssertFalse(source.contains("MLModel(contentsOf:"))
        XCTAssertFalse(source.contains("MLModelAsset(url:"))
    }

    private func assertRejected(_ loader: VerifiedParakeetModelLoader, snapshot: VerifiedParakeetSourceSnapshot, error expected: VerifiedParakeetModelLoaderError) async throws {
        do { _ = try await loader.load(snapshot: snapshot, policy: .cpuOnly); XCTFail("expected rejection") }
        catch let error as VerifiedParakeetModelLoaderError { XCTAssertEqual(error, expected) }
    }

    private func mutateFirst(_ snapshot: VerifiedParakeetSourceSnapshot, path: String? = nil, size: Int64? = nil, digest: String? = nil, component: ParakeetSourceComponent? = nil, role: String? = nil) -> VerifiedParakeetSourceSnapshot {
        var assets = snapshot.assets
        let original = assets[.preprocessor]!
        let identity = GeneratedParakeetManifestEntry(path: path ?? original.specification.identity.path, size: size ?? original.specification.identity.size, sha256: digest ?? original.specification.identity.sha256)
        let spec = VerifiedArtifactBytes(identity: identity, data: original.specification.data)
        assets[.preprocessor] = VerifiedCoreMLAssetBytes(component: component ?? original.component, specification: spec, weights: original.weights)
        return VerifiedParakeetSourceSnapshot(identity: snapshot.identity, assets: assets, vocabulary: snapshot.vocabulary)
    }

    private func predict(_ model: MLModel) throws -> [Int] {
        let input = try MLMultiArray(shape: [10], dataType: .float32)
        for index in 0..<10 { input[index] = NSNumber(value: index + 1) }
        let provider = try MLDictionaryFeatureProvider(dictionary: ["x": MLFeatureValue(multiArray: input)])
        let output = try model.prediction(from: provider)
        let array = try XCTUnwrap(output.featureValue(for: "double")?.multiArrayValue)
        return (0..<10).map { Int((array[$0] as NSNumber).doubleValue.rounded()) }
    }

    private final class Fixture {
        let identity = ParakeetSourceIdentity(formatVersion: 99, repository: "fixture", revision: "fixture-revision", fluidAudioRevision: "fixture-fluid", canonicalProvenanceSHA256: String(repeating: "f", count: 64))
        let sourceFiles: [URL]
        let artifacts: [ParakeetExpectedArtifact]
        let snapshot: VerifiedParakeetSourceSnapshot
        let vocabulary: VerifiedArtifactBytes
        init() throws {
            let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/VerifiedCoreMLFixture")
            let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("MacTalkLoaderFixture-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: tempRoot.appendingPathComponent("weights"), withIntermediateDirectories: true)
            sourceFiles = [tempRoot.appendingPathComponent("model.mlmodel"), tempRoot.appendingPathComponent("weights/weight.bin")]
            try FileManager.default.copyItem(at: base.appendingPathComponent("model.mlmodel"), to: sourceFiles[0])
            try FileManager.default.copyItem(at: base.appendingPathComponent("weights/weight.bin"), to: sourceFiles[1])
            let specData = try Data(contentsOf: sourceFiles[0])
            let weightData = try Data(contentsOf: sourceFiles[1])
            let specEntry = GeneratedParakeetManifestEntry(path: "model.mlmodel", size: Int64(specData.count), sha256: digest(specData))
            let weightEntry = GeneratedParakeetManifestEntry(path: "weights/weight.bin", size: Int64(weightData.count), sha256: digest(weightData))
            vocabulary = VerifiedArtifactBytes(identity: GeneratedParakeetManifestEntry(path: "vocab.json", size: Int64(Data(#"{"0":"<blank>","1":"fixture"}"#.utf8).count), sha256: digest(Data(#"{"0":"<blank>","1":"fixture"}"#.utf8))), data: Data(#"{"0":"<blank>","1":"fixture"}"#.utf8))
            var map = [ParakeetSourceComponent: VerifiedCoreMLAssetBytes]()
            artifacts = ParakeetSourceComponent.allCases.flatMap { component in [ParakeetExpectedArtifact(component: component, role: "specification", entry: specEntry), ParakeetExpectedArtifact(component: component, role: "weights", entry: weightEntry)] } + [ParakeetExpectedArtifact(component: nil, role: "vocabulary", entry: vocabulary.identity)]
            for component in ParakeetSourceComponent.allCases { map[component] = VerifiedCoreMLAssetBytes(component: component, specification: VerifiedArtifactBytes(identity: specEntry, data: specData), weights: VerifiedArtifactBytes(identity: weightEntry, data: weightData)) }
            snapshot = VerifiedParakeetSourceSnapshot(identity: identity, assets: map, vocabulary: vocabulary)
        }
        func snapshotWithVocabulary(_ data: Data) -> VerifiedParakeetSourceSnapshot {
            let entry = GeneratedParakeetManifestEntry(path: "vocab.json", size: Int64(data.count), sha256: digest(data))
            return VerifiedParakeetSourceSnapshot(identity: snapshot.identity, assets: snapshot.assets, vocabulary: VerifiedArtifactBytes(identity: entry, data: data))
        }
        func artifactsFor(_ snapshot: VerifiedParakeetSourceSnapshot) -> [ParakeetExpectedArtifact] {
            artifacts.dropLast() + [ParakeetExpectedArtifact(component: nil, role: "vocabulary", entry: snapshot.vocabulary.identity)]
        }
        func removeSourceFiles() throws {
            for sourceFile in sourceFiles { try? FileManager.default.removeItem(at: sourceFile) }
        }
        deinit {
            try? FileManager.default.removeItem(at: sourceFiles[0].deletingLastPathComponent())
        }
    }

    fileprivate actor RecordingState {
        var components = [ParakeetSourceComponent](); var policies = [CoreMLComputeUnitPolicy](); var active = 0; var maximum = 0
    }
    private final class RecordingComponentLoader: VerifiedParakeetComponentLoading, @unchecked Sendable {
        let state = RecordingState(); let real: Bool; let delay: Duration?
        init(real: Bool, delay: Duration? = nil) { self.real = real; self.delay = delay }
        func load(_ bytes: VerifiedCoreMLAssetBytes, computeUnits: CoreMLComputeUnitPolicy) async throws -> LoadedCoreMLByteAsset {
            await state.record(bytes.component, computeUnits)
            if let delay { try await Task.sleep(for: delay) }
            return try await CoreMLByteAssetLoader().load(bytes, computeUnits: computeUnits)
        }
        func components() async -> [ParakeetSourceComponent] { await state.components }
        func policies() async -> [CoreMLComputeUnitPolicy] { await state.policies }
        func maximumOverlap() async -> Int { await state.maximum }
        func waitForCount(_ count: Int) async { await state.waitForCount(count) }
    }
    private actor AsyncGate { var entered = false; var openState = false; var waiters = [CheckedContinuation<Void, Never>]()
        func waitUntilEntered() async { while !entered { await Task.yield() } }
        func wait() async { entered = true; if openState { return }; await withCheckedContinuation { waiters.append($0) } }
        func open() { openState = true; waiters.forEach { $0.resume() }; waiters.removeAll() }
    }
    private enum FixtureError: Error { case missing }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func digest(_ data: Data) -> String { Self.digest(data) }
}

private extension VerifiedParakeetModelLoaderTests.RecordingState {
    func record(_ component: ParakeetSourceComponent, _ policy: CoreMLComputeUnitPolicy) { components.append(component); policies.append(policy); active += 1; maximum = max(maximum, active); active -= 1 }
    func waitForCount(_ count: Int) async { while components.count < count { await Task.yield() } }
}
