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

    func test_whisperBridgeGuardRejectsGenericVariableArguments() {
        let reconstructedLeak = #"void log(const char *segment_text) { NSLog(@"Segment: %s", segment_text); }"#

        XCTAssertEqual(staticNSLogViolations(in: reconstructedLeak).count, 1)
    }

    func test_whisperBridgeDoesNotLogTranscriptContent() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let bridgeURL = testsDirectory
            .appendingPathComponent("../MacTalk/Whisper/WhisperBridge.mm")
            .standardizedFileURL
        let source = try String(contentsOf: bridgeURL, encoding: .utf8)

        let violations = staticNSLogViolations(in: source)
        XCTAssertTrue(
            violations.isEmpty,
            "WhisperBridge NSLog calls must use a static format string without variable arguments: \(violations)"
        )
    }
}

private func staticNSLogViolations(in source: String) -> [String] {
    let staticFormatPattern = #"^\s*@"(?:\\.|[^"\\])*"\s*$"#
    let staticFormatRegex = try! NSRegularExpression(pattern: staticFormatPattern)
    var violations: [String] = []
    var index = source.startIndex
    var state: LexicalState = .code
    var escaped = false

    while index < source.endIndex {
        let character = source[index]
        switch state {
        case .code:
            if character == "/", let next = source.index(index, offsetBy: 1, limitedBy: source.index(before: source.endIndex)), source[next] == "/" {
                state = .lineComment
                index = source.index(index, offsetBy: 2)
            } else if character == "/", let next = source.index(index, offsetBy: 1, limitedBy: source.index(before: source.endIndex)), source[next] == "*" {
                state = .blockComment
                index = source.index(index, offsetBy: 2)
            } else if character == "\"" {
                state = .string
                escaped = false
                index = source.index(after: index)
            } else if character == "'" {
                state = .character
                escaped = false
                index = source.index(after: index)
            } else if source[index...].hasPrefix("NSLog"),
                      (index == source.startIndex || !isIdentifierCharacter(source[source.index(before: index)])) {
                let nameEnd = source.index(index, offsetBy: 5)
                if nameEnd == source.endIndex || !isIdentifierCharacter(source[nameEnd]) {
                    var cursor = nameEnd
                    while cursor < source.endIndex, source[cursor].isWhitespace {
                        cursor = source.index(after: cursor)
                    }
                    if cursor < source.endIndex, source[cursor] == "(" {
                        if let close = matchingParenthesis(in: source, openingAt: cursor) {
                            let argumentStart = source.index(after: cursor)
                            let arguments = String(source[argumentStart..<close])
                            let range = NSRange(arguments.startIndex..<arguments.endIndex, in: arguments)
                            if staticFormatRegex.firstMatch(in: arguments, range: range) == nil {
                                violations.append(String(source[index...close]))
                            }
                            index = source.index(after: close)
                        } else {
                            violations.append(String(source[index...]))
                            break
                        }
                    } else {
                        index = nameEnd
                    }
                } else {
                    index = nameEnd
                }
            } else {
                index = source.index(after: index)
            }
        case .string, .character:
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if (state == .string && character == "\"") || (state == .character && character == "'") {
                state = .code
            }
            index = source.index(after: index)
        case .lineComment:
            if character == "\n" {
                state = .code
            }
            index = source.index(after: index)
        case .blockComment:
            if character == "*", let next = source.index(index, offsetBy: 1, limitedBy: source.index(before: source.endIndex)), source[next] == "/" {
                state = .code
                index = source.index(index, offsetBy: 2)
            } else {
                index = source.index(after: index)
            }
        }
    }

    return violations
}

private func matchingParenthesis(in source: String, openingAt opening: String.Index) -> String.Index? {
    var depth = 0
    var index = opening
    var state: LexicalState = .code
    var escaped = false

    while index < source.endIndex {
        let character = source[index]
        switch state {
        case .code:
            if character == "/", let next = source.index(index, offsetBy: 1, limitedBy: source.index(before: source.endIndex)), source[next] == "/" {
                state = .lineComment
                index = source.index(index, offsetBy: 2)
            } else if character == "/", let next = source.index(index, offsetBy: 1, limitedBy: source.index(before: source.endIndex)), source[next] == "*" {
                state = .blockComment
                index = source.index(index, offsetBy: 2)
            } else if character == "\"" {
                state = .string
                escaped = false
                index = source.index(after: index)
            } else if character == "'" {
                state = .character
                escaped = false
                index = source.index(after: index)
            } else if character == "(" {
                depth += 1
                index = source.index(after: index)
            } else if character == ")" {
                depth -= 1
                if depth == 0 {
                    return index
                }
                index = source.index(after: index)
            } else {
                index = source.index(after: index)
            }
        case .string, .character:
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if (state == .string && character == "\"") || (state == .character && character == "'") {
                state = .code
            }
            index = source.index(after: index)
        case .lineComment:
            if character == "\n" {
                state = .code
            }
            index = source.index(after: index)
        case .blockComment:
            if character == "*", let next = source.index(index, offsetBy: 1, limitedBy: source.index(before: source.endIndex)), source[next] == "/" {
                state = .code
                index = source.index(index, offsetBy: 2)
            } else {
                index = source.index(after: index)
            }
        }
    }

    return nil
}

private func isIdentifierCharacter(_ character: Character) -> Bool {
    character == "_" || character.isLetter || character.isNumber
}

private enum LexicalState {
    case code
    case string
    case character
    case lineComment
    case blockComment
}

private final class RecordingLogSink: DebugLogSink, @unchecked Sendable {
    private(set) var messages: [String] = []

    func write(_ message: String) {
        messages.append(message)
    }
}
