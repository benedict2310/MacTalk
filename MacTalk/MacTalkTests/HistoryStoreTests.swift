import Foundation
import XCTest
@testable import MacTalk

final class HistoryStoreTests: XCTestCase {
    func test_recordTerminalResultPersistsPipelineProvenance() async throws {
        let fixture = try HistoryStoreFixture()
        defer { fixture.remove() }
        let store = try HistoryStore(
            databaseURL: fixture.databaseURL,
            audioDirectoryURL: fixture.audioDirectoryURL
        )
        let terminal = makeTerminalResult()

        let outcome = try await store.recordTerminalResult(terminal)

        guard case let .inserted(record) = outcome else {
            return XCTFail("Expected an inserted History record")
        }
        XCTAssertEqual(record.sessionID, terminal.sessionID)
        XCTAssertEqual(record.rawASRText, " raw engine text ")
        XCTAssertEqual(record.cleanedText, "Raw engine text")
        XCTAssertEqual(record.deliveredText, "MacTalk is ready.")
        XCTAssertNil(record.correctedText)
        XCTAssertEqual(record.currentText, "MacTalk is ready.")
        XCTAssertEqual(record.provider, "whisper")
        XCTAssertEqual(record.modelID, "large-v3-turbo-q5")
        XCTAssertEqual(record.modelRevision, "model-revision")
        XCTAssertEqual(record.requestedLanguage, "en")
        XCTAssertEqual(record.detectedLanguage, "en")
        XCTAssertEqual(record.captureMode, "microphone")
        XCTAssertEqual(record.sourceBundleID, "com.apple.dt.Xcode")
        XCTAssertEqual(record.sourceDisplayName, "Xcode")
        XCTAssertEqual(record.durationMilliseconds, 2_500)
        XCTAssertEqual(record.inferenceMilliseconds, 420)
        XCTAssertEqual(record.insertionSucceeded, true)
        XCTAssertFalse(record.hasRetainedAudio)
        XCTAssertEqual(record.schemaVersion, HistoryRecord.currentSchemaVersion)

        let persisted = try await store.record(id: record.id)
        XCTAssertEqual(persisted, record)
    }

    func test_duplicateTerminalCallbacksConvergeOnOneSessionRecord() async throws {
        let fixture = try HistoryStoreFixture()
        defer { fixture.remove() }
        let store = try HistoryStore(
            databaseURL: fixture.databaseURL,
            audioDirectoryURL: fixture.audioDirectoryURL
        )
        let terminal = makeTerminalResult()

        let first = try await store.recordTerminalResult(terminal)
        let second = try await store.recordTerminalResult(terminal)

        guard case let .inserted(inserted) = first else {
            return XCTFail("Expected first callback to insert")
        }
        guard case let .alreadyRecorded(existing) = second else {
            return XCTFail("Expected duplicate callback to be idempotent")
        }
        XCTAssertEqual(existing.id, inserted.id)
        let count = try await store.count()
        XCTAssertEqual(count, 1)
    }

    func test_cancelledEmptyAndDisabledResultsAreNotPersisted() async throws {
        let fixture = try HistoryStoreFixture()
        defer { fixture.remove() }
        let store = try HistoryStore(
            databaseURL: fixture.databaseURL,
            audioDirectoryURL: fixture.audioDirectoryURL
        )

        let cancelled = try await store.recordTerminalResult(
            makeTerminalResult(outcome: .cancelled)
        )
        let empty = try await store.recordTerminalResult(
            makeTerminalResult(deliveredText: "  \n ")
        )
        let disabled = try await store.recordTerminalResult(
            makeTerminalResult(),
            historyEnabled: false
        )

        XCTAssertEqual(cancelled, .skipped(.cancelled))
        XCTAssertEqual(empty, .skipped(.emptyTranscript))
        XCTAssertEqual(disabled, .skipped(.historyDisabled))
        let count = try await store.count()
        XCTAssertEqual(count, 0)
    }

