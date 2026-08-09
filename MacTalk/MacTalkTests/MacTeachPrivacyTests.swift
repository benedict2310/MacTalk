import Foundation
import XCTest

final class MacTeachPrivacyTests: XCTestCase {
    func test_productionLogStatementsDoNotInterpolateMacTeachTextOrAudio() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let relativePaths = [
            "../MacTalk/StatusBar/MacTeachCoordinator.swift",
            "../MacTalk/StatusBar/RecordingSessionCoordinator.swift",
            "../MacTalk/Whisper/NativeWhisperEngine.swift",
            "../MacTalk/Whisper/WhisperBridge.mm",
        ]
        let forbiddenFragments = [
            "wrongForm", "writtenForm", "spokenForm", "rawASRText",
            "cleanedText", "deliveredText", "audioSamples", "initialPrompt",
        ]

        for relativePath in relativePaths {
            let source = try String(
                contentsOf: testsDirectory.appendingPathComponent(relativePath).standardizedFileURL,
                encoding: .utf8
            )
            let loggingLines = source.split(separator: "\n").filter {
                $0.contains("DLOG(") || $0.contains("DebugLogger.shared.log") || $0.contains("NSLog(")
            }
            for line in loggingLines {
                for fragment in forbiddenFragments {
                    XCTAssertFalse(
                        line.contains(fragment),
                        "MacTeach content must not enter production logs: \(relativePath)"
                    )
                }
            }
        }
    }
}
