import Foundation

enum ModelStore {
    static var modelsDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("MacTalk/Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var downloadsDir: URL {
        let dir = modelsDir.appendingPathComponent(".downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func path(for spec: ModelSpec) -> URL {
        modelsDir.appendingPathComponent(spec.filename)
    }

    static func exists(_ spec: ModelSpec) -> Bool {
        FileManager.default.fileExists(atPath: path(for: spec).path)
    }

    static func freeSpaceBytes() -> Int64? {
        do {
            let attrs = try FileManager.default.attributesOfFileSystem(forPath: modelsDir.path)
            return (attrs[.systemFreeSize] as? NSNumber)?.int64Value
        } catch {
            return nil
        }
    }

    /// List all available models (GGUF and BIN files)
    static func listAvailableModels() -> [String] {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(atPath: modelsDir.path) else {
            return []
        }
        return files.filter { $0.hasSuffix(".gguf") || $0.hasSuffix(".bin") }
    }

    /// Get file size for a model spec
    static func fileSize(for spec: ModelSpec) -> Int64? {
        let url = path(for: spec)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else {
            return nil
        }
        return size.int64Value
    }

    /// Delete a model file
    static func delete(_ spec: ModelSpec) throws {
        let url = path(for: spec)
        try FileManager.default.removeItem(at: url)
    }

    /// Open the models directory in Finder
    static func openModelsDirectory() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: modelsDir.path)
    }
}
