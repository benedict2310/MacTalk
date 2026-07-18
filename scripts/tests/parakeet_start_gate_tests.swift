import Foundation

@main
struct ParakeetStartGateTests {
    static func main() {
        precondition(ASRProvider.whisper.usesIncrementalChunkProcessing)
        precondition(!ASRProvider.parakeet.usesIncrementalChunkProcessing)
        precondition(ASRProvider.allCases.map(\.rawValue).sorted() == ["parakeet", "whisper"])
        precondition(ASRProvider.whisper.displayName == "Whisper")
        precondition(ASRProvider.parakeet.displayName == "Parakeet")
        print("provider processing policy tests passed")
    }
}
