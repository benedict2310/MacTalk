//
//  ModelManagerTests.swift
//  MacTalkTests
//
//  Pure model-catalog contracts. Model storage/downloading needs injected paths
//  and network clients before it can be tested without touching user state.
//

import XCTest
@testable import MacTalk

final class ModelCatalogTests: XCTestCase {
    func test_bundledCatalogHasUniqueStableIdentifiersAndFilenames() {
        let models = ModelCatalog.bundled()

        XCTAssertFalse(models.isEmpty)
        XCTAssertEqual(Set(models.map(\.id)).count, models.count)
        XCTAssertEqual(Set(models.map(\.filename)).count, models.count)
    }

    func test_everyBundledModelHasDownloadMetadata() {
        for model in ModelCatalog.bundled() {
            XCTAssertGreaterThan(model.sizeBytes, 0, model.id)
            XCTAssertFalse(model.urls.isEmpty, model.id)
            XCTAssertTrue(model.urls.allSatisfy { $0.scheme == "https" }, model.id)
        }
    }

    func test_lookupFindsModelByIDAndFilename() throws {
        let expected = try XCTUnwrap(ModelCatalog.bundled().first)

        XCTAssertEqual(ModelCatalog.findById(expected.id), expected)
        XCTAssertEqual(ModelCatalog.findByFilename(expected.filename), expected)
    }

    func test_lookupReturnsNilForUnknownModel() {
        XCTAssertNil(ModelCatalog.findById("unknown"))
        XCTAssertNil(ModelCatalog.findByFilename("unknown.bin"))
    }
}
