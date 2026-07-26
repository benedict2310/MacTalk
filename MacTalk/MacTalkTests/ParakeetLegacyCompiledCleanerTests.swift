import CryptoKit
import Darwin
import XCTest
@testable import MacTalk

final class ParakeetLegacyCompiledCleanerTests: XCTestCase {
    func test_removesOnlyExactCompiledGeneration() async throws {
        let parent = temporaryParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let compiled = parent.appendingPathComponent(ParakeetModelDownloader.folderName)
        let artifact = Data("weight".utf8)
        let entry = ParakeetManifestEntry(path: "Encoder.mlmodelc/weights/weight.bin", size: Int64(artifact.count), sha256: digest(artifact))
        let nested = compiled.appendingPathComponent("Encoder.mlmodelc/weights")
        let source = parent.appendingPathComponent(ParakeetSourceStore.canonicalDirectoryName)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try artifact.write(to: nested.appendingPathComponent("weight.bin"))
        try writeMarker(entries: [entry], to: compiled)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("source".utf8).write(to: source.appendingPathComponent("sentinel"))

        try await ParakeetLegacyCompiledCleaner(parent: parent, entries: [entry], repository: "repo", revision: "revision").removeCompiledGeneration()

        XCTAssertFalse(FileManager.default.fileExists(atPath: compiled.path))
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("sentinel")), Data("source".utf8))
    }

    func test_unexpectedFileRejectsWholeTreeBeforeAnyDeletion() async throws {
        let parent = temporaryParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let compiled = parent.appendingPathComponent(ParakeetModelDownloader.folderName)
        let artifact = Data("weight".utf8)
        let entry = ParakeetManifestEntry(path: "weight.bin", size: Int64(artifact.count), sha256: digest(artifact))
        try FileManager.default.createDirectory(at: compiled, withIntermediateDirectories: true)
        try artifact.write(to: compiled.appendingPathComponent("weight.bin"))
        try Data("unexpected".utf8).write(to: compiled.appendingPathComponent("other.bin"))
        try writeMarker(entries: [entry], to: compiled)

        do {
            try await ParakeetLegacyCompiledCleaner(parent: parent, entries: [entry], repository: "repo", revision: "revision").removeCompiledGeneration()
            XCTFail("unexpected content was deleted")
        } catch let error as ParakeetLegacyCompiledCleanupError {
            XCTAssertEqual(error, .invalidCompiledTree)
        }

        XCTAssertEqual(try Data(contentsOf: compiled.appendingPathComponent("weight.bin")), artifact)
        XCTAssertTrue(FileManager.default.fileExists(atPath: compiled.appendingPathComponent("other.bin").path))
    }

    func test_absentCompiledGenerationIsIdempotent() async throws {
        let parent = temporaryParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try await ParakeetLegacyCompiledCleaner(parent: parent).removeCompiledGeneration()
        try await ParakeetLegacyCompiledCleaner(parent: parent).removeCompiledGeneration()
    }

    func test_rejectsSymlinkWithoutTouchingTarget() async throws {
        let parent = temporaryParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let target = parent.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: target.appendingPathComponent("sentinel"))
        XCTAssertEqual(symlink("target", parent.appendingPathComponent(ParakeetModelDownloader.folderName).path), 0)

        do {
            try await ParakeetLegacyCompiledCleaner(parent: parent).removeCompiledGeneration()
            XCTFail("symlink unexpectedly removed")
        } catch let error as ParakeetLegacyCompiledCleanupError {
            XCTAssertEqual(error, .invalidCompiledTree)
        }

        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("sentinel")), Data("keep".utf8))
    }

    func test_rejectsRegularFileAtCompiledDirectoryName() async throws {
        let parent = temporaryParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try Data("collision".utf8).write(to: parent.appendingPathComponent(ParakeetModelDownloader.folderName))

        do {
            try await ParakeetLegacyCompiledCleaner(parent: parent).removeCompiledGeneration()
            XCTFail("regular file unexpectedly removed")
        } catch let error as ParakeetLegacyCompiledCleanupError {
            XCTAssertEqual(error, .invalidCompiledTree)
        }
    }

    private func writeMarker(entries: [ParakeetManifestEntry], to directory: URL) throws {
        let object: [String: Any] = [
            "repository": "repo",
            "revision": "revision",
            "files": entries.map { ["path": $0.path, "size": $0.size, "sha256": $0.sha256] }
        ]
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: directory.appendingPathComponent(".mactalk-manifest.json"))
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func temporaryParent() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("legacy-cleaner-\(UUID().uuidString)")
    }
}
