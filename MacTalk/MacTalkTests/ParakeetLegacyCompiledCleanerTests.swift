import Darwin
import XCTest
@testable import MacTalk

final class ParakeetLegacyCompiledCleanerTests: XCTestCase {
    func test_removesOnlyExactCompiledGeneration() async throws {
        let parent = temporaryParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let compiled = parent.appendingPathComponent(ParakeetModelDownloader.folderName)
        let nested = compiled.appendingPathComponent("Encoder.mlmodelc/weights")
        let source = parent.appendingPathComponent(ParakeetSourceStore.canonicalDirectoryName)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("weight".utf8).write(to: nested.appendingPathComponent("weight.bin"))
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("source".utf8).write(to: source.appendingPathComponent("sentinel"))

        try await ParakeetLegacyCompiledCleaner(parent: parent).removeCompiledGeneration()

        XCTAssertFalse(FileManager.default.fileExists(atPath: compiled.path))
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("sentinel")), Data("source".utf8))
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

    private func temporaryParent() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("legacy-cleaner-\(UUID().uuidString)")
    }
}
