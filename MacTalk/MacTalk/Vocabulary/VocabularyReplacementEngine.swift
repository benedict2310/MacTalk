import Foundation

struct VocabularyReplacementEdit: Equatable, Sendable {
    let entryID: UUID
    let wrongFormID: UUID
    let matchedText: String
    let replacementText: String
    let sourceUTF16Range: NSRange
    let sourceCharacterRange: Range<Int>
}
struct VocabularyReplacementResult: Equatable, Sendable {
    let text: String
    let edits: [VocabularyReplacementEdit]
}

struct VocabularyReplacementEngine: Sendable {
    func apply(
        to source: String,
        snapshot: PersonalVocabularySnapshot,
        context: VocabularyMatchContext = VocabularyMatchContext()
    ) -> VocabularyReplacementResult {
        let candidates = makeCandidates(snapshot: snapshot, context: context)
        guard !source.isEmpty, !candidates.isEmpty else {
            return VocabularyReplacementResult(text: source, edits: [])
        }

        var output = ""
        output.reserveCapacity(source.utf8.count)
        var edits: [VocabularyReplacementEdit] = []
        var cursor = source.startIndex
        var characterOffset = 0

        while cursor < source.endIndex {
            if let match = bestMatch(in: source, at: cursor, candidates: candidates) {
                let matchedText = String(source[match.range])
                output.append(match.entry.writtenForm)
                let utf16Range = NSRange(match.range, in: source)
                let characterLength = source[match.range].count
                edits.append(VocabularyReplacementEdit(
                    entryID: match.entry.id,
                    wrongFormID: match.wrongForm.id,
                    matchedText: matchedText,
                    replacementText: match.entry.writtenForm,
                    sourceUTF16Range: utf16Range,
                    sourceCharacterRange: characterOffset..<(characterOffset + characterLength)
                ))
                cursor = match.range.upperBound
                characterOffset += characterLength
            } else {
                let next = source.index(after: cursor)
                output.append(contentsOf: source[cursor..<next])
                cursor = next
                characterOffset += 1
            }
        }

        return VocabularyReplacementResult(text: output, edits: edits)
    }

    private func makeCandidates(
        snapshot: PersonalVocabularySnapshot,
        context: VocabularyMatchContext
    ) -> [Candidate] {
        snapshot.entries
            .filter { VocabularyNormalization.applies($0, to: context) && $0.replacementEnabled }
            .flatMap { entry in
                entry.wrongForms.compactMap { wrongForm -> Candidate? in
                    guard !wrongForm.text.isEmpty else { return nil }
                    return Candidate(entry: entry, wrongForm: wrongForm)
                }
            }
            .sorted { candidatePrecedes($0, $1, context: context) }
    }

    private func bestMatch(
        in source: String,
        at cursor: String.Index,
        candidates: [Candidate]
    ) -> Match? {
        for candidate in candidates {
            guard let range = source.range(
                of: candidate.wrongForm.text,
                options: [.anchored, .caseInsensitive],
                range: cursor..<source.endIndex,
                locale: VocabularyNormalization.locale
            ), range.lowerBound == cursor, hasWholePhraseBoundaries(source: source, range: range, wrongForm: candidate.wrongForm.text) else {
                continue
            }
            return Match(entry: candidate.entry, wrongForm: candidate.wrongForm, range: range)
        }
        return nil
    }

    private func candidatePrecedes(_ lhs: Candidate, _ rhs: Candidate, context: VocabularyMatchContext) -> Bool {
        let lhsLength = lhs.wrongForm.text.count
        let rhsLength = rhs.wrongForm.text.count
        if lhsLength != rhsLength { return lhsLength > rhsLength }

        let lhsLanguageSpecific = lhs.entry.language == nil ? 0 : 1
        let rhsLanguageSpecific = rhs.entry.language == nil ? 0 : 1
        if lhsLanguageSpecific != rhsLanguageSpecific { return lhsLanguageSpecific > rhsLanguageSpecific }

        let lhsApplicationSpecific = lhs.entry.applicationBundleIDs.isEmpty ? 0 : 1
        let rhsApplicationSpecific = rhs.entry.applicationBundleIDs.isEmpty ? 0 : 1
        if lhsApplicationSpecific != rhsApplicationSpecific { return lhsApplicationSpecific > rhsApplicationSpecific }

        if lhs.entry.priority != rhs.entry.priority { return lhs.entry.priority == .important }
        if lhs.entry.updatedAt != rhs.entry.updatedAt { return lhs.entry.updatedAt > rhs.entry.updatedAt }
        if lhs.entry.id != rhs.entry.id { return lhs.entry.id.uuidString < rhs.entry.id.uuidString }
        return lhs.wrongForm.id.uuidString < rhs.wrongForm.id.uuidString
    }

    private func hasWholePhraseBoundaries(source: String, range: Range<String.Index>, wrongForm: String) -> Bool {
        guard let first = wrongForm.first, let last = wrongForm.last else { return false }
        if isWordConstituent(first), range.lowerBound > source.startIndex {
            let previous = source[source.index(before: range.lowerBound)]
            if isWordConstituent(previous) { return false }
        }
        if isWordConstituent(last), range.upperBound < source.endIndex {
            let following = source[range.upperBound]
            if isWordConstituent(following) { return false }
        }
        return true
    }

    private func isWordConstituent(_ character: Character) -> Bool {
        let wordScalars = CharacterSet.alphanumerics
            .union(.nonBaseCharacters)
            .union(CharacterSet(charactersIn: "_"))
        return character.unicodeScalars.contains { wordScalars.contains($0) }
    }
}

private extension VocabularyReplacementEngine {
    struct Candidate {
        let entry: PersonalVocabularyEntry
        let wrongForm: PersonalVocabularyWrongForm
    }

    struct Match {
        let entry: PersonalVocabularyEntry
        let wrongForm: PersonalVocabularyWrongForm
        let range: Range<String.Index>
    }
}
