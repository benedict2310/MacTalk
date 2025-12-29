//
//  ParakeetModelDownloader.swift
//  MacTalk
//
//  HuggingFace downloader for Parakeet ASR models with progress
//

import Foundation
import FluidAudio

final class ParakeetModelDownloader: @unchecked Sendable {
    enum State: Equatable, Sendable {
        case idle
        case running(progress: Double, fileIndex: Int, fileCount: Int, currentFile: String?)
        case verifying
        case done(URL)
        case failed(Error)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle):
                return true
            case (.running(let p1, let i1, let c1, let f1), .running(let p2, let i2, let c2, let f2)):
                return p1 == p2 && i1 == i2 && c1 == c2 && f1 == f2
            case (.verifying, .verifying):
                return true
            case (.done(let u1), .done(let u2)):
                return u1 == u2
            case (.failed(let e1), .failed(let e2)):
                return e1.localizedDescription == e2.localizedDescription
            default:
                return false
            }
        }
    }

    enum ErrorType: LocalizedError, Sendable {
        case invalidResponse
        case rateLimited(Int)
        case noFiles
        case downloadFailed(String)
        case modelMissing(String)

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "Invalid response from model registry."
            case .rateLimited(let status):
                return "Model download was rate limited (HTTP \(status))."
            case .noFiles:
                return "No model files were found to download."
            case .downloadFailed(let path):
                return "Failed to download model file: \(path)"
            case .modelMissing(let name):
                return "Required model file missing: \(name)"
            }
        }
    }

    var onState: (@MainActor (State) -> Void)?

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    static var modelsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("MacTalk/Parakeet", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var repoDirectory: URL {
        modelsDirectory.appendingPathComponent(Repo.parakeet.folderName, isDirectory: true)
    }

    func modelsAvailable() -> Bool {
        let repoPath = Self.repoDirectory
        let required = ModelNames.ASR.requiredModels
        let vocabName = ModelNames.ASR.vocabulary(for: .parakeet)

        let requiredPaths = required.map { repoPath.appendingPathComponent($0).path }
        let vocabPath = repoPath.appendingPathComponent(vocabName).path

        let allModelsExist = requiredPaths.allSatisfy { FileManager.default.fileExists(atPath: $0) }
        return allModelsExist && FileManager.default.fileExists(atPath: vocabPath)
    }

    @discardableResult
    func downloadIfNeeded() async throws -> URL {
        do {
            if modelsAvailable() {
                notifyState(.done(Self.repoDirectory))
                return Self.repoDirectory
            }

            let filesToDownload = try await listFilesToDownload()
            guard !filesToDownload.isEmpty else {
                throw ErrorType.noFiles
            }

            let repoPath = Self.repoDirectory
            try? FileManager.default.createDirectory(at: repoPath, withIntermediateDirectories: true)

            notifyState(.running(progress: 0, fileIndex: 0, fileCount: filesToDownload.count, currentFile: nil))

            for (index, filePath) in filesToDownload.enumerated() {
                let destPath = repoPath.appendingPathComponent(filePath)

                if FileManager.default.fileExists(atPath: destPath.path) {
                    let progress = Double(index + 1) / Double(filesToDownload.count)
                    notifyState(.running(
                        progress: progress,
                        fileIndex: index + 1,
                        fileCount: filesToDownload.count,
                        currentFile: filePath
                    ))
                    continue
                }

                try FileManager.default.createDirectory(
                    at: destPath.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )

                let encodedPath = filePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filePath
                let fileURL = try ModelRegistry.resolveModel(Repo.parakeet.remotePath, encodedPath)
                DLOG("Parakeet download URL: \(fileURL.absoluteString)")

                let (tempURL, response) = try await session.download(for: authorizedRequest(url: fileURL))

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw ErrorType.invalidResponse
                }

                if httpResponse.statusCode == 429 || httpResponse.statusCode == 503 {
                    throw ErrorType.rateLimited(httpResponse.statusCode)
                }

                guard (200..<300).contains(httpResponse.statusCode) else {
                    throw ErrorType.downloadFailed(filePath)
                }

                if FileManager.default.fileExists(atPath: destPath.path) {
                    try? FileManager.default.removeItem(at: destPath)
                }
                try FileManager.default.moveItem(at: tempURL, to: destPath)

                let progress = Double(index + 1) / Double(filesToDownload.count)
                notifyState(.running(
                    progress: progress,
                    fileIndex: index + 1,
                    fileCount: filesToDownload.count,
                    currentFile: filePath
                ))
            }

            notifyState(.verifying)
            try verifyModelsExist()

            notifyState(.done(repoPath))
            return repoPath
        } catch {
            notifyState(.failed(error))
            throw error
        }
    }

    private func notifyState(_ state: State) {
        Task { @MainActor in
            self.onState?(state)
        }
    }

    private func verifyModelsExist() throws {
        let repoPath = Self.repoDirectory
        let required = ModelNames.ASR.requiredModels
        let vocabName = ModelNames.ASR.vocabulary(for: .parakeet)

        for model in required {
            let path = repoPath.appendingPathComponent(model).path
            guard FileManager.default.fileExists(atPath: path) else {
                throw ErrorType.modelMissing(model)
            }
        }

        let vocabPath = repoPath.appendingPathComponent(vocabName).path
        guard FileManager.default.fileExists(atPath: vocabPath) else {
            throw ErrorType.modelMissing(vocabName)
        }
    }

    private func listFilesToDownload() async throws -> [String] {
        let repo = Repo.parakeet
        let required = ModelNames.ASR.requiredModels

        var filesToDownload: [String] = []

        func listDirectory(path: String) async throws {
            let apiPath = path.isEmpty ? "tree/main" : "tree/main/\(path)"
            let dirURL = try ModelRegistry.apiModels(repo.remotePath, apiPath)
            let (dirData, response) = try await session.data(for: authorizedRequest(url: dirURL))

            guard let httpResponse = response as? HTTPURLResponse else {
                throw ErrorType.invalidResponse
            }

            if httpResponse.statusCode == 429 || httpResponse.statusCode == 503 {
                throw ErrorType.rateLimited(httpResponse.statusCode)
            }

            guard let items = try JSONSerialization.jsonObject(with: dirData) as? [[String: Any]] else {
                return
            }

            for item in items {
                guard let itemPath = item["path"] as? String,
                      let itemType = item["type"] as? String else {
                    continue
                }

                if itemType == "directory" {
                    let shouldProcess = required.contains { itemPath.hasPrefix($0) || $0.hasPrefix(itemPath + "/") }
                    if shouldProcess || required.isEmpty {
                        try await listDirectory(path: itemPath)
                    }
                } else if itemType == "file" {
                    let matchesRequired = required.contains { itemPath.hasPrefix($0) }
                    let isMetadata = itemPath.hasSuffix(".json") || itemPath.hasSuffix(".txt")

                    if matchesRequired || isMetadata {
                        filesToDownload.append(itemPath)
                    }
                }
            }
        }

        try await listDirectory(path: "")

        return filesToDownload.sorted()
    }

    private static var huggingFaceToken: String? {
        ProcessInfo.processInfo.environment["HF_TOKEN"]
            ?? ProcessInfo.processInfo.environment["HUGGING_FACE_HUB_TOKEN"]
            ?? ProcessInfo.processInfo.environment["HUGGINGFACEHUB_API_TOKEN"]
    }

    private func authorizedRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        if let token = Self.huggingFaceToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }
}
