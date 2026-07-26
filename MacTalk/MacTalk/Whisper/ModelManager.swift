//
//  ModelManager.swift
//  MacTalk
//
//  Model download and management with automatic download support
//

import Foundation
import AppKit

typealias ModelDownloadOperationID = UUID

/// The model-management boundary used by production download adapters.
/// Every callback carries the operation which produced it. This is important
/// because the shared manager can be asked to replace a transfer immediately.
@MainActor
protocol ModelManaging: AnyObject {
    var onDownloadState: (@MainActor @Sendable (ModelDownloadOperationID, ModelDownloader.State) -> Void)? { get set }
    func ensureAvailable(
        _ spec: ModelSpec,
        operationID: ModelDownloadOperationID,
        onState: (@MainActor @Sendable (ModelDownloadOperationID, ModelDownloader.State) -> Void)?,
        completion: @escaping @MainActor (ModelDownloadOperationID, Result<URL, Error>) -> Void
    )
    func cancelDownload(operationID: ModelDownloadOperationID)
}

/// Enhanced ModelManager with automatic download capabilities.
/// @MainActor ensures thread-safe access to download state and callbacks.
@MainActor
final class ModelManager: ModelManaging {
    static let shared = ModelManager()
    private let downloader: ModelDownloader

    /// Legacy compatibility - points to ModelStore directory
    nonisolated static let modelsDirectory: URL = ModelStore.modelsDir

    /// Bind this from UI to receive progress updates. The operation ID is
    /// intentionally part of the callback even for this legacy observer.
    var onDownloadState: (@MainActor @Sendable (ModelDownloadOperationID, ModelDownloader.State) -> Void)?

    private var activeOperationID: ModelDownloadOperationID?
    private var currentDownloadSpec: ModelSpec?
    private var stateHandlers: [ModelDownloadOperationID: (@MainActor @Sendable (ModelDownloadOperationID, ModelDownloader.State) -> Void)] = [:]
    private var completionHandlers: [ModelDownloadOperationID: @MainActor (ModelDownloadOperationID, Result<URL, Error>) -> Void] = [:]

    /// The downloader seam lets tests provide temporary roots and an injected
    /// transport/task factory without touching the user's model store.
    init(downloader: ModelDownloader = ModelDownloader()) {
        self.downloader = downloader
        downloader.onOperationState = { [weak self] operationID, state in
            Task { @MainActor in
                self?.handle(state, operationID: operationID)
            }
        }
    }

    /// Ensure a model is available - downloads automatically if needed.
    /// The caller owns the operation ID and must use it for cancellation.
    func ensureAvailable(
        _ spec: ModelSpec,
        operationID: ModelDownloadOperationID,
        onState: (@MainActor @Sendable (ModelDownloadOperationID, ModelDownloader.State) -> Void)? = nil,
        completion: @escaping @MainActor (ModelDownloadOperationID, Result<URL, Error>) -> Void
    ) {
        if let activeOperationID {
            if activeOperationID == operationID, currentDownloadSpec?.id == spec.id {
                return
            }
            completion(operationID, .failure(NSError(
                domain: "com.mactalk.modelmanager",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Another model is currently downloading. Please wait."]
            )))
            return
        }

        activeOperationID = operationID
        currentDownloadSpec = spec
        stateHandlers[operationID] = onState
        completionHandlers[operationID] = completion
        downloader.start(spec: spec, operationID: operationID)
    }

    /// Invalidate the operation synchronously before cancelling its underlying
    /// transfer. Any cancellation callback from the downloader is therefore
    /// stale and cannot be delivered to a replacement operation.
    func cancelDownload(operationID: ModelDownloadOperationID) {
        guard activeOperationID == operationID else { return }
        activeOperationID = nil
        currentDownloadSpec = nil
        stateHandlers.removeValue(forKey: operationID)
        let completion = completionHandlers.removeValue(forKey: operationID)
        completion?(operationID, .failure(ModelDownloader.ErrorType.cancelled))
        downloader.cancel()
    }

    private func handle(_ state: ModelDownloader.State, operationID: ModelDownloadOperationID) {
        guard activeOperationID == operationID else { return }
        onDownloadState?(operationID, state)
        stateHandlers[operationID]?(operationID, state)

        switch state {
        case .done(let url):
            finish(operationID, with: .success(url))
        case .failed(let error):
            finish(operationID, with: .failure(error))
        default:
            break
        }
    }

    private func finish(_ operationID: ModelDownloadOperationID, with result: Result<URL, Error>) {
        guard activeOperationID == operationID else { return }
        activeOperationID = nil
        currentDownloadSpec = nil
        stateHandlers.removeValue(forKey: operationID)
        let completion = completionHandlers.removeValue(forKey: operationID)
        completion?(operationID, result)
    }

    // MARK: - Legacy Compatibility Methods

    /// Legacy method - now uses ModelStore
    nonisolated static func ensureModelDownloaded(name: String) -> URL {
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

    nonisolated static func listAvailableModels() -> [String] {
        return ModelStore.listAvailableModels()
    }

    nonisolated static func modelExists(name: String) -> Bool {
        let modelURL = modelsDirectory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: modelURL.path)
    }

    nonisolated static func deleteModel(name: String) throws {
        let modelURL = modelsDirectory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            return
        }
        try FileManager.default.removeItem(at: modelURL)
    }

    nonisolated static func modelSize(name: String) -> Int64? {
        let modelURL = modelsDirectory.appendingPathComponent(name)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: modelURL.path) else {
            return nil
        }
        return attributes[.size] as? Int64
    }

    nonisolated static func openModelsDirectory() {
        ModelStore.openModelsDirectory()
    }
}

// MARK: - Model Download

extension ModelManager {
    enum DownloadError: Error, Sendable {
        case invalidURL
        case downloadFailed
        case checksumMismatch
    }

    /// Download a model from Hugging Face with progress tracking
    /// This is now implemented via ensureAvailable() method
    static func downloadModel(
        name: String,
        progressHandler: @escaping @MainActor (Double) -> Void,
        completion: @escaping @MainActor (Result<URL, Error>) -> Void
    ) {
        // Find the model spec from catalog
        guard let spec = ModelCatalog.findByFilename(name) else {
            completion(.failure(DownloadError.invalidURL))
            return
        }

        // Use an operation-scoped callback rather than the shared manager's
        // singleton observer. A second request can replace this one at any
        // time without redirecting A's callbacks into B's completion.
        let operationID = UUID()
        shared.ensureAvailable(spec, operationID: operationID, onState: { _, state in
            switch state {
            case .running(let progress):
                progressHandler(progress)
            default:
                break
            }
        }) { callbackOperationID, result in
            guard callbackOperationID == operationID else { return }
            completion(result)
        }
    }
}
