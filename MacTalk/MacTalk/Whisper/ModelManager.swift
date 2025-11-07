//
//  ModelManager.swift
//  MacTalk
//
//  Model download and management with automatic download support
//

import Foundation
import AppKit

/// Enhanced ModelManager with automatic download capabilities
final class ModelManager {
    static let shared = ModelManager()
    private let downloader = ModelDownloader()

    /// Legacy compatibility - points to ModelStore directory
    static let modelsDirectory: URL = ModelStore.modelsDir

    /// Bind this from UI to receive progress updates
    var onDownloadState: ((ModelDownloader.State) -> Void)? {
        didSet {
            downloader.onState = { [weak self] state in
                self?.onDownloadState?(state)
            }
        }
    }

    private init() {}

    /// Ensure a model is available - downloads automatically if needed
    /// - Parameters:
    ///   - spec: The model specification to ensure is available
    ///   - completion: Called with the model URL on success, or error on failure
    func ensureAvailable(_ spec: ModelSpec, completion: @escaping (Result<URL, Error>) -> Void) {
        if ModelStore.exists(spec) {
            completion(.success(ModelStore.path(for: spec)))
            return
        }

        downloader.onState = { state in
            switch state {
            case .done(let url):
                completion(.success(url))
            case .failed(let error):
                completion(.failure(error))
            default:
                break
            }
        }

        downloader.start(spec: spec)
    }

    /// Cancel ongoing download
    func cancelDownload() {
        downloader.cancel()
    }

    // MARK: - Legacy Compatibility Methods

    /// Legacy method - now uses ModelStore
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

            MacTalk now supports automatic model downloads!

            Models can be automatically downloaded through the app's menu bar:
            1. Click the MacTalk icon in the menu bar
            2. Select "Model" submenu
            3. Choose your desired model - it will download automatically

            Available models:
            - Tiny (Q5_1) - 32MB, fastest
            - Base (Q5_1) - 56MB, fast
            - Small (Q5_1) - 182MB, balanced
            - Medium (Q5_0) - 515MB, high accuracy
            - Large v3 Turbo (Q5_0) - 1.5GB, highest accuracy

            All downloads include:
            - Automatic resume if interrupted
            - SHA-256 checksum verification
            - Multiple mirror fallback
            - Progress tracking

            Manual download (if needed):
            https://huggingface.co/ggerganov/whisper.cpp/tree/main

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
        return ModelStore.listAvailableModels()
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
        ModelStore.openModelsDirectory()
    }
}

// MARK: - Model Download

extension ModelManager {
    enum DownloadError: Error {
        case invalidURL
        case downloadFailed
        case checksumMismatch
    }

    /// Download a model from Hugging Face with progress tracking
    /// This is now implemented via ensureAvailable() method
    static func downloadModel(
        name: String,
        progressHandler: @escaping (Double) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        // Find the model spec from catalog
        guard let spec = ModelCatalog.findByFilename(name) else {
            completion(.failure(DownloadError.invalidURL))
            return
        }

        // Use the shared manager to download
        shared.onDownloadState = { state in
            switch state {
            case .running(let progress):
                progressHandler(progress)
            case .done(let url):
                completion(.success(url))
            case .failed(let error):
                completion(.failure(error))
            default:
                break
            }
        }

        shared.ensureAvailable(spec) { result in
            // Completion already handled by onDownloadState callback
        }
    }
}
