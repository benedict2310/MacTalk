import Foundation
import XCTest
@testable import MacTalk

final class HistoryRetentionTests: XCTestCase {
    func test_pruneAppliesAgeAndCountBoundsAndKeepsNewestRecords() async throws {
        let fixture = try HistoryStoreFixture()
        defer { fixture.remove() }
        let store = try HistoryStore(
            databaseURL: fixture.databaseURL,
            audioDirectoryURL: fixture.audioDirectoryURL
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for dayOffset in [40, 20, 10, 2, 1] {
            _ = try await store.recordTerminalResult(
                makeTerminalResult(
                    completedAt: now.addingTimeInterval(TimeInterval(-dayOffset * 86_400)),
                    text: "Transcript day \(dayOffset)"
                )
            )
        }

        let report = try await store.prune(
            retention: HistoryRetentionConfiguration(policy: .thirtyDays, maximumRecordCount: 2),
            now: now
        )

        XCTAssertEqual(report.deletedRecordCount, 3)
        let remaining = try await store.search(HistorySearchQuery())
        XCTAssertEqual(remaining.map(\.currentText), ["Transcript day 1", "Transcript day 2"])
    }

    func test_offPolicyDoesNotDeleteExistingHistoryWithoutConfirmation() async throws {
        let fixture = try HistoryStoreFixture()
        defer { fixture.remove() }
        let store = try HistoryStore(
            databaseURL: fixture.databaseURL,
            audioDirectoryURL: fixture.audioDirectoryURL
        )
        _ = try await store.recordTerminalResult(makeTerminalResult(text: "Keep me"))

        let report = try await store.prune(
            retention: HistoryRetentionConfiguration(policy: .off, maximumRecordCount: 500),
            now: Date(timeIntervalSince1970: 1_900_000_000)
        )

        XCTAssertEqual(report.deletedRecordCount, 0)
        let count = try await store.count()
        XCTAssertEqual(count, 1)
    }

    func test_searchIsCaseAndDiacriticInsensitiveAndSupportsFilters() async throws {
        let fixture = try HistoryStoreFixture()
        defer { fixture.remove() }
        let store = try HistoryStore(
            databaseURL: fixture.databaseURL,
            audioDirectoryURL: fixture.audioDirectoryURL
        )
        _ = try await store.recordTerminalResult(
            makeTerminalResult(text: "Über Café", provider: "whisper", language: "de")
        )
        _ = try await store.recordTerminalResult(
            makeTerminalResult(text: "Cafe notes", provider: "parakeet", language: "en")
        )

        let folded = try await store.search(HistorySearchQuery(text: "UBER CAFE"))
        let filtered = try await store.search(
            HistorySearchQuery(text: "cafe", provider: "parakeet", language: "en")
        )

        XCTAssertEqual(folded.map(\.currentText), ["Über Café"])
        XCTAssertEqual(filtered.map(\.currentText), ["Cafe notes"])
    }

    func test_attachAndDeleteRecordRemovesOpaqueAudioFile() async throws {
        let fixture = try HistoryStoreFixture()
        defer { fixture.remove() }
        let store = try HistoryStore(
            databaseURL: fixture.databaseURL,
            audioDirectoryURL: fixture.audioDirectoryURL
        )
        let outcome = try await store.recordTerminalResult(makeTerminalResult(text: "Audio record"))
        guard case let .inserted(record) = outcome else {
            return XCTFail("Expected insert")
        }
        let sourceURL = fixture.rootURL.appendingPathComponent("capture.caf")
        try Data([0, 1, 2, 3]).write(to: sourceURL)

        let attached = try await store.attachAudioFile(
            from: sourceURL,
            to: record.id,
            fileExtension: "caf"
        )
        let storedAudioURL = try await store.audioURL(for: record.id)
        let retainedURL = try XCTUnwrap(storedAudioURL)

        XCTAssertTrue(attached.hasRetainedAudio)
        XCTAssertEqual(retainedURL.lastPathComponent, "\(record.id.uuidString.lowercased()).caf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: retainedURL.path))

        let deleted = try await store.delete(recordID: record.id)
        XCTAssertTrue(deleted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: retainedURL.path))
    }

    func test_reconcileAudioRemovesOrphansAndClearsMissingReferences() async throws {
        let fixture = try HistoryStoreFixture()
        defer { fixture.remove() }
        let store = try HistoryStore(
            databaseURL: fixture.databaseURL,
            audioDirectoryURL: fixture.audioDirectoryURL
        )
        let outcome = try await store.recordTerminalResult(makeTerminalResult(text: "Audio record"))
        guard case let .inserted(record) = outcome else {
            return XCTFail("Expected insert")
        }
        let sourceURL = fixture.rootURL.appendingPathComponent("capture.caf")
        try Data([0, 1, 2, 3]).write(to: sourceURL)
        _ = try await store.attachAudioFile(from: sourceURL, to: record.id, fileExtension: "caf")
        let storedAudioURL = try await store.audioURL(for: record.id)
        let retainedURL = try XCTUnwrap(storedAudioURL)
        try FileManager.default.removeItem(at: retainedURL)
        let orphanURL = fixture.audioDirectoryURL.appendingPathComponent("\(UUID().uuidString).caf")
        try Data([4, 5, 6]).write(to: orphanURL)

        let report = try await store.reconcileAudioFiles()
        let storedRecord = try await store.record(id: record.id)
        let updated = try XCTUnwrap(storedRecord)

        XCTAssertEqual(report.removedOrphanCount, 1)
        XCTAssertEqual(report.clearedMissingReferenceCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanURL.path))
        XCTAssertFalse(updated.hasRetainedAudio)
    }

