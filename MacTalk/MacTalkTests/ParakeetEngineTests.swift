//
//  ParakeetEngineTests.swift
//  MacTalkTests
//
//  Basic tests for ParakeetEngine wrapper
//

import XCTest
@testable import MacTalk

final class ParakeetEngineTests: XCTestCase {

    func test_providerIsParakeet() {
        let engine = ParakeetEngine()
        XCTAssertEqual(engine.provider, .parakeet)
    }

    func test_prepareFailsWhenModelsMissing() async throws {
        let downloader = ParakeetModelDownloader()
        if downloader.modelsAvailable() {
            throw XCTSkip("Parakeet models are available; missing-model test skipped.")
        }

        let engine = ParakeetEngine()
        do {
            try await engine.prepare()
            XCTFail("Expected prepare() to fail when models are missing.")
        } catch let error as ParakeetBootstrap.BootstrapError {
            XCTAssertEqual(error, .modelsNotAvailable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
