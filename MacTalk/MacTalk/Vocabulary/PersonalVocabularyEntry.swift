import Foundation

enum PersonalVocabularyPriority: String, Codable, CaseIterable, Sendable {
    case normal
    case important
}

enum PersonalVocabularySource: String, Codable, CaseIterable, Sendable {
    case manual
    case correction
    case suggestion
    case imported
}

struct PersonalVocabularyWrongForm: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: UUID
    let text: String

    init(id: UUID = UUID(), text: String) {
        self.id = id
        self.text = text
    }
}

struct PersonalVocabularyEntry: Identifiable, Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2

    let id: UUID
    let writtenForm: String
    let spokenForm: String?
    let wrongForms: [PersonalVocabularyWrongForm]
    let language: String?
    let applicationBundleIDs: Set<String>
    let priority: PersonalVocabularyPriority
    let recognitionHintEnabled: Bool
    let replacementEnabled: Bool
    let isEnabled: Bool
    let source: PersonalVocabularySource
    let sourceHistoryRecordID: UUID?
    let createdAt: Date
    let updatedAt: Date
    let applicationCount: Int
    let correctionCount: Int
    let lastAppliedAt: Date?
    let directRecognitionCount: Int
    let lastRecognizedAt: Date?
    let schemaVersion: Int

    init(
        id: UUID = UUID(),
        writtenForm: String,
        spokenForm: String? = nil,
        wrongForms: [PersonalVocabularyWrongForm] = [],
        language: String? = nil,
        applicationBundleIDs: Set<String> = [],
        priority: PersonalVocabularyPriority = .normal,
        recognitionHintEnabled: Bool = true,
        replacementEnabled: Bool = true,
        isEnabled: Bool = true,
        source: PersonalVocabularySource = .manual,
        sourceHistoryRecordID: UUID? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        applicationCount: Int = 0,
        correctionCount: Int = 0,
        lastAppliedAt: Date? = nil,
        directRecognitionCount: Int = 0,
        lastRecognizedAt: Date? = nil,
        schemaVersion: Int = PersonalVocabularyEntry.currentSchemaVersion
    ) {
        self.id = id
        self.writtenForm = writtenForm
        self.spokenForm = spokenForm
        self.wrongForms = wrongForms
        self.language = language
        self.applicationBundleIDs = applicationBundleIDs
        self.priority = priority
        self.recognitionHintEnabled = recognitionHintEnabled
        self.replacementEnabled = replacementEnabled
        self.isEnabled = isEnabled
        self.source = source
        self.sourceHistoryRecordID = sourceHistoryRecordID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.applicationCount = applicationCount
        self.correctionCount = correctionCount
        self.lastAppliedAt = lastAppliedAt
        self.directRecognitionCount = directRecognitionCount
        self.lastRecognizedAt = lastRecognizedAt
        self.schemaVersion = schemaVersion
    }
}

struct PersonalVocabularySnapshot: Equatable, Sendable {
    let entries: [PersonalVocabularyEntry]
    let version: UInt64
    let capturedAt: Date

    init(
        entries: [PersonalVocabularyEntry],
        version: UInt64 = 0,
        capturedAt: Date = Date()
    ) {
        self.entries = entries.sorted { $0.id.uuidString < $1.id.uuidString }
        self.version = version
        self.capturedAt = capturedAt
    }
}

struct VocabularyMatchContext: Equatable, Sendable {
    let language: String?
    let applicationBundleID: String?

    init(language: String? = nil, applicationBundleID: String? = nil) {
        self.language = language
        self.applicationBundleID = applicationBundleID
    }
}

enum PersonalVocabularyValidationCode: String, Equatable, Sendable {
    case emptyWrittenForm
    case valueTooLong
    case controlCharacter
    case surroundingWhitespace
    case emptyWrongForm
    case selfReplacingWrongForm
    case invalidBundleIdentifier
    case invalidCount
}

