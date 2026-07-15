import XCTest
@testable import MacTalk

final class PrivacyLoggingTests: XCTestCase {
    func test_sensitiveTranscriptClipboardAndErrorValuesNeverReachLoggingSink() {
        let transcript = "TRANSCRIPT_SENTINEL_7F1A"
        let clipboard = "CLIPBOARD_SENTINEL_9C2B"
        let error = NSError(domain: "test", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "engine failed after reading \(transcript) and \(clipboard)"
        ])
        let sink = RecordingLogSink()
        let logger = DebugLogger(sink: sink, diagnosticsEnabled: true)

        logger.log(.transcriptCompleted(characterCount: transcript.count))
        logger.log(.clipboardUpdated(characterCount: clipboard.count))
        logger.log(.error(description: error.localizedDescription))

        let output = sink.messages.joined(separator: "\n")
        XCTAssertFalse(output.contains(transcript))
        XCTAssertFalse(output.contains(clipboard))
        XCTAssertFalse(output.contains(error.localizedDescription))
    }

    func test_whisperBridgeDoesNotLogTranscriptContent() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let bridgeURL = testsDirectory
            .appendingPathComponent("../MacTalk/Whisper/WhisperBridge.mm")
            .standardizedFileURL
        let source = try String(contentsOf: bridgeURL, encoding: .utf8)

        let nativeTranscriptLogPattern = #"(?is)NSLog\s*\([^;]*\btranscript\b[^;]*(?:c_str|%s|%@|substr)"#
        let nativeTranscriptLogRegex = try NSRegularExpression(pattern: nativeTranscriptLogPattern)
        let sourceRange = NSRange(source.startIndex..<source.endIndex, in: source)
        XCTAssertNil(
            nativeTranscriptLogRegex.firstMatch(in: source, range: sourceRange),
            "WhisperBridge must not interpolate transcript content through NSLog"
        )
    }
}

private final class RecordingLogSink: DebugLogSink, @unchecked Sendable {
    private(set) var messages: [String] = []

    func write(_ message: String) {
        messages.append(message)
    }
}
