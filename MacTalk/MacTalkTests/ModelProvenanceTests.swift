import XCTest
@testable import MacTalk

final class ModelProvenanceTests: XCTestCase {
    func test_whisperCatalogUsesGeneratedImmutableIdentity() {
        let models = ModelCatalog.bundled()
        XCTAssertEqual(models.count, 5)
        XCTAssertEqual(models.map(\.filename), GeneratedModelProvenance.whisper.map(\.filename))
        XCTAssertEqual(models.map(\.sha256), GeneratedModelProvenance.whisper.map(\.sha256))
        XCTAssertEqual(models.map(\.sizeBytes), GeneratedModelProvenance.whisper.map(\.sizeBytes))
        XCTAssertTrue(models.allSatisfy { $0.revision == GeneratedModelProvenance.whisperRevision })
        XCTAssertTrue(models.allSatisfy { $0.source == GeneratedModelProvenance.whisperRepository })
        XCTAssertTrue(models.allSatisfy { spec in
            spec.urls.allSatisfy { $0.absoluteString.contains("/resolve/\(spec.revision)/") }
        })
    }

    func test_parakeetManifestUsesGeneratedCompiledEntriesAndKeepsSourceInactive() throws {
        XCTAssertEqual(ParakeetModelDownloader.revision, GeneratedModelProvenance.parakeetRevision)
        XCTAssertEqual(ParakeetModelDownloader.fluidAudioRevision, GeneratedModelProvenance.fluidAudioRevision)
        XCTAssertEqual(ParakeetModelDownloader.folderName, "parakeet-tdt-0.6b-v3")
        XCTAssertEqual(ParakeetModelDownloader.manifest, GeneratedModelProvenance.parakeetCompiled.map {
            ParakeetManifestEntry(path: $0.path, size: $0.size, sha256: $0.sha256)
        })
        XCTAssertEqual(GeneratedModelProvenance.parakeetCompiled.count, 21)
        XCTAssertEqual(GeneratedModelProvenance.parakeetSource.count, 9)
        let expectedSourcePaths: [String: String] = [
            "Preprocessor/specification": "mlpackages/Preprocessor.mlpackage/Data/com.apple.CoreML/model.mlmodel",
            "Preprocessor/weights": "mlpackages/Preprocessor.mlpackage/Data/com.apple.CoreML/weights/weight.bin",
            "Encoder/specification": "mlpackages/Encoder.mlpackage/Data/com.apple.CoreML/model.mlmodel",
            "Encoder/weights": "mlpackages/Encoder.mlpackage/Data/com.apple.CoreML/weights/weight.bin",
            "Decoder/specification": "mlpackages/Decoder.mlpackage/Data/com.apple.CoreML/model.mlmodel",
            "Decoder/weights": "mlpackages/Decoder.mlpackage/Data/com.apple.CoreML/weights/weight.bin",
            "JointDecisionv3/specification": "JointDecisionv3.mlpackage/Data/com.apple.CoreML/model.mlmodel",
            "JointDecisionv3/weights": "JointDecisionv3.mlpackage/Data/com.apple.CoreML/weights/weight.bin"
        ]
        for entry in GeneratedModelProvenance.parakeetSource where entry.role != "vocabulary" {
            XCTAssertEqual(entry.path, expectedSourcePaths["\(entry.component)/\(entry.role)"])
        }
        XCTAssertEqual(GeneratedModelProvenance.parakeetSource.last?.path, "parakeet_vocab.json")
        try ParakeetModelDownloader.validateManifest()
    }

    func test_parakeetAvailabilityIsOfflineAndSideEffectFree() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("parakeet-empty-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertFalse(ParakeetModelDownloader.modelsAvailable(at: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func test_downloaderInitializerDoesNotDeleteLiveStaging() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("parakeet-staging-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appendingPathComponent(".staging-live")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        _ = ParakeetModelDownloader(modelsRoot: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.path))
    }

    func test_productionParakeetDownloaderHasNoMirrorOverridePolicySeam() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("MacTalk/Whisper/ParakeetModelDownloader.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertFalse(source.contains("mirrorResolver"),
                       "production Parakeet downloads must not expose a mirror override seam")
    }

    func test_parakeetPathValidationRejectsUnsafeComponents() {
        for path in ["../escape", "/absolute", "model/./file", "model//file"] {
            XCTAssertThrowsError(try ParakeetModelDownloader.validatePath(path), path)
        }
        XCTAssertNoThrow(try ParakeetModelDownloader.validatePath("Encoder.mlmodelc/weights/weight.bin"))
    }
}
