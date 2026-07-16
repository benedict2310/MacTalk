import XCTest
@testable import MacTalk

final class ModelProvenanceTests: XCTestCase {
    func test_whisperCatalogHasExactImmutableIdentity() {
        let models = ModelCatalog.bundled()
        XCTAssertEqual(models.count, 5)
        XCTAssertTrue(models.allSatisfy { $0.revision == "5359861c739e955e79d9a303bcbc70fb988958b1" })
        XCTAssertTrue(models.allSatisfy { $0.source == "ggerganov/whisper.cpp" })
        XCTAssertTrue(models.allSatisfy { $0.sha256.count == 64 && $0.sizeBytes > 0 })
        XCTAssertTrue(models.allSatisfy { spec in
            spec.urls.allSatisfy { $0.absoluteString.contains("/resolve/\(spec.revision)/") }
        })
    }

    func test_parakeetManifestIsCompleteAndPinned() throws {
        XCTAssertEqual(ParakeetModelDownloader.manifest.count, 21)
        XCTAssertEqual(ParakeetModelDownloader.revision, "aed02740059203c4a87495924f685de3722ae9ce")
        XCTAssertEqual(ParakeetModelDownloader.manifest.reduce(0) { $0 + $1.size }, 483_105_645)
        try ParakeetModelDownloader.validateManifest()
    }

    func test_parakeetPathValidationRejectsUnsafeComponents() {
        for path in ["../escape", "/absolute", "model/./file", "model//file"] {
            XCTAssertThrowsError(try ParakeetModelDownloader.validatePath(path), path)
        }
        XCTAssertNoThrow(try ParakeetModelDownloader.validatePath("Encoder.mlmodelc/weights/weight.bin"))
    }
}
