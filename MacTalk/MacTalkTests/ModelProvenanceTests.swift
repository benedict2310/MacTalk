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
        XCTAssertTrue(GeneratedModelProvenance.parakeetSource.allSatisfy { $0.path.contains(".mlpackage/") || $0.path == "parakeet_vocab.json" })
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

    func test_parakeetPathValidationRejectsUnsafeComponents() {
        for path in ["../escape", "/absolute", "model/./file", "model//file"] {
            XCTAssertThrowsError(try ParakeetModelDownloader.validatePath(path), path)
        }
        XCTAssertNoThrow(try ParakeetModelDownloader.validatePath("Encoder.mlmodelc/weights/weight.bin"))
    }
}
