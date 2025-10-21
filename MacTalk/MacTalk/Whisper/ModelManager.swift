//
//  ModelManager.swift
//  MacTalk
//
//  Model download and management
//

import Foundation

enum ModelManager {
    static let modelsDirectory: URL = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return appSupport
            .appendingPathComponent("MacTalk", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }()

    static func ensureModelDownloaded(name: String) -> URL {
        // Create models directory if it doesn't exist
        try? FileManager.default.createDirectory(
            at: modelsDirectory,
            withIntermediateDirectories: true
        )

        let modelURL = modelsDirectory.appendingPathComponent(name)

        if !FileManager.default.fileExists(atPath: modelURL.path) {
            // Create a README file with download instructions
            let readmePath = modelsDirectory.appendingPathComponent("README.txt")
            let readmeContent = """
            MacTalk Models Directory
            ========================

            Place your Whisper GGUF model files here.

            Download models from:
            https://huggingface.co/ggerganov/whisper.cpp/tree/main

            Recommended models:
            - ggml-tiny-q5_0.gguf (~75 MB, fastest)
            - ggml-base-q5_0.gguf (~140 MB, fast)
            - ggml-small-q5_0.gguf (~460 MB, balanced, recommended)
            - ggml-medium-q5_0.gguf (~1.4 GB, high accuracy)
            - ggml-large-v3-turbo-q5_0.gguf (~2.8 GB, highest accuracy)

            Example download command:
            curl -L -o "\(name)" \\
                "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(name)"

            Current model path:
            \(modelURL.path)
            """

            try? readmeContent.write(
                to: readmePath,
                atomically: true,
                encoding: .utf8
            )

            print("Model not found. Created README at: \(readmePath.path)")
        }

        return modelURL
    }

    static func listAvailableModels() -> [String] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: modelsDirectory,
            includingPropertiesForKeys: [.nameKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return contents
            .filter { $0.pathExtension == "gguf" || $0.pathExtension == "bin" }
            .map { $0.lastPathComponent }
            .sorted()
    }

    static func modelExists(name: String) -> Bool {
        let modelURL = modelsDirectory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: modelURL.path)
    }

    static func deleteModel(name: String) throws {
        let modelURL = modelsDirectory.appendingPathComponent(name)
        try FileManager.default.removeItem(at: modelURL)
    }

    static func modelSize(name: String) -> Int64? {
        let modelURL = modelsDirectory.appendingPathComponent(name)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: modelURL.path) else {
            return nil
        }
        return attributes[.size] as? Int64
    }

    static func openModelsDirectory() {
        NSWorkspace.shared.open(modelsDirectory)
    }
}

// MARK: - Model Download (Future Enhancement)

extension ModelManager {
    enum DownloadError: Error {
        case invalidURL
        case downloadFailed
        case checksumMismatch
    }

    /// Download a model from Hugging Face (placeholder for future implementation)
    static func downloadModel(
        name: String,
        progressHandler: @escaping (Double) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        // TODO: Implement actual download with URLSession
        // For now, just show instructions

        let modelURL = modelsDirectory.appendingPathComponent(name)
        completion(.failure(DownloadError.downloadFailed))
    }
}
