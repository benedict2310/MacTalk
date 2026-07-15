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

        logger.log(.transcriptCompleted(text: transcript))
        logger.log(.clipboardUpdated(text: clipboard))
        logger.log(.error(description: error.localizedDescription))

        let output = sink.messages.joined(separator: "\n")
        XCTAssertFalse(output.contains(transcript))
        XCTAssertFalse(output.contains(clipboard))
        XCTAssertFalse(output.contains(error.localizedDescription))
    }
}

private final class RecordingLogSink: DebugLogSink, @unchecked Sendable {
    private(set) var messages: [String] = []

    func write(_ message: String) {
        messages.append(message)
    }
}
