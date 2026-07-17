//
//  NativeWhisperEngineTests.swift
//  MacTalkTests
//
//  Deterministic validation of model-path rejection. Successful inference belongs
//  in a separately provisioned real-model integration suite.
//

import XCTest
@testable import MacTalk

final class NativeWhisperEngineTests: XCTestCase {
    func test_missingModelIsRejected() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).bin")

        XCTAssertNil(NativeWhisperEngine(modelSpec: fixtureSpec(), modelURL: url))
    }

    func test_directoryIsRejectedAsModel() {
        XCTAssertNil(NativeWhisperEngine(modelSpec: fixtureSpec(), modelURL: FileManager.default.temporaryDirectory))
    }

    func test_corruptModelFileIsRejected() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("corrupt-\(UUID().uuidString).bin")
        try Data("not a whisper model".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertNil(NativeWhisperEngine(modelSpec: fixtureSpec(), modelURL: url))
    }

    func test_nativeBoundaryRejectsSymlinkModel() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("symlink-\(UUID().uuidString)")
        let target = directory.appendingPathComponent("target.bin")
        let link = directory.appendingPathComponent("model.bin")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(repeating: 0, count: 1).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try ModelIntegrityVerifier.openValidated(source: link, spec: fixtureSpec()))
    }

    private func fixtureSpec() -> ModelSpec {
        ModelSpec(id: "fixture", displayName: "Fixture", filename: "fixture.bin",
                  sha256: String(repeating: "a", count: 64), sizeBytes: 1,
                  urls: [URL(string: "https://example.invalid/fixture")!], license: nil, languages: nil)
    }
}