struct PersonalVocabularyValidationIssue: Equatable, Sendable {
    enum Field: Equatable, Sendable {
        case writtenForm
        case spokenForm
        case wrongForm(UUID)
        case applicationBundleID(String)
        case applicationCount
        case correctionCount
        case directRecognitionCount
    }

    let code: PersonalVocabularyValidationCode
    let field: Field
    let message: String
}

enum PersonalVocabularyConflictKind: Equatable, Sendable {
    case duplicateEntry
    case wrongFormCollision
}

struct PersonalVocabularyConflict: Equatable, Sendable {
    let kind: PersonalVocabularyConflictKind
    let candidateEntryID: UUID
    let existingEntryID: UUID
    let wrongForm: String?
}

enum PersonalVocabularyValidator {
    static let maximumWrittenFormLength = 256
    static let maximumWrongFormLength = 256
    static let maximumSpokenFormLength = 512

    static func validate(_ entry: PersonalVocabularyEntry) -> [PersonalVocabularyValidationIssue] {
        var issues: [PersonalVocabularyValidationIssue] = []
        let written = entry.writtenForm.trimmingCharacters(in: .whitespacesAndNewlines)
        if written.isEmpty {
            issues.append(.init(code: .emptyWrittenForm, field: .writtenForm, message: "Written form is required."))
        }
        if !entry.writtenForm.isEmpty, written != entry.writtenForm {
            issues.append(.init(
                code: .surroundingWhitespace,
                field: .writtenForm,
                message: "Written form cannot start or end with whitespace."
            ))
        }
        validateText(entry.writtenForm, maximumLength: maximumWrittenFormLength, field: .writtenForm, issues: &issues)
        if let spokenForm = entry.spokenForm {
            validateText(spokenForm, maximumLength: maximumSpokenFormLength, field: .spokenForm, issues: &issues)
        }

        let normalizedWritten = VocabularyNormalization.text(entry.writtenForm)
        for wrongForm in entry.wrongForms {
            let trimmed = wrongForm.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                issues.append(.init(code: .emptyWrongForm, field: .wrongForm(wrongForm.id), message: "Wrong form cannot be empty."))
            }
            if !wrongForm.text.isEmpty, trimmed != wrongForm.text {
                issues.append(.init(
                    code: .surroundingWhitespace,
                    field: .wrongForm(wrongForm.id),
                    message: "Wrong form cannot start or end with whitespace."
                ))
            }
            validateText(wrongForm.text, maximumLength: maximumWrongFormLength, field: .wrongForm(wrongForm.id), issues: &issues)
            if !trimmed.isEmpty && VocabularyNormalization.text(wrongForm.text) == normalizedWritten {
                issues.append(.init(
                    code: .selfReplacingWrongForm,
                    field: .wrongForm(wrongForm.id),
                    message: "Wrong form must differ from the written form."
                ))
            }
        }

