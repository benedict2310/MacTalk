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

    private func fixtureSpec() -> ModelSpec {
        ModelSpec(id: "fixture", displayName: "Fixture", filename: "fixture.bin",
                  sha256: String(repeating: "a", count: 64), sizeBytes: 1,
                  urls: [URL(string: "https://example.invalid/fixture")!], license: nil, languages: nil)
    }
}
