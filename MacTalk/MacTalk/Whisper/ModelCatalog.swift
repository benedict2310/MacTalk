import Foundation

struct ModelSpec: Codable, Identifiable, Hashable {
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
         revision: String = "5359861c739e955e79d9a303bcbc70fb988958b1",
         source: String = "ggerganov/whisper.cpp") {
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
    private static let revision = "5359861c739e955e79d9a303bcbc70fb988958b1"
    private static let source = "ggerganov/whisper.cpp"

    static func bundled() -> [ModelSpec] {
        [
            ModelSpec(id: "whisper-tiny-q5_1", displayName: "Tiny (Q5_1) - 32MB",
                      filename: "ggml-tiny-q5_1.bin",
                      sha256: "818710568da3ca15689e31a743197b520007872ff9576237bda97bd1b469c3d7",
                      sizeBytes: 32_152_673,
                      urls: pinnedURLs(filename: "ggml-tiny-q5_1.bin"), license: "MIT", languages: ["multilingual"], revision: revision, source: source),
            ModelSpec(id: "whisper-base-q5_1", displayName: "Base (Q5_1) - 60MB",
                      filename: "ggml-base-q5_1.bin",
                      sha256: "422f1ae452ade6f30a004d7e5c6a43195e4433bc370bf23fac9cc591f01a8898",
                      sizeBytes: 59_707_625,
                      urls: pinnedURLs(filename: "ggml-base-q5_1.bin"), license: "MIT", languages: ["multilingual"], revision: revision, source: source),
            ModelSpec(id: "whisper-small-q5_1", displayName: "Small (Q5_1) - 190MB",
                      filename: "ggml-small-q5_1.bin",
                      sha256: "ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb",
                      sizeBytes: 190_085_487,
                      urls: pinnedURLs(filename: "ggml-small-q5_1.bin"), license: "MIT", languages: ["multilingual"], revision: revision, source: source),
            ModelSpec(id: "whisper-medium-q5_0", displayName: "Medium (Q5_0) - 539MB",
                      filename: "ggml-medium-q5_0.bin",
                      sha256: "19fea4b380c3a618ec4723c3eef2eb785ffba0d0538cf43f8f235e7b3b34220f",
                      sizeBytes: 539_212_467,
                      urls: pinnedURLs(filename: "ggml-medium-q5_0.bin"), license: "MIT", languages: ["multilingual"], revision: revision, source: source),
            ModelSpec(id: "whisper-large-v3-turbo-q5_0", displayName: "Large v3 Turbo (Q5_0) - 574MB",
                      filename: "ggml-large-v3-turbo-q5_0.bin",
                      sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2",
                      sizeBytes: 574_041_195,
                      urls: pinnedURLs(filename: "ggml-large-v3-turbo-q5_0.bin"), license: "MIT", languages: ["multilingual"], revision: revision, source: source)
        ]
    }

    private static func pinnedURLs(filename: String) -> [URL] {
        [
            URL(string: "https://huggingface.co/\(source)/resolve/\(revision)/\(filename)")!,
            URL(string: "https://hf-mirror.com/\(source)/resolve/\(revision)/\(filename)")!
        ]
    }

    static func findByFilename(_ filename: String) -> ModelSpec? { bundled().first { $0.filename == filename } }
    static func findById(_ id: String) -> ModelSpec? { bundled().first { $0.id == id } }
}
