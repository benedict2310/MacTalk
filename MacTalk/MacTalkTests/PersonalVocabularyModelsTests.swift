import XCTest
@testable import MacTalk

final class PersonalVocabularyModelsTests: XCTestCase {
    func test_validatorRejectsEmptyControlCharactersAndSelfReplacingWrongForms() {
        let issues = PersonalVocabularyValidator.validate(
            makeEntry(writtenForm: "  ", spokenForm: "bad\tform", wrongForms: ["valid"])
        ) + PersonalVocabularyValidator.validate(
            makeEntry(writtenForm: "MacTalk", wrongForms: ["MACtalk"])
        )

        XCTAssertTrue(issues.contains { $0.code == .emptyWrittenForm })
        XCTAssertTrue(issues.contains { $0.code == .controlCharacter })
        XCTAssertTrue(issues.contains { $0.code == .selfReplacingWrongForm })
    }

    func test_validatorRejectsSurroundingWhitespaceThatWouldCorruptReplacementSpacing() {
        let issues = PersonalVocabularyValidator.validate(
            makeEntry(writtenForm: " MacTalk ", wrongForms: [" Mac Talk"])
        )

        XCTAssertTrue(issues.contains { $0.code == .surroundingWhitespace && $0.field == .writtenForm })
        XCTAssertTrue(issues.contains { issue in
            guard issue.code == .surroundingWhitespace else { return false }
            if case .wrongForm = issue.field { return true }
            return false
        })
    }

    func test_validatorDetectsDuplicateIdentityAndOverlappingWrongFormConflict() {
        let existing = makeEntry(
            writtenForm: "MacTalk",
            wrongForms: ["Mac Talk"],
            language: "en",
            bundleIDs: ["com.apple.dt.Xcode"]
        )
        let duplicate = makeEntry(
            writtenForm: " mactalk ",
            wrongForms: [],
            language: "EN",
            bundleIDs: ["com.apple.dt.Xcode"]
        )
        let conflicting = makeEntry(
            writtenForm: "Mactel",
            wrongForms: ["mac talk"],
            language: nil,
            bundleIDs: []
        )

        XCTAssertEqual(
            PersonalVocabularyValidator.conflicts(for: duplicate, against: [existing]).map(\.kind),
            [.duplicateEntry]
        )
        XCTAssertEqual(
            PersonalVocabularyValidator.conflicts(for: conflicting, against: [existing]).map(\.kind),
            [.wrongFormCollision]
        )
    }

    func test_snapshotIsAnImmutableDeterministicallyOrderedValue() {
        var entries = [
            makeEntry(writtenForm: "Zulu", id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!),
            makeEntry(writtenForm: "Alpha", id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!),
        ]
        let snapshot = PersonalVocabularySnapshot(entries: entries, version: 7, capturedAt: Date(timeIntervalSince1970: 10))
        entries.removeAll()

        XCTAssertEqual(snapshot.entries.map(\.writtenForm), ["Alpha", "Zulu"])
        XCTAssertEqual(snapshot.version, 7)
    }
}

func makeEntry(
    writtenForm: String,
    id: UUID = UUID(),
    spokenForm: String? = nil,
    wrongForms: [String] = [],
    language: String? = nil,
    bundleIDs: Set<String> = [],
    priority: PersonalVocabularyPriority = .normal,
    hintEnabled: Bool = true,
    replacementEnabled: Bool = true,
    enabled: Bool = true,
    updatedAt: Date = Date(timeIntervalSince1970: 100),
    applicationCount: Int = 0,
    correctionCount: Int = 0,
    lastAppliedAt: Date? = nil,
    directRecognitionCount: Int = 0,
    lastRecognizedAt: Date? = nil
) -> PersonalVocabularyEntry {
    PersonalVocabularyEntry(
        id: id,
        writtenForm: writtenForm,
        spokenForm: spokenForm,
        wrongForms: wrongForms.map { PersonalVocabularyWrongForm(text: $0) },
        language: language,
        applicationBundleIDs: bundleIDs,
        priority: priority,
        recognitionHintEnabled: hintEnabled,
        replacementEnabled: replacementEnabled,
        isEnabled: enabled,
        source: .manual,
        sourceHistoryRecordID: nil,
        createdAt: Date(timeIntervalSince1970: 1),
        updatedAt: updatedAt,
        applicationCount: applicationCount,
        correctionCount: correctionCount,
        lastAppliedAt: lastAppliedAt,
        directRecognitionCount: directRecognitionCount,
        lastRecognizedAt: lastRecognizedAt
    )
}