    func test_storeReopensAndCorrectionUpdatesOnlyCurrentText() async throws {
        let fixture = try HistoryStoreFixture()
        defer { fixture.remove() }
        let recordID: UUID
        do {
            let store = try HistoryStore(
                databaseURL: fixture.databaseURL,
                audioDirectoryURL: fixture.audioDirectoryURL
            )
            let outcome = try await store.recordTerminalResult(makeTerminalResult())
            guard case let .inserted(record) = outcome else {
                return XCTFail("Expected insert")
            }
            recordID = record.id
            let updated = try await store.setCorrectedText("MacTeach is ready.", for: recordID)
            XCTAssertEqual(updated.correctedText, "MacTeach is ready.")
            XCTAssertEqual(updated.currentText, "MacTeach is ready.")
            XCTAssertEqual(updated.rawASRText, " raw engine text ")
            XCTAssertEqual(updated.cleanedText, "Raw engine text")
            XCTAssertEqual(updated.deliveredText, "MacTalk is ready.")
        }

        let reopened = try HistoryStore(
            databaseURL: fixture.databaseURL,
            audioDirectoryURL: fixture.audioDirectoryURL
        )
        let reopenedRecord = try await reopened.record(id: recordID)
        let persisted = try XCTUnwrap(reopenedRecord)
        XCTAssertEqual(persisted.correctedText, "MacTeach is ready.")
        let schemaVersion = try await reopened.databaseSchemaVersion()
        XCTAssertEqual(schemaVersion, HistoryStore.currentDatabaseSchemaVersion)
    }

    func test_historyExportProvidesPlainTextAndStructuredJSONWithoutAudioContent() async throws {
        let fixture = try HistoryStoreFixture()
        defer { fixture.remove() }
        let store = try HistoryStore(
            databaseURL: fixture.databaseURL,
            audioDirectoryURL: fixture.audioDirectoryURL
        )
        let outcome = try await store.recordTerminalResult(makeTerminalResult())
        guard case let .inserted(record) = outcome else { return XCTFail("Expected insert") }

        let text = HistoryExportCodec.plainText(record)
        let data = try HistoryExportCodec.json(record)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(text, "MacTalk is ready.")
        XCTAssertEqual(json["currentText"] as? String, "MacTalk is ready.")
        XCTAssertEqual(json["rawASRText"] as? String, " raw engine text ")
        XCTAssertNil(json["audio"])
    }

    private func makeTerminalResult(
        sessionID: UUID = UUID(),
        completedAt: Date = Date(timeIntervalSince1970: 1_800_000_000),
        deliveredText: String = "MacTalk is ready.",
        outcome: HistoryTerminalOutcome = .completed
    ) -> HistoryTerminalResult {
        HistoryTerminalResult(
            sessionID: sessionID,
            createdAt: completedAt.addingTimeInterval(-2.5),
            completedAt: completedAt,
            provider: "whisper",
            modelID: "large-v3-turbo-q5",
            modelRevision: "model-revision",
            requestedLanguage: "en",
            detectedLanguage: "en",
            captureMode: "microphone",
            sourceBundleID: "com.apple.dt.Xcode",
            sourceDisplayName: "Xcode",
            rawASRText: " raw engine text ",
            cleanedText: "Raw engine text",
            deliveredText: deliveredText,
            durationMilliseconds: 2_500,
            inferenceMilliseconds: 420,
            insertionSucceeded: true,
            outcome: outcome
        )
    }
}

struct HistoryStoreFixture {
    let rootURL: URL
    let databaseURL: URL
    let audioDirectoryURL: URL

    init() throws {
        self.rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mactalk-history-\(UUID().uuidString)", isDirectory: true)
        self.databaseURL = self.rootURL.appendingPathComponent("MacTeach.sqlite")
        self.audioDirectoryURL = self.rootURL.appendingPathComponent("HistoryAudio", isDirectory: true)
        try FileManager.default.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: self.rootURL)
    }
}
