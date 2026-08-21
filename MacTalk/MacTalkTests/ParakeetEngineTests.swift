//
//  ParakeetEngineTests.swift
//  MacTalkTests
//
//  Provider identity is deterministic. Prepare/process/finalize behavior requires
//  an injectable bootstrap and a separately provisioned real-model suite.
//

import XCTest
@testable import MacTalk

final class ParakeetEngineTests: XCTestCase {
    func test_providerIsParakeet() {
        XCTAssertEqual(ParakeetEngine().provider, .parakeet)
    }

    func test_vocabularyHintingRequiresVerifiedParakeetResources() {
        XCTAssertEqual(
            ParakeetEngine().vocabularyHintingCapability,
            .unavailable(.additionalVerifiedResourcesRequired)
        )
    }
}
