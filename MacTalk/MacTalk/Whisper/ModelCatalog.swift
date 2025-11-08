import Foundation

struct ModelSpec: Codable, Identifiable, Hashable {
    let id: String                 // e.g. "whisper-large-v3-turbo-q5_0"
    let displayName: String        // UI label
    let filename: String           // local file name (.gguf)
    let sha256: String             // lowercase hex digest (full file)
    let sizeBytes: Int64           // expected size in bytes (0 if unknown)
    let urls: [URL]                // mirrors in priority order
    let license: String?           // optional
    let languages: [String]?       // optional
}

enum ModelCatalog {
    /// Bundled model catalog with HuggingFace URLs
    ///
    /// Note: SHA-256 checksums are currently empty to allow downloads to succeed.
    /// The whisper.cpp repository only publishes SHA-1 hashes, not SHA-256.
    /// For enhanced security, compute and add SHA-256 checksums manually.
    /// When sha256 is empty, only file size validation is performed.
    ///
    /// To add checksums:
    /// 1. Download a model from HuggingFace
    /// 2. Run: shasum -a 256 <model-file>
    /// 3. Update the sha256 field below
    static func bundled() -> [ModelSpec] {
        return [
            ModelSpec(
                id: "whisper-tiny-q5_1",
                displayName: "Tiny (Q5_1) - 32MB",
                filename: "ggml-tiny-q5_1.bin",
                sha256: "", // TODO: Add real SHA-256 checksum for security
                sizeBytes: 32_200_000,
                urls: [
                    URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny-q5_1.bin")!,
                    URL(string: "https://hf-mirror.com/ggerganov/whisper.cpp/resolve/main/ggml-tiny-q5_1.bin")!
                ],
                license: "MIT",
                languages: ["multilingual"]
            ),
            ModelSpec(
                id: "whisper-base-q5_1",
                displayName: "Base (Q5_1) - 60MB",
                filename: "ggml-base-q5_1.bin",
                sha256: "", // TODO: Add real SHA-256 checksum for security
                sizeBytes: 59_700_000, // 59.7 MB from HuggingFace
                urls: [
                    URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base-q5_1.bin")!,
                    URL(string: "https://hf-mirror.com/ggerganov/whisper.cpp/resolve/main/ggml-base-q5_1.bin")!
                ],
                license: "MIT",
                languages: ["multilingual"]
            ),
            ModelSpec(
                id: "whisper-small-q5_1",
                displayName: "Small (Q5_1) - 190MB",
                filename: "ggml-small-q5_1.bin",
                sha256: "", // TODO: Add real SHA-256 checksum for security
                sizeBytes: 190_000_000, // 190 MB from HuggingFace
                urls: [
                    URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small-q5_1.bin")!,
                    URL(string: "https://hf-mirror.com/ggerganov/whisper.cpp/resolve/main/ggml-small-q5_1.bin")!
                ],
                license: "MIT",
                languages: ["multilingual"]
            ),
            ModelSpec(
                id: "whisper-medium-q5_0",
                displayName: "Medium (Q5_0) - 539MB",
                filename: "ggml-medium-q5_0.bin",
                sha256: "", // TODO: Add real SHA-256 checksum for security
                sizeBytes: 539_000_000, // 539 MB from HuggingFace
                urls: [
                    URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium-q5_0.bin")!,
                    URL(string: "https://hf-mirror.com/ggerganov/whisper.cpp/resolve/main/ggml-medium-q5_0.bin")!
                ],
                license: "MIT",
                languages: ["multilingual"]
            ),
            ModelSpec(
                id: "whisper-large-v3-turbo-q5_0",
                displayName: "Large v3 Turbo (Q5_0) - 574MB",
                filename: "ggml-large-v3-turbo-q5_0.bin",
                sha256: "", // TODO: Add real SHA-256 checksum for security
                sizeBytes: 574_000_000, // 574 MB from HuggingFace (NOT 1.5GB!)
                urls: [
                    URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin")!,
                    URL(string: "https://hf-mirror.com/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin")!
                ],
                license: "MIT",
                languages: ["multilingual"]
            )
        ]
    }

    /// Find a model spec by filename
    static func findByFilename(_ filename: String) -> ModelSpec? {
        return bundled().first { $0.filename == filename }
    }

    /// Find a model spec by ID
    static func findById(_ id: String) -> ModelSpec? {
        return bundled().first { $0.id == id }
    }
}
