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
        XCTAssertEqual(ParakeetModelDownloader.revision, "aed02740059203c4a87495924f685de3722ae9ce")
        XCTAssertEqual(ParakeetModelDownloader.fluidAudioRevision, "19600a485baa4998812e4654b70d2bab8f2c9949")
        XCTAssertEqual(ParakeetModelDownloader.folderName, "parakeet-tdt-0.6b-v3")
        let expected: [(String, Int64, String)] = [
            ("Decoder.mlmodelc/analytics/coremldata.bin", 243, "4238c4e81ecd0dc94bd7dfbb60f7e2cc824107c1ffe0387b8607b72833dba350"),
            ("Decoder.mlmodelc/coremldata.bin", 554, "18647af085d87bd8f3121c8a9b4d4564c1ede038dab63d295b4e745cf2d7fb99"),
            ("Decoder.mlmodelc/metadata.json", 3427, "a39e93cd8371b8ded92635c7804fcd0590f0d1dd9415c6d19a0484be073077d9"),
            ("Decoder.mlmodelc/model.mil", 13110, "ef2a0a281695398a62fde86ac269c68f73d5b578d7ed3b31f2ba91a2d1ea1f35"),
            ("Decoder.mlmodelc/weights/weight.bin", 23604992, "48adf0f0d47c406c8253d4f7fef967436a39da14f5a65e66d5a4b407be355d41"),
            ("Encoder.mlmodelc/analytics/coremldata.bin", 243, "42e638870d73f26b332918a3496ce36793fbb413a81cbd3d16ba01328637a105"),
            ("Encoder.mlmodelc/coremldata.bin", 485, "d48034a167a82e88fc3df64f60af963ab3983538271175b8319e7d5720a0fb86"),
            ("Encoder.mlmodelc/metadata.json", 2921, "da24da9cca943fb29d7fa8e376d57fca7cb3aa08ca51b956b0b0e56813f087e9"),
            ("Encoder.mlmodelc/model.mil", 959769, "ed7b19156ca29fa7dfd6891deb9fda4b0e8893f68597c985d135736546a43808"),
            ("Encoder.mlmodelc/weights/weight.bin", 445187200, "e2020f323703477a5b21d7c2d282c403e371afb5962e79877e3033e73ba6f421"),
            ("JointDecisionv3.mlmodelc/analytics/coremldata.bin", 243, "26def4bf73dd56d29dee21c8ef97cb8969e62f6120ed1adc91e46828e2737b6c"),
            ("JointDecisionv3.mlmodelc/coremldata.bin", 521, "f5fc08b741400f0088492c9e839418b1e18522f19cba28d361dd030c5f398342"),
            ("JointDecisionv3.mlmodelc/metadata.json", 3453, "d9307211b9a37e0f0ac260c7660b1571a3de25841035cfdf9b58fd40425f890f"),
            ("JointDecisionv3.mlmodelc/model.mil", 11775, "be60732943389a047175111a83f8839f3eb39d4803adafa828a0871b2f39818d"),
            ("JointDecisionv3.mlmodelc/weights/weight.bin", 12642764, "4e0e63d840032f7f07ddb1d64446051166281e5491bf22da8a945c41f6eedb3e"),
            ("Preprocessor.mlmodelc/analytics/coremldata.bin", 243, "c9beeb989c8d66f8be11df59bc6df277ec76cee404f6865b46243835ef562f6d"),
            ("Preprocessor.mlmodelc/coremldata.bin", 486, "dbde3f2300842c1fd51ef3ff948a0bcffe65ffd2dca10707f2509f32c1d65b1d"),
            ("Preprocessor.mlmodelc/metadata.json", 2841, "2a98699e22d279dd37fa1d238aeb1c6db1df0d6fad687775324157689d8f3acf"),
            ("Preprocessor.mlmodelc/model.mil", 28181, "4b8518a956450fec57f06c2a21bdffc26973f7f1fa6842fb38fe917f896b6b93"),
            ("Preprocessor.mlmodelc/weights/weight.bin", 491072, "129b76e3aeafa8afa3ea76d995b964b145fe83700d579f6ff42c4c38fa0968ea"),
            ("parakeet_vocab.json", 151122, "7ec60e05f1b24480736ec0eed40900f4626bce1fa9a60fd700ec7e2a59198735")
        ]
        XCTAssertEqual(ParakeetModelDownloader.manifest.count, expected.count)
        for (actual, pinned) in zip(ParakeetModelDownloader.manifest, expected) {
            XCTAssertEqual(actual.path, pinned.0)
            XCTAssertEqual(actual.size, pinned.1)
            XCTAssertEqual(actual.sha256, pinned.2)
        }
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
