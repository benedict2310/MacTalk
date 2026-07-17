//
//  ParakeetModelDownloader.swift
//  MacTalk
//
//  Immutable, manifest-driven Hugging Face downloader for Parakeet v3.
//

import Foundation
import FluidAudio

struct ParakeetManifestEntry: Codable, Hashable, Sendable {
    let path: String
    let size: Int64
    let sha256: String
}

final class ParakeetModelDownloader: @unchecked Sendable {
    typealias DownloadTaskFactory = @Sendable (URLRequest) async throws -> (URL, URLResponse)
    static let repository = "FluidInference/parakeet-tdt-0.6b-v3-coreml"
    static let revision = "aed02740059203c4a87495924f685de3722ae9ce"
    static let fluidAudioRevision = "19600a485baa4998812e4654b70d2bab8f2c9949"

    static let manifest: [ParakeetManifestEntry] = [
        .init(path: "Decoder.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "4238c4e81ecd0dc94bd7dfbb60f7e2cc824107c1ffe0387b8607b72833dba350"),
        .init(path: "Decoder.mlmodelc/coremldata.bin", size: 554, sha256: "18647af085d87bd8f3121c8a9b4d4564c1ede038dab63d295b4e745cf2d7fb99"),
        .init(path: "Decoder.mlmodelc/metadata.json", size: 3427, sha256: "a39e93cd8371b8ded92635c7804fcd0590f0d1dd9415c6d19a0484be073077d9"),
        .init(path: "Decoder.mlmodelc/model.mil", size: 13110, sha256: "ef2a0a281695398a62fde86ac269c68f73d5b578d7ed3b31f2ba91a2d1ea1f35"),
        .init(path: "Decoder.mlmodelc/weights/weight.bin", size: 23604992, sha256: "48adf0f0d47c406c8253d4f7fef967436a39da14f5a65e66d5a4b407be355d41"),
        .init(path: "Encoder.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "42e638870d73f26b332918a3496ce36793fbb413a81cbd3d16ba01328637a105"),
        .init(path: "Encoder.mlmodelc/coremldata.bin", size: 485, sha256: "d48034a167a82e88fc3df64f60af963ab3983538271175b8319e7d5720a0fb86"),
        .init(path: "Encoder.mlmodelc/metadata.json", size: 2921, sha256: "da24da9cca943fb29d7fa8e376d57fca7cb3aa08ca51b956b0b0e56813f087e9"),
        .init(path: "Encoder.mlmodelc/model.mil", size: 959769, sha256: "ed7b19156ca29fa7dfd6891deb9fda4b0e8893f68597c985d135736546a43808"),
        .init(path: "Encoder.mlmodelc/weights/weight.bin", size: 445187200, sha256: "e2020f323703477a5b21d7c2d282c403e371afb5962e79877e3033e73ba6f421"),
        .init(path: "JointDecisionv3.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "26def4bf73dd56d29dee21c8ef97cb8969e62f6120ed1adc91e46828e2737b6c"),
        .init(path: "JointDecisionv3.mlmodelc/coremldata.bin", size: 521, sha256: "f5fc08b741400f0088492c9e839418b1e18522f19cba28d361dd030c5f398342"),
        .init(path: "JointDecisionv3.mlmodelc/metadata.json", size: 3453, sha256: "d9307211b9a37e0f0ac260c7660b1571a3de25841035cfdf9b58fd40425f890f"),
        .init(path: "JointDecisionv3.mlmodelc/model.mil", size: 11775, sha256: "be60732943389a047175111a83f8839f3eb39d4803adafa828a0871b2f39818d"),
        .init(path: "JointDecisionv3.mlmodelc/weights/weight.bin", size: 12642764, sha256: "4e0e63d840032f7f07ddb1d64446051166281e5491bf22da8a945c41f6eedb3e"),
        .init(path: "Preprocessor.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "c9beeb989c8d66f8be11df59bc6df277ec76cee404f6865b46243835ef562f6d"),
        .init(path: "Preprocessor.mlmodelc/coremldata.bin", size: 486, sha256: "dbde3f2300842c1fd51ef3ff948a0bcffe65ffd2dca10707f2509f32c1d65b1d"),
        .init(path: "Preprocessor.mlmodelc/metadata.json", size: 2841, sha256: "2a98699e22d279dd37fa1d238aeb1c6db1df0d6fad687775324157689d8f3acf"),
        .init(path: "Preprocessor.mlmodelc/model.mil", size: 28181, sha256: "4b8518a956450fec57f06c2a21bdffc26973f7f1fa6842fb38fe917f896b6b93"),
        .init(path: "Preprocessor.mlmodelc/weights/weight.bin", size: 491072, sha256: "129b76e3aeafa8afa3ea76d995b964b145fe83700d579f6ff42c4c38fa0968ea"),
        .init(path: "parakeet_vocab.json", size: 151122, sha256: "7ec60e05f1b24480736ec0eed40900f4626bce1fa9a60fd700ec7e2a59198735")
    ]

    enum State: Equatable, Sendable {
        case idle
        case running(progress: Double, fileIndex: Int, fileCount: Int, currentFile: String?)
        case verifying
        case done(URL)
        case failed(Error)
        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.verifying, .verifying): return true
            case let (.running(a,b,c,d), .running(e,f,g,h)): return a == e && b == f && c == g && d == h
            case let (.done(a), .done(b)): return a == b
            case let (.failed(a), .failed(b)): return a.localizedDescription == b.localizedDescription
            default: return false
            }
        }
    }

    enum ErrorType: LocalizedError, Sendable {
        case invalidResponse
        case cancelled
        case rateLimited(Int)
        case unauthorized
        case downloadFailed(String)
        case corruptFile(String)
        case modelMissing(String)
        case invalidManifest
        case pathTraversal(String)
        case absolutePath(String)
        case dotPath(String)
        case symlink(String)
        case unexpectedFile(String)
        case duplicatePath(String)

        var errorDescription: String? {
            switch self {
            case .invalidResponse: return "Invalid response from model registry."
            case .cancelled: return "Model download was cancelled."
            case .rateLimited(let status): return "Model download was rate limited (HTTP \(status))."
            case .unauthorized: return "Model download authorization failed."
            case .downloadFailed(let path): return "Failed to download model file: \(path)"
            case .corruptFile(let path): return "Parakeet model file failed integrity verification: \(path)"
            case .modelMissing(let path): return "Required model file missing: \(path)"
            case .invalidManifest: return "Parakeet model manifest is invalid."
            case .pathTraversal(let path): return "Unsafe model path: \(path)"
            case .absolutePath(let path): return "Absolute model path is not allowed: \(path)"
            case .dotPath(let path): return "Dot path is not allowed: \(path)"
            case .symlink(let path): return "Symlink model path is not allowed: \(path)"
            case .unexpectedFile(let path): return "Unexpected model file: \(path)"
            case .duplicatePath(let path): return "Duplicate model path: \(path)"
            }
        }
    }

    var onState: (@MainActor (State) -> Void)?
    let repoDirectory: URL
    /// Must stay in lockstep with FluidAudio's Repo.parakeetV3.folderName.
    static let folderName = Repo.parakeetV3.folderName
    private let session: URLSession
    private let taskFactory: DownloadTaskFactory?
    private let root: URL
    private var operation: Task<URL, Error>?
    private var generation = 0

    init(session: URLSession = .shared, modelsRoot: URL? = nil, repoDirectory: URL? = nil,
         taskFactory: DownloadTaskFactory? = nil) {
        self.session = session
        self.taskFactory = taskFactory
        self.root = modelsRoot ?? Self.modelsDirectory
        self.repoDirectory = repoDirectory ?? self.root.appendingPathComponent(Self.folderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        cleanupStaleArtifacts()
    }

    static var modelsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MacTalk/Parakeet", isDirectory: true)
    }

    static var repoDirectory: URL { modelsDirectory.appendingPathComponent(folderName, isDirectory: true) }

    func modelsAvailable() -> Bool {
        do {
            try validateActive()
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func downloadIfNeeded() async throws -> URL {
        try Self.validateManifest()
        if modelsAvailable() {
            notifyState(.done(repoDirectory))
            return repoDirectory
        }
        operation?.cancel()
        generation += 1
        let currentGeneration = generation
        let task = Task { [weak self] () throws -> URL in
            guard let self else { throw ErrorType.cancelled }
            return try await self.performDownload(generation: currentGeneration)
        }
        operation = task
        defer { if self.generation == currentGeneration { self.operation = nil } }
        return try await task.value
    }

    func cancel() {
        generation += 1
        operation?.cancel()
        operation = nil
        notifyState(.failed(ErrorType.cancelled))
    }

    private func performDownload(generation: Int) async throws -> URL {
        let staging = root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        var activated = false
        defer { if !activated { try? FileManager.default.removeItem(at: staging) } }
        do {
            notifyState(.running(progress: 0, fileIndex: 0, fileCount: Self.manifest.count, currentFile: nil))
            for (index, entry) in Self.manifest.enumerated() {
                try check(generation)
                let target = try safeURL(entry.path, under: staging)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                let url = URL(string: "https://huggingface.co/\(Self.repository)/resolve/\(Self.revision)/\(entry.path)")!
                let request = authorizedRequest(url: url)
                let (temporary, response): (URL, URLResponse)
                if let taskFactory {
                    (temporary, response) = try await taskFactory(request)
                } else {
                    (temporary, response) = try await session.download(for: request)
                }
                try check(generation)
                defer { try? FileManager.default.removeItem(at: temporary) }
                guard let http = response as? HTTPURLResponse else { throw ErrorType.invalidResponse }
                switch http.statusCode {
                case 401, 403: throw ErrorType.unauthorized
                case 429, 503: throw ErrorType.rateLimited(http.statusCode)
                case 200..<300: break
                default: throw ErrorType.downloadFailed(entry.path)
                }
                try verify(source: temporary, entry: entry)
                try check(generation)
                try FileManager.default.moveItem(at: temporary, to: target)
                notifyState(.running(progress: Double(index + 1) / Double(Self.manifest.count), fileIndex: index + 1, fileCount: Self.manifest.count, currentFile: entry.path))
            }
            try check(generation)
            notifyState(.verifying)
            try validateSet(at: staging)
            try writeManifest(nextTo: staging)
            try check(generation)
            try activate(staging: staging)
            activated = true
            notifyState(.done(repoDirectory))
            return repoDirectory
        } catch {
            let wasCancelled = Task.isCancelled || self.generation != generation
            let finalError: Error = wasCancelled ? ErrorType.cancelled : error
            // cancel() already emitted the terminal state for an invalidated
            // generation; stale work must not emit a second terminal event.
            if self.generation == generation { notifyState(.failed(finalError)) }
            throw finalError
        }
    }

    private func check(_ expectedGeneration: Int) throws {
        guard !Task.isCancelled, self.generation == expectedGeneration else { throw ErrorType.cancelled }
    }

    /// Validates the fixed manifest itself, including path safety and duplicate rejection.
    static func validateManifest() throws { try validateManifest(manifest) }

    /// Kept internal for hermetic tests of path and duplicate handling.
    static func validateManifest(_ entries: [ParakeetManifestEntry]) throws {
        var seen = Set<String>()
        for entry in entries {
            guard seen.insert(entry.path).inserted else { throw ErrorType.duplicatePath(entry.path) }
            if entry.path.hasPrefix("/") { throw ErrorType.absolutePath(entry.path) }
            let components = entry.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard !components.contains("..") else { throw ErrorType.pathTraversal(entry.path) }
            guard !components.contains(".") else { throw ErrorType.dotPath(entry.path) }
            guard components.allSatisfy({ !$0.isEmpty }) else { throw ErrorType.pathTraversal(entry.path) }
            guard entry.size >= 0, entry.sha256.count == 64,
                  entry.sha256.allSatisfy({ $0.isNumber || ("a"..."f").contains($0) }) else { throw ErrorType.invalidManifest }
        }
    }

    private func validateActive() throws {
        try Self.validateManifest()
        let sidecar = manifestURL(for: repoDirectory)
        guard let data = try? Data(contentsOf: sidecar),
              let identity = try? JSONDecoder().decode(ManifestIdentity.self, from: data),
              identity.repository == Self.repository, identity.revision == Self.revision,
              identity.files == Self.manifest else { throw ErrorType.invalidManifest }
        try validateSet(at: repoDirectory)
    }

    private func validateSet(at directory: URL) throws {
        var expected = Set<String>()
        for entry in Self.manifest {
            let file = try safeURL(entry.path, under: directory)
            expected.insert(entry.path)
            guard isRegularFile(file), !isSymlink(file) else { throw ErrorType.symlink(entry.path) }
            try verify(source: file, entry: entry)
        }
        // The identity sidecar is part of the activated tree, but not a model
        // payload entry. Exact-set validation explicitly accounts for it.
        expected.insert(manifestFileName)
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: []) else { throw ErrorType.invalidManifest }
        for case let file as URL in enumerator {
            if isSymlink(file) { throw ErrorType.symlink(relative(file, from: directory)) }
            let values = try file.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == false {
                let path = relative(file, from: directory)
                guard expected.contains(path) else { throw ErrorType.unexpectedFile(path) }
            }
        }
    }

    private func verify(source: URL, entry: ParakeetManifestEntry) throws {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: source.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value, size == entry.size,
              let digest = try? SHA256Streamer.hashFile(at: source), digest == entry.sha256 else {
            throw ErrorType.corruptFile(entry.path)
        }
    }

    private struct ManifestIdentity: Codable, Equatable {
        let repository: String
        let revision: String
        let files: [ParakeetManifestEntry]
    }

    private func writeManifest(nextTo directory: URL) throws {
        let data = try JSONEncoder().encode(ManifestIdentity(repository: Self.repository, revision: Self.revision, files: Self.manifest))
        let url = manifestURL(for: directory)
        try data.write(to: url, options: .atomic)
    }

    private let manifestFileName = ".mactalk-manifest.json"

    private func manifestURL(for directory: URL) -> URL { directory.appendingPathComponent(manifestFileName) }

    private func activate(staging: URL) throws {
        let manager = FileManager.default
        let backup = root.appendingPathComponent(".backup-\(UUID().uuidString)")
        var movedOld = false
        do {
            if manager.fileExists(atPath: repoDirectory.path) {
                try manager.moveItem(at: repoDirectory, to: backup)
                movedOld = true
            }
            try manager.moveItem(at: staging, to: repoDirectory)
            if movedOld { try? manager.removeItem(at: backup) }
        } catch {
            try? manager.removeItem(at: repoDirectory)
            if movedOld { try? manager.moveItem(at: backup, to: repoDirectory) }
            throw error
        }
    }

    private func safeURL(_ path: String, under root: URL) throws -> URL {
        try Self.validatePath(path)
        let url = root.appendingPathComponent(path)
        let rootPath = root.standardizedFileURL.path.hasSuffix("/") ? root.standardizedFileURL.path : root.standardizedFileURL.path + "/"
        guard url.standardizedFileURL.path.hasPrefix(rootPath) else { throw ErrorType.pathTraversal(path) }
        return url
    }

    static func validatePath(_ path: String) throws {
        if path.hasPrefix("/") { throw ErrorType.absolutePath(path) }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if components.contains("..") { throw ErrorType.pathTraversal(path) }
        if components.contains(".") { throw ErrorType.dotPath(path) }
        if components.contains(where: { $0.isEmpty }) { throw ErrorType.pathTraversal(path) }
    }

    private func isRegularFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]) else { return false }
        return values.isRegularFile == true
    }

    private func isSymlink(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]) else { return false }
        return values.isSymbolicLink == true
    }

    private func relative(_ url: URL, from root: URL) -> String {
        let prefix = root.standardizedFileURL.path + "/"
        return String(url.standardizedFileURL.path.dropFirst(prefix.count))
    }

    private func authorizedRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        guard url.scheme?.lowercased() == "https", url.host == "huggingface.co" else { return request }
        if let token = ProcessInfo.processInfo.environment["HF_TOKEN"]
            ?? ProcessInfo.processInfo.environment["HUGGING_FACE_HUB_TOKEN"]
            ?? ProcessInfo.processInfo.environment["HUGGINGFACEHUB_API_TOKEN"] {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func cleanupStaleArtifacts() {
        guard let items = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for item in items where item.lastPathComponent.hasPrefix(".staging-") || item.lastPathComponent.hasPrefix(".backup-") {
            try? FileManager.default.removeItem(at: item)
        }
    }

    private func notifyState(_ state: State) {
        Task { @MainActor in self.onState?(state) }
    }
}
