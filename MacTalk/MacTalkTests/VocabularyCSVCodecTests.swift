import XCTest
@testable import MacTalk

final class VocabularyCSVCodecTests: XCTestCase {
    private let codec = VocabularyCSVCodec()

    func test_roundTripUsesVersionedUTF8CSVAndPreservesQuotedUnicodeFields() throws {
        let entry = makeEntry(
            writtenForm: "Élodie, Inc.",
            spokenForm: "ay-low-dee",
            wrongForms: ["Elody", "Élodie \"company\""],
            language: "fr",
            bundleIDs: ["com.example.Editor"],
            priority: .important,
            hintEnabled: true,
            replacementEnabled: true
        )

        let data = try codec.export([entry])
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.hasPrefix("# MacTalk Personal Vocabulary CSV v1\nwritten_form,"))

        let preview = try codec.previewImport(data: data)
        XCTAssertTrue(preview.issues.isEmpty)
        XCTAssertEqual(preview.entries.count, 1)
        XCTAssertEqual(preview.entries.first?.writtenForm, entry.writtenForm)
        XCTAssertEqual(Set(preview.entries.first?.wrongForms.map(\.text) ?? []), Set(entry.wrongForms.map(\.text)))
        XCTAssertEqual(preview.entries.first?.applicationBundleIDs, entry.applicationBundleIDs)
    }

    func test_previewReportsInvalidRowsDuplicatesAndExistingConflictsWithoutMutating() throws {
        let csv = """
        # MacTalk Personal Vocabulary CSV v1
        written_form,wrong_form,spoken_form,language,bundle_id,priority,recognition_hint,replacement
        MacTalk,Mac Talk,,en,,important,true,true
        MacTalk,Mac-Talk,,en,,important,true,true
        Other,Mac Talk,,en,,normal,true,true
        ,missing,,,,normal,true,true
        """
        let existing = makeEntry(writtenForm: "Existing", wrongForms: ["Mac Talk"], language: "en")

        let preview = try codec.previewImport(data: Data(csv.utf8), existingEntries: [existing])

        XCTAssertEqual(preview.entries.count, 2)
        XCTAssertEqual(preview.duplicateRowCount, 1)
        XCTAssertEqual(preview.conflictCount, 2)
        XCTAssertTrue(preview.issues.contains { $0.row == 6 && $0.validationCode == .emptyWrittenForm })
    }

    func test_rejectsUnknownVersionAndMalformedBoolean() throws {
        let unknown = "# MacTalk Personal Vocabulary CSV v2\nwritten_form\nMacTalk\n"
        XCTAssertThrowsError(try codec.previewImport(data: Data(unknown.utf8))) { error in
            XCTAssertEqual(error as? VocabularyCSVError, .unsupportedVersion(2))
        }

        let malformed = "# MacTalk Personal Vocabulary CSV v1\nwritten_form,recognition_hint\nMacTalk,sometimes\n"
        let preview = try codec.previewImport(data: Data(malformed.utf8))
        XCTAssertTrue(preview.issues.contains { $0.row == 3 && $0.message.contains("boolean") })
    }

    func test_duplicateRowsWithDifferentMetadataRequireResolution() throws {
        let csv = """
        # MacTalk Personal Vocabulary CSV v1
        written_form,wrong_form,spoken_form,language,bundle_id,priority,recognition_hint,replacement
        MacTalk,Mac Talk,Mac Talk,en,,normal,true,true
        MacTalk,Mac-Talk,Mac Tock,en,,important,false,true
        """

        let preview = try codec.previewImport(data: Data(csv.utf8))

        XCTAssertTrue(preview.issues.contains { $0.row == 4 && $0.message.contains("inconsistent metadata") })
    }
}
