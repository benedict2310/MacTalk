import Foundation

struct ModelSpec: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var provider: ASRProvider { .whisper }
    let displayName: String
    let filename: String
    let sha256: String
    let sizeBytes: Int64
    let urls: [URL]
    let license: String?
    let languages: [String]?
    /// Immutable model-repository revision used by every URL in this spec.
    let revision: String
    /// Immutable source repository identifier (kept separate from mirror URLs).
    let source: String

    init(id: String, displayName: String, filename: String, sha256: String,
         sizeBytes: Int64, urls: [URL], license: String?, languages: [String]?,
         revision: String = GeneratedModelProvenance.whisperRevision,
         source: String = GeneratedModelProvenance.whisperRepository) {
        self.id = id
        self.displayName = displayName
        self.filename = filename
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
        self.urls = urls
        self.license = license
        self.languages = languages
        self.revision = revision
        self.source = source
    }
}

enum ModelCatalog {
    static func bundled() -> [ModelSpec] {
        GeneratedModelProvenance.whisper.map { model in
            ModelSpec(
                id: model.id,
                displayName: model.displayName,
                filename: model.filename,
                sha256: model.sha256,
                sizeBytes: model.sizeBytes,
                urls: pinnedURLs(filename: model.filename),
                license: model.license,
                languages: model.languages,
                revision: model.revision,
                source: model.source
            )
        }
    }

    /// The first URL is the provenance authority. The second is only a
    /// byte-source fallback; credentials are deliberately never sent there.
    private static func pinnedURLs(filename: String) -> [URL] {
        [
            URL(string: "https://huggingface.co/\(GeneratedModelProvenance.whisperRepository)/resolve/\(GeneratedModelProvenance.whisperRevision)/\(filename)")!,
            URL(string: "https://hf-mirror.com/\(GeneratedModelProvenance.whisperRepository)/resolve/\(GeneratedModelProvenance.whisperRevision)/\(filename)")!
        ]
    }

    static func findByFilename(_ filename: String) -> ModelSpec? { bundled().first { $0.filename == filename } }
    static func findById(_ id: String) -> ModelSpec? { bundled().first { $0.id == id } }
}
