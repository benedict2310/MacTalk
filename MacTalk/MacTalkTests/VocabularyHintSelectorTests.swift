import XCTest
@testable import MacTalk

final class VocabularyHintSelectorTests: XCTestCase {
    func test_filtersAndRanksDeterministically() {
        let importantID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        let appID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let snapshot = PersonalVocabularySnapshot(entries: [
            makeEntry(writtenForm: "Global", id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!),
            makeEntry(writtenForm: "German", id: UUID(), language: "de"),
            makeEntry(writtenForm: "Replacement", id: UUID(), hintEnabled: false),
            makeEntry(writtenForm: "App term", id: appID, bundleIDs: ["com.apple.dt.Xcode"]),
            makeEntry(writtenForm: "Important", id: importantID, priority: .important),
        ])

        let result = VocabularyHintSelector().select(
            from: snapshot,
            context: VocabularyMatchContext(language: "en-US", applicationBundleID: "com.apple.dt.Xcode"),
            budget: VocabularyHintBudget(maximumCount: 10, maximumTokenCost: 100)
        )

        XCTAssertEqual(result.hints.map(\.entryID), [appID, importantID, snapshot.entries[0].id])
    }

    func test_neverExceedsCountOrTokenBudgetAndSkipsOversizedTerms() {
        let snapshot = PersonalVocabularySnapshot(entries: [
            makeEntry(writtenForm: "Too expensive", priority: .important),
            makeEntry(writtenForm: "One", priority: .important),
            makeEntry(writtenForm: "Two"),
            makeEntry(writtenForm: "Three"),
        ])
        let selector = VocabularyHintSelector(tokenCost: { $0 == "Too expensive" ? 20 : 2 })

        let result = selector.select(
            from: snapshot,
            context: VocabularyMatchContext(),
            budget: VocabularyHintBudget(maximumCount: 2, maximumTokenCost: 4)
        )

        XCTAssertEqual(result.hints.count, 2)
        XCTAssertEqual(result.totalTokenCost, 4)
        XCTAssertFalse(result.hints.contains { $0.writtenForm == "Too expensive" })
    }

    func test_recentSuccessCorrectionFrequencyAndCompactCostBreakTies() {
        let old = Date(timeIntervalSince1970: 10)
        let recent = Date(timeIntervalSince1970: 20)
        let snapshot = PersonalVocabularySnapshot(entries: [
            makeEntry(writtenForm: "Long costly", updatedAt: old, correctionCount: 2),
            makeEntry(writtenForm: "Short", updatedAt: old, correctionCount: 2),
            makeEntry(writtenForm: "Corrected", updatedAt: old, correctionCount: 3),
            makeEntry(writtenForm: "Applied", updatedAt: old, correctionCount: 1, lastAppliedAt: recent),
        ])
        let selector = VocabularyHintSelector(tokenCost: { $0.split(separator: " ").count })

        let result = selector.select(from: snapshot, context: VocabularyMatchContext(), budget: .unlimited)

        XCTAssertEqual(result.hints.map(\.writtenForm), ["Applied", "Corrected", "Short", "Long costly"])
    }
}
