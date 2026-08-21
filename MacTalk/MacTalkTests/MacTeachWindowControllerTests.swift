import XCTest
import Combine
@testable import MacTalk

@MainActor
final class MacTeachWindowControllerTests: XCTestCase {
    private var cancellables: Set<AnyCancellable> = []

    func test_historyAndVocabularyWindowsHaveStableAccessibleConfiguration() throws {
        let fixture = try makeFixture()
        let history = HistoryWindowController(coordinator: fixture.coordinator)
        let vocabulary = PersonalVocabularyWindowController(coordinator: fixture.coordinator)

        XCTAssertEqual(history.window?.title, "MacTalk History")
        XCTAssertEqual(vocabulary.window?.title, "Personal Vocabulary")
        XCTAssertTrue(history.window?.styleMask.contains(.resizable) == true)
        XCTAssertTrue(vocabulary.window?.styleMask.contains(.resizable) == true)
        XCTAssertEqual(history.window?.accessibilityLabel(), "MacTalk transcription history")
        XCTAssertEqual(vocabulary.window?.accessibilityLabel(), "MacTalk personal vocabulary")
    }

    func test_correctLastSelectsNewestHistoryRecord() async throws {
        let fixture = try makeFixture()
        let older = try await insertHistory(in: fixture.history, completedAt: Date(timeIntervalSince1970: 1))
        let newer = try await insertHistory(in: fixture.history, completedAt: Date(timeIntervalSince1970: 2))
        let controller = HistoryWindowController(coordinator: fixture.coordinator)

        await controller.selectLatestForCorrection()

        XCTAssertNotEqual(controller.viewModel.selectedRecordID, older)
        XCTAssertEqual(controller.viewModel.selectedRecordID, newer)
        XCTAssertTrue(controller.viewModel.isTeaching)
        XCTAssertEqual(controller.viewModel.heardForm, "Talk")
    }

    func test_openHistoryReloadsWhenRecordingPersistenceCompletes() async throws {
        let fixture = try makeFixture()
        let controller = HistoryWindowController(coordinator: fixture.coordinator)
        await controller.viewModel.load()
        XCTAssertTrue(controller.viewModel.records.isEmpty)
        let reloaded = expectation(description: "History view reloads")
        var didFulfill = false
        controller.viewModel.$records
            .dropFirst()
            .sink { records in
                if records.count == 1, !didFulfill {
                    didFulfill = true
                    reloaded.fulfill()
                }
            }
            .store(in: &cancellables)
        _ = try await insertHistory(in: fixture.history, completedAt: Date())

        NotificationCenter.default.post(name: .macTalkHistoryDidChange, object: fixture.coordinator)

        await fulfillment(of: [reloaded], timeout: 1)
        XCTAssertEqual(controller.viewModel.records.count, 1)
    }

    func test_openVocabularyReloadsWhenMacTeachMeasurementsChange() async throws {
        let fixture = try makeFixture()
        let viewModel = PersonalVocabularyViewModel(coordinator: fixture.coordinator)
        await viewModel.load()
        XCTAssertTrue(viewModel.entries.isEmpty)
        let reloaded = expectation(description: "Personal Vocabulary view reloads")
        var didFulfill = false
        viewModel.$entries
            .dropFirst()
            .sink { entries in
                if entries.count == 1, !didFulfill {
                    didFulfill = true
                    reloaded.fulfill()
                }
            }
            .store(in: &cancellables)

        try await fixture.coordinator.saveVocabularyEntry(PersonalVocabularyEntry(writtenForm: "MacTalk"))

        await fulfillment(of: [reloaded], timeout: 1)
        XCTAssertEqual(viewModel.entries.map(\.writtenForm), ["MacTalk"])
    }

    func test_keyboardVocabularySelectionLoadsTheSelectedEntryIntoEditor() async throws {
        let fixture = try makeFixture()
        let entry = PersonalVocabularyEntry(
            writtenForm: "API",
            spokenForm: "A P I",
            wrongForms: [PersonalVocabularyWrongForm(text: "a pie")],
            language: "en",
            priority: .important
        )
        try await fixture.coordinator.saveVocabularyEntry(entry)
        let controller = PersonalVocabularyWindowController(coordinator: fixture.coordinator)
        await controller.viewModel.load()

        controller.viewModel.selectEntry(id: entry.id)

        XCTAssertEqual(controller.viewModel.writtenForm, "API")
        XCTAssertEqual(controller.viewModel.wrongForms, "a pie")
        XCTAssertEqual(controller.viewModel.spokenForm, "A P I")
        XCTAssertEqual(controller.viewModel.priority, .important)
    }

    func test_vocabularyEffectivenessSummaryDistinguishesRecognitionFromRepair() throws {
        let fixture = try makeFixture()
        let controller = PersonalVocabularyWindowController(coordinator: fixture.coordinator)
        let measured = PersonalVocabularyEntry(
            writtenForm: "MacTalk",
            applicationCount: 2,
            correctionCount: 1,
            directRecognitionCount: 5
        )
        let unobserved = PersonalVocabularyEntry(writtenForm: "Codex")

        XCTAssertEqual(
            controller.viewModel.effectivenessSummary(for: measured),
            "Recognized directly 5 times · Repaired 2 times · Taught once"
        )
        XCTAssertEqual(
            controller.viewModel.effectivenessSummary(for: unobserved),
            "No later uses observed yet"
        )
    }

    private struct Fixture {
        let root: URL
        let history: HistoryStore
        let coordinator: MacTeachCoordinator
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacTeachWindowTests-\(UUID().uuidString)", isDirectory: true)
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
            coordinator: MacTeachCoordinator(historyStore: history, vocabularyStore: vocabulary)
        )
    }

    private func insertHistory(in store: HistoryStore, completedAt: Date) async throws -> UUID {
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
            sourceBundleID: nil,
            sourceDisplayName: nil,
            rawASRText: "mac talk",
            cleanedText: "Mac Talk.",
            deliveredText: "Mac Talk.",
            durationMilliseconds: 500,
            inferenceMilliseconds: 50,
            insertionSucceeded: true,
            outcome: .completed
        ))
        return id
    }
}
