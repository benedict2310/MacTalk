import Foundation

struct VocabularyHintBudget: Equatable, Sendable {
    static let unlimited = VocabularyHintBudget(maximumCount: .max, maximumTokenCost: .max)

    let maximumCount: Int
    let maximumTokenCost: Int

    init(maximumCount: Int, maximumTokenCost: Int) {
        self.maximumCount = max(0, maximumCount)
        self.maximumTokenCost = max(0, maximumTokenCost)
    }
}
struct VocabularyHint: Equatable, Sendable {
    let entryID: UUID
    let writtenForm: String
    let spokenForm: String?
    let priority: PersonalVocabularyPriority
    let tokenCost: Int
}

struct VocabularyHintSelection: Equatable, Sendable {
    let snapshotVersion: UInt64
    let hints: [VocabularyHint]
    let totalTokenCost: Int
    let eligibleEntryCount: Int
}

struct VocabularyHintSelector: Sendable {
    typealias TokenCost = @Sendable (String) -> Int

    private let tokenCost: TokenCost

    init(tokenCost: @escaping TokenCost = VocabularyHintSelector.estimatedTokenCost) {
        self.tokenCost = tokenCost
    }

    func select(
        from snapshot: PersonalVocabularySnapshot,
        context: VocabularyMatchContext,
        budget: VocabularyHintBudget
    ) -> VocabularyHintSelection {
        let eligible = snapshot.entries
            .filter { VocabularyNormalization.applies($0, to: context) && $0.recognitionHintEnabled }
            .map { RankedEntry(entry: $0, tokenCost: max(1, tokenCost($0.writtenForm))) }
            .sorted { precedes($0, $1) }

        var hints: [VocabularyHint] = []
        var totalCost = 0
        for ranked in eligible {
            guard hints.count < budget.maximumCount else { break }
            guard ranked.tokenCost <= budget.maximumTokenCost - totalCost else { continue }
            hints.append(VocabularyHint(
                entryID: ranked.entry.id,
                writtenForm: ranked.entry.writtenForm,
                spokenForm: ranked.entry.spokenForm,
                priority: ranked.entry.priority,
                tokenCost: ranked.tokenCost
            ))
            totalCost += ranked.tokenCost
        }

        return VocabularyHintSelection(
            snapshotVersion: snapshot.version,
            hints: hints,
            totalTokenCost: totalCost,
            eligibleEntryCount: eligible.count
        )
    }

    private func precedes(_ lhs: RankedEntry, _ rhs: RankedEntry) -> Bool {
        let lhsLanguageSpecific = lhs.entry.language == nil ? 0 : 1
        let rhsLanguageSpecific = rhs.entry.language == nil ? 0 : 1
        if lhsLanguageSpecific != rhsLanguageSpecific { return lhsLanguageSpecific > rhsLanguageSpecific }

        let lhsApplicationSpecific = lhs.entry.applicationBundleIDs.isEmpty ? 0 : 1
        let rhsApplicationSpecific = rhs.entry.applicationBundleIDs.isEmpty ? 0 : 1
        if lhsApplicationSpecific != rhsApplicationSpecific { return lhsApplicationSpecific > rhsApplicationSpecific }

        if lhs.entry.priority != rhs.entry.priority { return lhs.entry.priority == .important }
        switch (lhs.entry.lastAppliedAt, rhs.entry.lastAppliedAt) {
        case let (lhsDate?, rhsDate?) where lhsDate != rhsDate:
            return lhsDate > rhsDate
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            break
        }
        if lhs.entry.correctionCount != rhs.entry.correctionCount {
            return lhs.entry.correctionCount > rhs.entry.correctionCount
        }
        if lhs.entry.updatedAt != rhs.entry.updatedAt { return lhs.entry.updatedAt > rhs.entry.updatedAt }
        if lhs.tokenCost != rhs.tokenCost { return lhs.tokenCost < rhs.tokenCost }
        return lhs.entry.id.uuidString < rhs.entry.id.uuidString
    }

    private static func estimatedTokenCost(_ term: String) -> Int {
        // Conservative tokenizer-independent fallback. Provider adapters can inject
        // the loaded model's exact tokenizer when building a request.
        max(1, (term.utf8.count + 3) / 4)
    }
}

private extension VocabularyHintSelector {
    struct RankedEntry {
        let entry: PersonalVocabularyEntry
        let tokenCost: Int
    }
}
