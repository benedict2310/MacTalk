import Foundation
import SQLite3
import XCTest
@testable import MacTalk

final class PersonalVocabularyStoreTests: XCTestCase {
    func test_savePersistsEntryChildrenAndRevisionAcrossReopen() async throws {
        let fixture = try VocabularyStoreFixture()
        defer { fixture.remove() }
        let entry = makeEntry(
            writtenForm: "MacTalk",
            spokenForm: "Mac Talk",
            wrongForms: ["Mac Talk", "Mactel"],
            language: "en",
            bundleIDs: ["com.apple.dt.Xcode", "com.apple.TextEdit"],
            priority: .important,
            applicationCount: 3,
            correctionCount: 2,
            lastAppliedAt: Date(timeIntervalSince1970: 90),
            directRecognitionCount: 4,
            lastRecognizedAt: Date(timeIntervalSince1970: 95)
        )

        do {
            let store = try PersonalVocabularyStore(databaseURL: fixture.databaseURL)
            let saved = try await store.save(entry)
            XCTAssertEqual(saved, entry)
            let snapshot = try await store.snapshot()
            XCTAssertEqual(snapshot.version, 1)
            XCTAssertEqual(snapshot.entries, [entry])
        }

        let reopened = try PersonalVocabularyStore(databaseURL: fixture.databaseURL)
        let persisted = try await reopened.entry(id: entry.id)
        let reopenedSnapshot = try await reopened.snapshot()
        XCTAssertEqual(persisted, entry)
        XCTAssertEqual(reopenedSnapshot.version, 1)
    }

    func test_saveRejectsValidationAndConflictsWithoutAdvancingRevision() async throws {
        let fixture = try VocabularyStoreFixture()
        defer { fixture.remove() }
        let store = try PersonalVocabularyStore(databaseURL: fixture.databaseURL)
        let existing = makeEntry(writtenForm: "MacTalk", wrongForms: ["Mac Talk"])
        _ = try await store.save(existing)

        do {
            _ = try await store.save(makeEntry(writtenForm: "", wrongForms: []))
            XCTFail("Expected validation error")
        } catch let error as PersonalVocabularyStoreError {
            guard case .validation = error else { return XCTFail("Unexpected \(error)") }
        }
        do {
            _ = try await store.save(makeEntry(writtenForm: "Other", wrongForms: ["mac talk"]))
            XCTFail("Expected conflict error")
        } catch let error as PersonalVocabularyStoreError {
            guard case .conflicts = error else { return XCTFail("Unexpected \(error)") }
        }

        let snapshot = try await store.snapshot()
        let entries = try await store.entries()
        XCTAssertEqual(snapshot.version, 1)
        XCTAssertEqual(entries, [existing])
    }

    func test_enableUsageAndDeleteMutationsProduceDeterministicSnapshots() async throws {
        let fixture = try VocabularyStoreFixture()
        defer { fixture.remove() }
        let store = try PersonalVocabularyStore(databaseURL: fixture.databaseURL)
        let id = UUID()
        _ = try await store.save(makeEntry(writtenForm: "API", id: id, wrongForms: ["a pie"], enabled: false))

        let enabled = try await store.setEnabled(true, id: id, modifiedAt: Date(timeIntervalSince1970: 200))
        XCTAssertTrue(enabled.isEnabled)
        let enabledSnapshot = try await store.snapshot()
        XCTAssertEqual(enabledSnapshot.version, 2)

        let appliedAt = Date(timeIntervalSince1970: 300)
        try await store.recordApplications(entryIDs: [id, id], appliedAt: appliedAt)
        let loadedApplied = try await store.entry(id: id)
        let applied = try XCTUnwrap(loadedApplied)
        XCTAssertEqual(applied.applicationCount, 1)
        XCTAssertEqual(applied.lastAppliedAt, appliedAt)
        let appliedSnapshot = try await store.snapshot()
        XCTAssertEqual(appliedSnapshot.version, 3)

        let recognizedAt = Date(timeIntervalSince1970: 400)
        try await store.recordDirectRecognitions(entryIDs: [id, id], recognizedAt: recognizedAt)
        let loadedRecognized = try await store.entry(id: id)
        let recognized = try XCTUnwrap(loadedRecognized)
        XCTAssertEqual(recognized.directRecognitionCount, 1)
        XCTAssertEqual(recognized.lastRecognizedAt, recognizedAt)
        let recognizedSnapshot = try await store.snapshot()
        XCTAssertEqual(recognizedSnapshot.version, 4)

        try await store.delete(id: id)
        let emptyEntries = try await store.entries()
        let deletedSnapshot = try await store.snapshot()
        XCTAssertTrue(emptyEntries.isEmpty)
        XCTAssertEqual(deletedSnapshot.version, 5)
    }