        for bundleID in entry.applicationBundleIDs where !isValidBundleIdentifier(bundleID) {
            issues.append(.init(
                code: .invalidBundleIdentifier,
                field: .applicationBundleID(bundleID),
                message: "Application bundle identifier is invalid."
            ))
        }
        if entry.applicationCount < 0 {
            issues.append(.init(code: .invalidCount, field: .applicationCount, message: "Application count cannot be negative."))
        }
        if entry.correctionCount < 0 {
            issues.append(.init(code: .invalidCount, field: .correctionCount, message: "Correction count cannot be negative."))
        }
        if entry.directRecognitionCount < 0 {
            issues.append(.init(
                code: .invalidCount,
                field: .directRecognitionCount,
                message: "Direct recognition count cannot be negative."
            ))
        }
        return issues
    }

    static func conflicts(
        for candidate: PersonalVocabularyEntry,
        against existingEntries: [PersonalVocabularyEntry]
    ) -> [PersonalVocabularyConflict] {
        var conflicts: [PersonalVocabularyConflict] = []
        let candidateWritten = VocabularyNormalization.text(candidate.writtenForm)
        let candidateWrongForms = Set(candidate.wrongForms.map { VocabularyNormalization.text($0.text) }.filter { !$0.isEmpty })

        for existing in existingEntries where existing.id != candidate.id {
            if candidateWritten == VocabularyNormalization.text(existing.writtenForm),
               VocabularyNormalization.language(candidate.language) == VocabularyNormalization.language(existing.language),
               candidate.applicationBundleIDs == existing.applicationBundleIDs {
                conflicts.append(.init(
                    kind: .duplicateEntry,
                    candidateEntryID: candidate.id,
                    existingEntryID: existing.id,
                    wrongForm: nil
                ))
            }

            guard scopesOverlap(candidate, existing), languagesOverlap(candidate.language, existing.language) else {
                continue
            }
            let existingWrongForms = Set(existing.wrongForms.map { VocabularyNormalization.text($0.text) })
            for wrongForm in candidateWrongForms.intersection(existingWrongForms).sorted()
                where candidateWritten != VocabularyNormalization.text(existing.writtenForm) {
                conflicts.append(.init(
                    kind: .wrongFormCollision,
                    candidateEntryID: candidate.id,
                    existingEntryID: existing.id,
                    wrongForm: wrongForm
                ))
            }
        }

        return conflicts.sorted {
            if $0.kind != $1.kind { return String(describing: $0.kind) < String(describing: $1.kind) }
            if $0.existingEntryID != $1.existingEntryID { return $0.existingEntryID.uuidString < $1.existingEntryID.uuidString }
            return ($0.wrongForm ?? "") < ($1.wrongForm ?? "")
        }
    }

    private static func validateText(
        _ text: String,
        maximumLength: Int,
        field: PersonalVocabularyValidationIssue.Field,
        issues: inout [PersonalVocabularyValidationIssue]
    ) {
        if text.count > maximumLength {
            issues.append(.init(code: .valueTooLong, field: field, message: "Value is too long."))
        }
        if text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            issues.append(.init(code: .controlCharacter, field: field, message: "Control characters are not allowed."))
        }
    }

    private static func isValidBundleIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 255, !value.hasPrefix("."), !value.hasSuffix(".") else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func scopesOverlap(_ lhs: PersonalVocabularyEntry, _ rhs: PersonalVocabularyEntry) -> Bool {
        lhs.applicationBundleIDs.isEmpty || rhs.applicationBundleIDs.isEmpty || !lhs.applicationBundleIDs.isDisjoint(with: rhs.applicationBundleIDs)
    }

    private static func languagesOverlap(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs = VocabularyNormalization.language(lhs), let rhs = VocabularyNormalization.language(rhs) else { return true }
        return VocabularyNormalization.languageMatches(entryLanguage: lhs, contextLanguage: rhs)
            || VocabularyNormalization.languageMatches(entryLanguage: rhs, contextLanguage: lhs)
    }
}

enum VocabularyNormalization {
    static let locale = Locale(identifier: "en_US_POSIX")

    static func text(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: locale)
    }

    static func language(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased(with: locale)
        return normalized.isEmpty ? nil : normalized
    }

    static func languageMatches(entryLanguage: String?, contextLanguage: String?) -> Bool {
        guard let entryLanguage = language(entryLanguage) else { return true }
        guard let contextLanguage = language(contextLanguage) else { return false }
        return entryLanguage == contextLanguage || contextLanguage.hasPrefix(entryLanguage + "-")
    }

    static func applies(_ entry: PersonalVocabularyEntry, to context: VocabularyMatchContext) -> Bool {
        guard entry.isEnabled, languageMatches(entryLanguage: entry.language, contextLanguage: context.language) else { return false }
        if entry.applicationBundleIDs.isEmpty { return true }
        guard let bundleID = context.applicationBundleID else { return false }
        return entry.applicationBundleIDs.contains(bundleID)
    }
}