    func test_audioRetentionPrunesRecordingWithoutDeletingTextRecord() async throws {
        let fixture = try HistoryStoreFixture()
        defer { fixture.remove() }
        let store = try HistoryStore(
            databaseURL: fixture.databaseURL,
            audioDirectoryURL: fixture.audioDirectoryURL
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let outcome = try await store.recordTerminalResult(makeTerminalResult(text: "Keep the text"))
        guard case let .inserted(record) = outcome else { return XCTFail("Expected insert") }
        let sourceURL = fixture.rootURL.appendingPathComponent("capture.caf")
        try Data([0, 1, 2, 3]).write(to: sourceURL)
        _ = try await store.attachAudioFile(
            from: sourceURL,
            to: record.id,
            fileExtension: "caf",
            createdAt: now.addingTimeInterval(-8 * 86_400)
        )

        let removed = try await store.pruneAudio(olderThan: now.addingTimeInterval(-7 * 86_400))

        let persisted = try await store.record(id: record.id)
        XCTAssertEqual(removed, 1)
        XCTAssertEqual(persisted?.currentText, "Keep the text")
        XCTAssertFalse(persisted?.hasRetainedAudio ?? true)
    }

    private func makeTerminalResult(
        completedAt: Date = Date(timeIntervalSince1970: 1_800_000_000),
        text: String,
        provider: String = "whisper",
        language: String = "en"
    ) -> HistoryTerminalResult {
        HistoryTerminalResult(
            sessionID: UUID(),
            createdAt: completedAt.addingTimeInterval(-1),
            completedAt: completedAt,
            provider: provider,
            modelID: "model",
            modelRevision: "revision",
            requestedLanguage: language,
            detectedLanguage: language,
            captureMode: "microphone",
            sourceBundleID: "com.example.app",
            sourceDisplayName: "Example",
            rawASRText: text,
            cleanedText: text,
            deliveredText: text,
            durationMilliseconds: 1_000,
            inferenceMilliseconds: 100,
            insertionSucceeded: nil,
            outcome: .completed
        )
    }
}