    func test_openingLegacyVocabularyDatabaseAddsRecognitionMetricsWithoutLosingEntries() async throws {
        let fixture = try VocabularyStoreFixture()
        defer { fixture.remove() }
        let id = UUID()
        try createLegacyVocabularyDatabase(at: fixture.databaseURL, entryID: id)

        let store = try PersonalVocabularyStore(databaseURL: fixture.databaseURL)
        let loadedMigrated = try await store.entry(id: id)
        let migrated = try XCTUnwrap(loadedMigrated)

        XCTAssertEqual(migrated.writtenForm, "MacTalk")
        XCTAssertEqual(migrated.applicationCount, 2)
        XCTAssertEqual(migrated.directRecognitionCount, 0)
        XCTAssertNil(migrated.lastRecognizedAt)
        XCTAssertEqual(migrated.schemaVersion, PersonalVocabularyEntry.currentSchemaVersion)

        let recognizedAt = Date(timeIntervalSince1970: 500)
        try await store.recordDirectRecognitions(entryIDs: [id], recognizedAt: recognizedAt)
        let loadedUpdated = try await store.entry(id: id)
        let updated = try XCTUnwrap(loadedUpdated)
        XCTAssertEqual(updated.directRecognitionCount, 1)
        XCTAssertEqual(updated.lastRecognizedAt, recognizedAt)
    }

    func test_databaseCanCoexistWithHistoryTablesWithoutOwningUserVersion() async throws {
        let fixture = try VocabularyStoreFixture()
        defer { fixture.remove() }
        let history = try HistoryStore(
            databaseURL: fixture.databaseURL,
            audioDirectoryURL: fixture.rootURL.appendingPathComponent("HistoryAudio", isDirectory: true)
        )
        let initialHistoryVersion = try await history.databaseSchemaVersion()
        XCTAssertEqual(initialHistoryVersion, HistoryStore.currentDatabaseSchemaVersion)

        let vocabulary = try PersonalVocabularyStore(databaseURL: fixture.databaseURL)
        _ = try await vocabulary.save(makeEntry(writtenForm: "MacTalk"))

        let finalHistoryVersion = try await history.databaseSchemaVersion()
        let writtenForms = try await vocabulary.entries().map(\.writtenForm)
        XCTAssertEqual(finalHistoryVersion, HistoryStore.currentDatabaseSchemaVersion)
        XCTAssertEqual(writtenForms, ["MacTalk"])
    }

    func test_deleteAllRemovesEveryEntryAndAdvancesSnapshotOnce() async throws {
        let fixture = try VocabularyStoreFixture()
        defer { fixture.remove() }
        let store = try PersonalVocabularyStore(databaseURL: fixture.databaseURL)
        _ = try await store.save(makeEntry(writtenForm: "MacTalk"))
        _ = try await store.save(makeEntry(writtenForm: "API"))

        let deletedCount = try await store.deleteAll()

        let snapshot = try await store.snapshot()
        XCTAssertEqual(deletedCount, 2)
        XCTAssertTrue(snapshot.entries.isEmpty)
        XCTAssertEqual(snapshot.version, 3)
    }

    func test_saveAllIsAtomicWhenAnyImportedEntryIsInvalid() async throws {
        let fixture = try VocabularyStoreFixture()
        defer { fixture.remove() }
        let store = try PersonalVocabularyStore(databaseURL: fixture.databaseURL)

        do {
            _ = try await store.saveAll([
                makeEntry(writtenForm: "MacTalk"),
                makeEntry(writtenForm: "  ")
            ])
            XCTFail("Expected validation failure")
        } catch let error as PersonalVocabularyStoreError {
            guard case .validation = error else { return XCTFail("Unexpected \(error)") }
        }

        let snapshot = try await store.snapshot()
        XCTAssertTrue(snapshot.entries.isEmpty)
        XCTAssertEqual(snapshot.version, 0)
    }
}

private func createLegacyVocabularyDatabase(at url: URL, entryID: UUID) throws {
    var database: OpaquePointer?
    guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
        throw PersonalVocabularyStoreError.cannotCreateStorage
    }
    defer { sqlite3_close(database) }
    let sql = """
        CREATE TABLE vocabulary_entries (
            id TEXT PRIMARY KEY NOT NULL, written_form TEXT NOT NULL, spoken_form TEXT,
            language TEXT, priority TEXT NOT NULL, hint_enabled INTEGER NOT NULL,
            replacement_enabled INTEGER NOT NULL, enabled INTEGER NOT NULL, source TEXT NOT NULL,
            source_history_id TEXT, created_at REAL NOT NULL, updated_at REAL NOT NULL,
            application_count INTEGER NOT NULL, correction_count INTEGER NOT NULL,
            last_applied_at REAL, schema_version INTEGER NOT NULL
        );
        INSERT INTO vocabulary_entries VALUES (
            '\(entryID.uuidString.lowercased())', 'MacTalk', NULL, 'en', 'important',
            1, 1, 1, 'manual', NULL, 10, 20, 2, 1, 30, 1
        );
        """
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
        throw PersonalVocabularyStoreError.databaseFailure(code: sqlite3_errcode(database))
    }
}

private struct VocabularyStoreFixture {
    let rootURL: URL
    let databaseURL: URL

    init() throws {
        self.rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mactalk-vocabulary-\(UUID().uuidString)", isDirectory: true)
        self.databaseURL = self.rootURL.appendingPathComponent("MacTeach.sqlite")
        try FileManager.default.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: self.rootURL)
    }
}
