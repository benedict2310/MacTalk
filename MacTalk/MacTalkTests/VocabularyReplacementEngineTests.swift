import XCTest
@testable import MacTalk

final class VocabularyReplacementEngineTests: XCTestCase {
    private let engine = VocabularyReplacementEngine()

    func test_replacesWholeWordsAndPhrasesWithoutTouchingSubstrings() {
        let snapshot = PersonalVocabularySnapshot(entries: [
            makeEntry(writtenForm: "cat", wrongForms: ["kat"]),
            makeEntry(writtenForm: "MacTalk", wrongForms: ["Mac Talk"]),
        ])

        let result = engine.apply(to: "A kat, Mac Talk and katapult.", snapshot: snapshot)

        XCTAssertEqual(result.text, "A cat, MacTalk and katapult.")
        XCTAssertEqual(result.edits.map(\.matchedText), ["kat", "Mac Talk"])
        XCTAssertEqual(result.edits.map(\.replacementText), ["cat", "MacTalk"])
    }

    func test_longestMatchWinsAndReplacementsDoNotCascade() {
        let snapshot = PersonalVocabularySnapshot(entries: [
            makeEntry(writtenForm: "New York City", wrongForms: ["new york"]),
            makeEntry(writtenForm: "Yorkshire", wrongForms: ["York"]),
            makeEntry(writtenForm: "NYC", wrongForms: ["new york city"]),
        ])

        let result = engine.apply(to: "new york city and new york", snapshot: snapshot)

        XCTAssertEqual(result.text, "NYC and New York City")
        XCTAssertFalse(result.text.contains("Yorkshire"))
    }

    func test_preservesPunctuationWhitespaceAndConfiguredCapitalizationForUnicode() {
        let snapshot = PersonalVocabularySnapshot(entries: [
            makeEntry(writtenForm: "Élodie", wrongForms: ["élody"]),
            makeEntry(writtenForm: "API", wrongForms: ["a pie"]),
        ])

        let result = engine.apply(to: "“ÉLODY”  said a pie!", snapshot: snapshot)

        XCTAssertEqual(result.text, "“Élodie”  said API!")
        XCTAssertEqual(result.edits.first?.sourceUTF16Range, NSRange(location: 1, length: 5))
    }

    func test_filtersByLanguageApplicationAndEnabledFlags() {
        let snapshot = PersonalVocabularySnapshot(entries: [
            makeEntry(writtenForm: "global", wrongForms: ["heard"]),
            makeEntry(writtenForm: "english", wrongForms: ["heard"], language: "en"),
            makeEntry(writtenForm: "xcode", wrongForms: ["term"], bundleIDs: ["com.apple.dt.Xcode"]),
            makeEntry(writtenForm: "disabled", wrongForms: ["off"], enabled: false),
            makeEntry(writtenForm: "hint only", wrongForms: ["hint"], replacementEnabled: false),
        ])

        let result = engine.apply(
            to: "heard term off hint",
            snapshot: snapshot,
            context: VocabularyMatchContext(language: "en-US", applicationBundleID: "com.apple.dt.Xcode")
        )

        XCTAssertEqual(result.text, "english xcode off hint")
    }

    func test_reapplyingToImmutableSourceIsIdempotentAndEditsIdentifyEntry() {
        let id = UUID()
        let snapshot = PersonalVocabularySnapshot(entries: [makeEntry(writtenForm: "MacTalk", id: id, wrongForms: ["Mac Talk"])])

        let first = engine.apply(to: "Mac Talk", snapshot: snapshot)
        let second = engine.apply(to: "Mac Talk", snapshot: snapshot)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.edits.single?.entryID, id)
        XCTAssertEqual(first.edits.single?.sourceCharacterRange, 0..<8)
    }
}
private extension Collection {
    var single: Element? { count == 1 ? first : nil }
}
