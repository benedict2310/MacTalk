import Foundation

enum VocabularyCSVError: Error, Equatable, Sendable {
    case invalidUTF8
    case missingVersionHeader
    case unsupportedVersion(Int)
    case malformedCSV(String)
    case missingWrittenFormColumn
}

struct VocabularyCSVImportIssue: Equatable, Sendable {
    let row: Int
    let message: String
    let validationCode: PersonalVocabularyValidationCode?
}

struct VocabularyCSVImportPreview: Equatable, Sendable {
    let schemaVersion: Int
    let entries: [PersonalVocabularyEntry]
    let issues: [VocabularyCSVImportIssue]
    let duplicateRowCount: Int
    let conflictCount: Int
}

struct VocabularyCSVCodec: Sendable {
    static let currentVersion = 1
    static let versionHeader = "# MacTalk Personal Vocabulary CSV v1"

    private static let columns = [
        "written_form",
        "wrong_form",
        "spoken_form",
        "language",
        "bundle_id",
        "priority",
        "recognition_hint",
        "replacement",
    ]

    func export(_ entries: [PersonalVocabularyEntry]) throws -> Data {
        var lines = [Self.versionHeader, Self.columns.joined(separator: ",")]
        let sortedEntries = entries.sorted {
            let lhs = VocabularyNormalization.text($0.writtenForm)
            let rhs = VocabularyNormalization.text($1.writtenForm)
            if lhs != rhs { return lhs < rhs }
            return $0.id.uuidString < $1.id.uuidString
        }

        for entry in sortedEntries {
            let wrongForms: [String?] = entry.wrongForms.isEmpty
                ? [nil]
                : entry.wrongForms.sorted { $0.id.uuidString < $1.id.uuidString }.map { Optional($0.text) }
            let bundleIDs = entry.applicationBundleIDs.sorted().joined(separator: ";")
            for wrongForm in wrongForms {
                lines.append([
                    entry.writtenForm,
                    wrongForm ?? "",
                    entry.spokenForm ?? "",
                    entry.language ?? "",
                    bundleIDs,
                    entry.priority.rawValue,
                    entry.recognitionHintEnabled ? "true" : "false",
                    entry.replacementEnabled ? "true" : "false",
                ].map(csvEscape).joined(separator: ","))
            }
        }

        guard let data = (lines.joined(separator: "\n") + "\n").data(using: .utf8) else {
            throw VocabularyCSVError.invalidUTF8
        }
        return data
    }

    func previewImport(
        data: Data,
        existingEntries: [PersonalVocabularyEntry] = []
    ) throws -> VocabularyCSVImportPreview {
        guard var text = String(data: data, encoding: .utf8) else { throw VocabularyCSVError.invalidUTF8 }
        if text.first == "\u{feff}" { text.removeFirst() }
        let (version, body) = try parseVersion(in: text)
        let rows = try parseRows(body, startingAt: 2)
        guard let header = rows.first else { throw VocabularyCSVError.missingWrittenFormColumn }
        let names = header.fields.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard let writtenIndex = names.firstIndex(of: "written_form") else {
            throw VocabularyCSVError.missingWrittenFormColumn
        }

        func index(_ name: String) -> Int? { names.firstIndex(of: name) }
        var builders: [ImportIdentity: ImportBuilder] = [:]
        var identityOrder: [ImportIdentity] = []
        var issues: [VocabularyCSVImportIssue] = []
        var duplicateRows = 0

        for row in rows.dropFirst() where !row.fields.allSatisfy({ $0.isEmpty }) {
            func value(_ column: String) -> String {
                guard let columnIndex = index(column), columnIndex < row.fields.count else { return "" }
                return row.fields[columnIndex]
            }

            let writtenForm = writtenIndex < row.fields.count ? row.fields[writtenIndex] : ""
            let language = nilIfEmpty(value("language"))
            let bundleIDs = Set(value("bundle_id").split(separator: ";").map(String.init).filter { !$0.isEmpty })
            let priorityText = value("priority").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let priority: PersonalVocabularyPriority
            if priorityText.isEmpty || priorityText == "normal" {
                priority = .normal
            } else if priorityText == "important" {
                priority = .important
            } else {
                issues.append(.init(row: row.number, message: "Invalid priority '\(priorityText)'.", validationCode: nil))
                continue
            }
            guard let hintEnabled = parseBoolean(value("recognition_hint"), defaultValue: true) else {
                issues.append(.init(row: row.number, message: "recognition_hint must be a boolean.", validationCode: nil))
                continue
            }
            guard let replacementEnabled = parseBoolean(value("replacement"), defaultValue: true) else {
                issues.append(.init(row: row.number, message: "replacement must be a boolean.", validationCode: nil))
                continue
            }

            let identity = ImportIdentity(
                writtenForm: VocabularyNormalization.text(writtenForm),
                language: VocabularyNormalization.language(language),
                bundleIDs: bundleIDs.sorted()
            )
            let wrongForm = nilIfEmpty(value("wrong_form"))
            if var builder = builders[identity] {
                duplicateRows += 1
                let spokenForm = nilIfEmpty(value("spoken_form"))
                if builder.spokenForm != spokenForm
                    || builder.priority != priority
                    || builder.hintEnabled != hintEnabled
                    || builder.replacementEnabled != replacementEnabled {
                    issues.append(.init(
                        row: row.number,
                        message: "Duplicate rows contain inconsistent metadata.",
                        validationCode: nil
                    ))
                }
                if let wrongForm, !builder.wrongForms.contains(where: { VocabularyNormalization.text($0) == VocabularyNormalization.text(wrongForm) }) {
                    builder.wrongForms.append(wrongForm)
                }
                builders[identity] = builder
            } else {
                identityOrder.append(identity)
                builders[identity] = ImportBuilder(
                    row: row.number,
                    writtenForm: writtenForm,
                    spokenForm: nilIfEmpty(value("spoken_form")),
                    wrongForms: wrongForm.map { [$0] } ?? [],
                    language: language,
                    bundleIDs: bundleIDs,
                    priority: priority,
                    hintEnabled: hintEnabled,
                    replacementEnabled: replacementEnabled
                )
            }
        }

        var entries: [PersonalVocabularyEntry] = []
        var entryRows: [UUID: Int] = [:]
        for identity in identityOrder {
            guard let builder = builders[identity] else { continue }
            let entry = PersonalVocabularyEntry(
                writtenForm: builder.writtenForm,
                spokenForm: builder.spokenForm,
                wrongForms: builder.wrongForms.map { PersonalVocabularyWrongForm(text: $0) },
                language: builder.language,
                applicationBundleIDs: builder.bundleIDs,
                priority: builder.priority,
                recognitionHintEnabled: builder.hintEnabled,
                replacementEnabled: builder.replacementEnabled,
                source: .imported
            )
            let validationIssues = PersonalVocabularyValidator.validate(entry)
            if validationIssues.isEmpty {
                entries.append(entry)
                entryRows[entry.id] = builder.row
            } else {
                issues.append(contentsOf: validationIssues.map {
                    VocabularyCSVImportIssue(row: builder.row, message: $0.message, validationCode: $0.code)
                })
            }
        }

        let conflictEntryIDs = Set(entries.compactMap { entry -> UUID? in
            let otherImported = entries.filter { $0.id != entry.id }
            let conflicts = PersonalVocabularyValidator.conflicts(for: entry, against: existingEntries + otherImported)
            return conflicts.isEmpty ? nil : entry.id
        })
        for entry in entries where conflictEntryIDs.contains(entry.id) {
            issues.append(.init(
                row: entryRows[entry.id] ?? 0,
                message: "Entry conflicts with an existing or imported vocabulary rule.",
                validationCode: nil
            ))
        }

        return VocabularyCSVImportPreview(
            schemaVersion: version,
            entries: entries,
            issues: issues.sorted { $0.row < $1.row },
            duplicateRowCount: duplicateRows,
            conflictCount: conflictEntryIDs.count
        )
    }

