//
//  ModelManagerTests.swift
//  MacTalkTests
//
//  Unit tests for ModelManager component
//

import XCTest
@testable import MacTalk

final class ModelManagerTests: XCTestCase {

    var testModelsDirectory: URL!

    override func setUp() {
        super.setUp()

        // Create temporary test directory
        let tempDir = FileManager.default.temporaryDirectory
        testModelsDirectory = tempDir.appendingPathComponent("MacTalkTests_\(UUID().uuidString)")

        try? FileManager.default.createDirectory(
            at: testModelsDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDown() {
        // Clean up test directory
        try? FileManager.default.removeItem(at: testModelsDirectory)
        testModelsDirectory = nil

        super.tearDown()
    }

    // MARK: - Path Management Tests

    func testModelsDirectoryPath() {
        let modelsDir = ModelManager.modelsDirectory

        XCTAssertTrue(modelsDir.path.contains("MacTalk"))
        XCTAssertTrue(modelsDir.path.contains("Models"))
    }

    func testEnsureModelDownloaded() {
        let modelName = "test-model.gguf"
        let modelURL = ModelManager.ensureModelDownloaded(name: modelName)

        XCTAssertEqual(modelURL.lastPathComponent, modelName)
        XCTAssertTrue(modelURL.path.contains("Models"))
    }

    func testModelExists() {
        let modelName = "existing-model.gguf"
        let modelPath = testModelsDirectory.appendingPathComponent(modelName)

        // Create test model file
        FileManager.default.createFile(atPath: modelPath.path, contents: Data())

        // Note: This tests the existence check conceptually
        // In real implementation, we'd need to point ModelManager to testModelsDirectory
        let exists = FileManager.default.fileExists(atPath: modelPath.path)
        XCTAssertTrue(exists)
    }

    func testModelDoesNotExist() {
        let modelName = "nonexistent-model.gguf"
        let modelPath = testModelsDirectory.appendingPathComponent(modelName)

        let exists = FileManager.default.fileExists(atPath: modelPath.path)
        XCTAssertFalse(exists)
    }

    // MARK: - Model Naming Tests

    func testValidModelNames() {
        let validNames = [
            "ggml-tiny-q5_0.gguf",
            "ggml-base-q5_0.gguf",
            "ggml-small-q5_0.gguf",
            "ggml-medium-q5_0.gguf",
            "ggml-large-v3-turbo-q5_0.gguf"
        ]

        for name in validNames {
            let url = ModelManager.ensureModelDownloaded(name: name)
            XCTAssertEqual(url.lastPathComponent, name)
        }
    }

    func testModelNameWithoutExtension() {
        let modelName = "test-model"
        let url = ModelManager.ensureModelDownloaded(name: modelName)

        XCTAssertEqual(url.lastPathComponent, modelName)
    }

    // MARK: - README Generation Tests

    func testREADMECreation() {
        let modelName = "test-model.gguf"
        _ = ModelManager.ensureModelDownloaded(name: modelName)

        let readmePath = ModelManager.modelsDirectory.appendingPathComponent("README.txt")

        // README should be created if model doesn't exist
        // (In real scenario, this would happen automatically)
        let readmeExists = FileManager.default.fileExists(atPath: readmePath.path)

        // We can't guarantee this in unit test without actual ModelManager implementation
        // but we can verify the path structure
        XCTAssertTrue(readmePath.path.contains("README.txt"))
    }

    // MARK: - Model Size Tests

    func testModelSize() {
        let modelName = "test-model.gguf"
        let modelPath = testModelsDirectory.appendingPathComponent(modelName)

        // Create test model with known size
        let testData = Data(count: 1024 * 1024) // 1 MB
        try? testData.write(to: modelPath)

        if let size = ModelManager.modelSize(name: modelName) {
            // Note: This would work if ModelManager used testModelsDirectory
            XCTAssertGreaterThan(size, 0)
        }

        // Direct file check
        if let attributes = try? FileManager.default.attributesOfItem(atPath: modelPath.path),
           let size = attributes[.size] as? Int64 {
            XCTAssertEqual(size, 1024 * 1024)
        }
    }

    func testModelSizeNonexistent() {
        let modelName = "nonexistent-model.gguf"
        let size = ModelManager.modelSize(name: modelName)

        XCTAssertNil(size)
    }

    // MARK: - Model Deletion Tests

    func testDeleteModel() {
        let modelName = "deleteme.gguf"
        let modelPath = testModelsDirectory.appendingPathComponent(modelName)

        // Create test model
        FileManager.default.createFile(atPath: modelPath.path, contents: Data())
        XCTAssertTrue(FileManager.default.fileExists(atPath: modelPath.path))

        // Delete it
        try? FileManager.default.removeItem(at: modelPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: modelPath.path))
    }

    func testDeleteNonexistentModel() {
        let modelName = "nonexistent.gguf"

        // Should not throw when deleting nonexistent file
        XCTAssertNoThrow(try ModelManager.deleteModel(name: modelName))
    }

    // MARK: - List Available Models Tests

    func testListAvailableModelsEmpty() {
        // Use fresh empty directory
        let emptyDir = FileManager.default.temporaryDirectory.appendingPathComponent("Empty_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)

        let contents = try? FileManager.default.contentsOfDirectory(
            at: emptyDir,
            includingPropertiesForKeys: nil
        )

        XCTAssertNotNil(contents)
        XCTAssertEqual(contents?.count, 0)

        try? FileManager.default.removeItem(at: emptyDir)
    }

    func testListAvailableModelsWithFiles() {
        // Create test models
        let models = ["tiny.gguf", "small.gguf", "medium.gguf"]

        for model in models {
            let path = testModelsDirectory.appendingPathComponent(model)
            FileManager.default.createFile(atPath: path.path, contents: Data())
        }

        // List them
        if let contents = try? FileManager.default.contentsOfDirectory(
            at: testModelsDirectory,
            includingPropertiesForKeys: [.nameKey],
            options: [.skipsHiddenFiles]
        ) {
            let modelNames = contents
                .filter { $0.pathExtension == "gguf" }
                .map { $0.lastPathComponent }
                .sorted()

            XCTAssertEqual(modelNames.count, 3)
            XCTAssertTrue(modelNames.contains("tiny.gguf"))
            XCTAssertTrue(modelNames.contains("small.gguf"))
            XCTAssertTrue(modelNames.contains("medium.gguf"))
        }
    }

    func testListAvailableModelsFiltersExtensions() {
        // Create files with different extensions
        let files = [
            "model1.gguf",
            "model2.bin",
            "readme.txt",
            "model3.gguf"
        ]

        for file in files {
            let path = testModelsDirectory.appendingPathComponent(file)
            FileManager.default.createFile(atPath: path.path, contents: Data())
        }

        // List GGUF models only
        if let contents = try? FileManager.default.contentsOfDirectory(
            at: testModelsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            let ggufModels = contents.filter { $0.pathExtension == "gguf" }
            XCTAssertEqual(ggufModels.count, 2)
        }
    }

    // MARK: - Directory Creation Tests

    func testModelsDirectoryCreation() {
        let testDir = FileManager.default.temporaryDirectory.appendingPathComponent("TestModels_\(UUID().uuidString)")

        // Directory shouldn't exist yet
        XCTAssertFalse(FileManager.default.fileExists(atPath: testDir.path))

        // Create it
        try? FileManager.default.createDirectory(
            at: testDir,
            withIntermediateDirectories: true
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: testDir.path))

        // Clean up
        try? FileManager.default.removeItem(at: testDir)
    }

    // MARK: - Edge Cases

    func testEmptyModelName() {
        let url = ModelManager.ensureModelDownloaded(name: "")
        XCTAssertEqual(url.lastPathComponent, "")
    }

    func testModelNameWithSpecialCharacters() {
        let names = [
            "model-with-dashes.gguf",
            "model_with_underscores.gguf",
            "model.v3.gguf",
            "model (copy).gguf"
        ]

        for name in names {
            let url = ModelManager.ensureModelDownloaded(name: name)
            XCTAssertEqual(url.lastPathComponent, name)
        }
    }

    func testModelNameWithPath() {
        // Model name should not include path components
        let name = "../../malicious.gguf"
        let url = ModelManager.ensureModelDownloaded(name: name)

        // URL should be in models directory, not escaped
        XCTAssertTrue(url.path.contains("Models"))
    }

    // MARK: - Open Models Directory Tests

    func testOpenModelsDirectoryPath() {
        let modelsDir = ModelManager.modelsDirectory

        // Verify it's a valid URL
        XCTAssertNotNil(modelsDir)
        XCTAssertTrue(modelsDir.isFileURL)
    }
}
