import XCTest
@testable import MacTalk

@MainActor
final class MacTeachCoordinatorTests: XCTestCase {
    func test_sessionSnapshotDrivesHintsReplacementAndHistoryProvenance() async throws {
        let fixture = try makeFixture()
        let entry = PersonalVocabularyEntry(
            writtenForm: "MacTalk",
            wrongForms: [PersonalVocabularyWrongForm(text: "Mac Talk")],
            priority: .important
        )
        try await fixture.vocabulary.save(entry)
        let settings = makeSettings()
        let target = ApplicationIdentity(
            processIdentifier: 42,
            bundleIdentifier: "com.apple.TextEdit",
            displayName: "TextEdit"
        )

        let session = await fixture.coordinator.captureSession(settings: settings, target: target)
        XCTAssertEqual(session.requestContext.language, "en")
        XCTAssertEqual(session.requestContext.vocabularyHints.map(\.writtenForm), ["MacTalk"])

        let terminal = TerminalTranscription(
            sessionID: UUID(),
            provider: .whisper,
            rawASRText: "mac talk",
            cleanedText: "Mac Talk.",
            requestedLanguage: "en",
            durationMilliseconds: 1_250
        )
        let delivered = fixture.coordinator.deliver(terminal, session: session)
        XCTAssertEqual(delivered.text, "MacTalk.")
        XCTAssertEqual(delivered.replacementEdits.count, 1)

        let persistence = try await fixture.coordinator.persist(
            delivered,
            session: session,
            selection: EngineSelection(
                provider: .whisper,
                modelID: "whisper-large-v3-turbo-q5_0",
                revision: "revision"
            ),
            insertionSucceeded: true
        )
        XCTAssertEqual(persistence.diagnosticOutcome, .inserted)
        let records = try await fixture.history.search(HistorySearchQuery())
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].rawASRText, "mac talk")
        XCTAssertEqual(records[0].cleanedText, "Mac Talk.")
        XCTAssertEqual(records[0].deliveredText, "MacTalk.")
        XCTAssertEqual(records[0].sourceBundleID, "com.apple.TextEdit")
    }

    func test_persistPublishesHistoryChangeOnlyAfterDurableInsert() async throws {
        let fixture = try makeFixture()
        let settings = makeSettings()
        let session = await fixture.coordinator.captureSession(settings: settings, target: nil)
        let terminal = TerminalTranscription(
            sessionID: UUID(),
            provider: .whisper,
            rawASRText: "hello",
            cleanedText: "Hello."
        )
        let delivered = fixture.coordinator.deliver(terminal, session: session)
        let changed = expectation(forNotification: .macTalkHistoryDidChange, object: fixture.coordinator)

        let outcome = try await fixture.coordinator.persist(
            delivered,
            session: session,
            selection: EngineSelection(provider: .whisper, modelID: "model", revision: "revision"),
            insertionSucceeded: nil
        )

        await fulfillment(of: [changed], timeout: 1)
        XCTAssertEqual(outcome.diagnosticOutcome, .inserted)
        let records = try await fixture.history.search(HistorySearchQuery())
        XCTAssertEqual(records.count, 1)
    }

    func test_teachCreatesVocabularyAndRecomputesCorrectedHistoryFromCleanedText() async throws {
        let fixture = try makeFixture()
        let recordID = UUID()
        _ = try await fixture.history.recordTerminalResult(
            HistoryTerminalResult(
                recordID: recordID,
                sessionID: UUID(),
                createdAt: Date(timeIntervalSince1970: 1),
                completedAt: Date(timeIntervalSince1970: 2),
                provider: "whisper",
                modelID: "model",
                modelRevision: "revision",
                requestedLanguage: "en",
                detectedLanguage: nil,
                captureMode: "micOnly",
                sourceBundleID: nil,
                sourceDisplayName: nil,
                rawASRText: "mac talk is useful",
                cleanedText: "Mac Talk is useful.",
                deliveredText: "Mac Talk is useful.",
                durationMilliseconds: 500,
                inferenceMilliseconds: 50,
                insertionSucceeded: true,
                outcome: .completed
            ),
            historyEnabled: true
        )

        let taught = try await fixture.coordinator.teach(
            historyRecordID: recordID,
            wrongForm: "Mac Talk",
            writtenForm: "MacTalk",
            spokenForm: nil,
            language: "en",
            applicationBundleIDs: []
        )

        XCTAssertEqual(taught.source, .correction)
        let vocabularyCount = try await fixture.vocabulary.entries().count
        let correctedText = try await fixture.history.record(id: recordID)?.correctedText
        let correctionEvents = try await fixture.history.correctionEvents(historyRecordID: recordID)

        XCTAssertEqual(vocabularyCount, 1)
        XCTAssertEqual(correctedText, "MacTalk is useful.")
        XCTAssertEqual(correctionEvents.count, 1)
        XCTAssertEqual(correctionEvents.first?.wrongText, "Mac Talk")
        XCTAssertEqual(correctionEvents.first?.intendedText, "MacTalk")
        XCTAssertEqual(correctionEvents.first?.vocabularyEntryID, taught.id)
    }

    func test_teachHonorsRecognitionReplacementAndPriorityControls() async throws {
        let fixture = try makeFixture()
        let recordID = try await insertHistory(in: fixture.history)

        let taught = try await fixture.coordinator.teach(
            historyRecordID: recordID,
            wrongForm: "a pie",
            writtenForm: "API",
            spokenForm: "A P I",
            language: "en",
            applicationBundleIDs: ["com.apple.dt.Xcode"],
            recognitionHintEnabled: false,
            replacementEnabled: true,
            priority: .important
        )

        XCTAssertFalse(taught.recognitionHintEnabled)
        XCTAssertTrue(taught.replacementEnabled)
        XCTAssertEqual(taught.priority, .important)
        XCTAssertEqual(taught.applicationBundleIDs, ["com.apple.dt.Xcode"])
    }

    func test_maintenanceAppliesTextAndAudioRetentionIndependently() async throws {
        let fixture = try makeFixture()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let oldID = UUID()
        _ = try await fixture.history.recordTerminalResult(HistoryTerminalResult(
            recordID: oldID,
            sessionID: UUID(),
            createdAt: now.addingTimeInterval(-41 * 86_400),
            completedAt: now.addingTimeInterval(-40 * 86_400),
            provider: "whisper",
            modelID: "model",
            modelRevision: "revision",
            requestedLanguage: "en",
            detectedLanguage: nil,
            captureMode: "micOnly",
            sourceBundleID: nil,
            sourceDisplayName: nil,
            rawASRText: "old",
            cleanedText: "Old.",
            deliveredText: "Old.",
            durationMilliseconds: 500,
            inferenceMilliseconds: 50,
            insertionSucceeded: true,
            outcome: .completed
        ))
        let currentID = try await insertHistory(in: fixture.history, completedAt: now)
        let sourceURL = fixture.root.appendingPathComponent("capture.caf")
        try Data([0, 1, 2, 3]).write(to: sourceURL)
        _ = try await fixture.history.attachAudioFile(
            from: sourceURL,
            to: currentID,
            fileExtension: "caf",
            createdAt: now.addingTimeInterval(-8 * 86_400)
        )
        var settings = makeSettings()
        settings.macTeach.textRetentionDays = 30
        settings.macTeach.audioRetentionDays = 7
        let coordinator = MacTeachCoordinator(
            historyStore: fixture.history,
            vocabularyStore: fixture.vocabulary,
            clock: { now }
        )

        try await coordinator.performMaintenance(settings: settings)

        let expired = try await fixture.history.record(id: oldID)
        let current = try await fixture.history.record(id: currentID)
        XCTAssertNil(expired)
        XCTAssertNotNil(current)
        XCTAssertFalse(current?.hasRetainedAudio ?? true)
    }

    private struct Fixture {
        let root: URL
        let history: HistoryStore
        let vocabulary: PersonalVocabularyStore
        let coordinator: MacTeachCoordinator
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacTeachCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("MacTeach.sqlite")
        let history = try HistoryStore(
            databaseURL: database,
            audioDirectoryURL: root.appendingPathComponent("HistoryAudio", isDirectory: true)
        )
        let vocabulary = try PersonalVocabularyStore(databaseURL: database)
        return Fixture(
            root: root,
            history: history,
            vocabulary: vocabulary,
            coordinator: MacTeachCoordinator(historyStore: history, vocabularyStore: vocabulary)
        )
    }

    private func makeSettings() -> SettingsSnapshot {
        SettingsSnapshot(
            provider: .whisper,
            whisperModelID: "whisper-large-v3-turbo-q5_0",
            language: "en",
            captureMode: .micOnly,
            showNotifications: true,
            autoPaste: false
        )
    }

    private func insertHistory(
        in store: HistoryStore,
        completedAt: Date = Date(timeIntervalSince1970: 2)
    ) async throws -> UUID {
        let id = UUID()
        _ = try await store.recordTerminalResult(HistoryTerminalResult(
            recordID: id,
            sessionID: UUID(),
            createdAt: completedAt.addingTimeInterval(-1),
            completedAt: completedAt,
            provider: "whisper",
            modelID: "model",
            modelRevision: "revision",
            requestedLanguage: "en",
            detectedLanguage: nil,
            captureMode: "micOnly",
            sourceBundleID: "com.apple.dt.Xcode",
            sourceDisplayName: "Xcode",
            rawASRText: "a pie",
            cleanedText: "A pie.",
            deliveredText: "A pie.",
            durationMilliseconds: 500,
            inferenceMilliseconds: 50,
            insertionSucceeded: true,
            outcome: .completed
        ))
        return id
    }
}