    private func parseVersion(in text: String) throws -> (Int, Substring) {
        let firstNewline = text.firstIndex(of: "\n") ?? text.endIndex
        let rawHeader = text[..<firstNewline].trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "# MacTalk Personal Vocabulary CSV v"
        guard rawHeader.hasPrefix(prefix), let version = Int(rawHeader.dropFirst(prefix.count)) else {
            throw VocabularyCSVError.missingVersionHeader
        }
        guard version == Self.currentVersion else { throw VocabularyCSVError.unsupportedVersion(version) }
        let bodyStart = firstNewline < text.endIndex ? text.index(after: firstNewline) : text.endIndex
        return (version, text[bodyStart...])
    }

    private func parseRows(_ text: Substring, startingAt initialRow: Int) throws -> [CSVRow] {
        var rows: [CSVRow] = []
        var fields: [String] = []
        var field = ""
        var insideQuotes = false
        var index = text.startIndex
        var physicalRow = initialRow
        var recordStartRow = initialRow

        func finishRecord() {
            fields.append(field)
            rows.append(CSVRow(number: recordStartRow, fields: fields))
            field = ""
            fields = []
            recordStartRow = physicalRow + 1
        }

        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if insideQuotes {
                if character == "\"" {
                    if next < text.endIndex, text[next] == "\"" {
                        field.append("\"")
                        index = text.index(after: next)
                        continue
                    }
                    insideQuotes = false
                } else {
                    field.append(character)
                    if character == "\n" { physicalRow += 1 }
                }
            } else {
                switch character {
                case "\"" where field.isEmpty:
                    insideQuotes = true
                case ",":
                    fields.append(field)
                    field = ""
                case "\n":
                    finishRecord()
                    physicalRow += 1
                case "\r":
                    break
                default:
                    field.append(character)
                }
            }
            index = next
        }
        guard !insideQuotes else { throw VocabularyCSVError.malformedCSV("Unterminated quoted field." ) }
        if !field.isEmpty || !fields.isEmpty { finishRecord() }
        return rows
    }

    private func parseBoolean(_ value: String, defaultValue: Bool) -> Bool? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "": return defaultValue
        case "true", "1", "yes": return true
        case "false", "0", "no": return false
        default: return nil
        }
    }

    private func nilIfEmpty(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }

    private func csvEscape(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

private extension VocabularyCSVCodec {
    struct CSVRow {
        let number: Int
        let fields: [String]
    }

    struct ImportIdentity: Hashable {
        let writtenForm: String
        let language: String?
        let bundleIDs: [String]
    }

    struct ImportBuilder {
        let row: Int
        let writtenForm: String
        let spokenForm: String?
        var wrongForms: [String]
        let language: String?
        let bundleIDs: Set<String>
        let priority: PersonalVocabularyPriority
        let hintEnabled: Bool
        let replacementEnabled: Bool
    }
}
