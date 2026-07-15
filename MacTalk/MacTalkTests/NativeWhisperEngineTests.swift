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

        XCTAssertNil(NativeWhisperEngine(modelURL: url))
    }

    func test_directoryIsRejectedAsModel() {
        XCTAssertNil(NativeWhisperEngine(modelURL: FileManager.default.temporaryDirectory))
    }

    func test_corruptModelFileIsRejected() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("corrupt-\(UUID().uuidString).bin")
        try Data("not a whisper model".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertNil(NativeWhisperEngine(modelURL: url))
    }
}
