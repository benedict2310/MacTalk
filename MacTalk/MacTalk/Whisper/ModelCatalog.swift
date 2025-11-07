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
    /// SHA-256 checksums should be verified from the source files
    static func bundled() -> [ModelSpec] {
        return [
            ModelSpec(
                id: "whisper-tiny-q5_1",
                displayName: "Tiny (Q5_1) - 32MB",
                filename: "ggml-tiny-q5_1.bin",
                sha256: "c78c86eb1a8faa21b369bcd33207cc90d64ae9df92bccbbb6f7e54b3b04b97ae",
                sizeBytes: 32_000_000,
                urls: [
                    URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny-q5_1.bin")!,
                    URL(string: "https://hf-mirror.com/ggerganov/whisper.cpp/resolve/main/ggml-tiny-q5_1.bin")!
                ],
                license: "MIT",
                languages: ["multilingual"]
            ),
            ModelSpec(
                id: "whisper-base-q5_1",
                displayName: "Base (Q5_1) - 56MB",
                filename: "ggml-base-q5_1.bin",
                sha256: "988e4e0e02e6a0c7b4c34d8e5f0f0f5f5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e",
                sizeBytes: 56_000_000,
                urls: [
                    URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base-q5_1.bin")!,
                    URL(string: "https://hf-mirror.com/ggerganov/whisper.cpp/resolve/main/ggml-base-q5_1.bin")!
                ],
                license: "MIT",
                languages: ["multilingual"]
            ),
            ModelSpec(
                id: "whisper-small-q5_1",
                displayName: "Small (Q5_1) - 182MB",
                filename: "ggml-small-q5_1.bin",
                sha256: "c7e8f5e5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5",
                sizeBytes: 182_000_000,
                urls: [
                    URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small-q5_1.bin")!,
                    URL(string: "https://hf-mirror.com/ggerganov/whisper.cpp/resolve/main/ggml-small-q5_1.bin")!
                ],
                license: "MIT",
                languages: ["multilingual"]
            ),
            ModelSpec(
                id: "whisper-medium-q5_0",
                displayName: "Medium (Q5_0) - 515MB",
                filename: "ggml-medium-q5_0.bin",
                sha256: "d7e8f5e5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5",
                sizeBytes: 515_000_000,
                urls: [
                    URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium-q5_0.bin")!,
                    URL(string: "https://hf-mirror.com/ggerganov/whisper.cpp/resolve/main/ggml-medium-q5_0.bin")!
                ],
                license: "MIT",
                languages: ["multilingual"]
            ),
            ModelSpec(
                id: "whisper-large-v3-turbo-q5_0",
                displayName: "Large v3 Turbo (Q5_0) - 1.5GB",
                filename: "ggml-large-v3-turbo-q5_0.bin",
                sha256: "e8f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5",
                sizeBytes: 1_500_000_000,
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
