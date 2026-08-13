import Foundation
import SQLite3

enum PersonalVocabularyStoreError: Error, Equatable, Sendable {
    case cannotCreateStorage
    case cannotOpenDatabase(code: Int32)
    case databaseFailure(code: Int32)
    case malformedRecord
    case notFound
    case validation([PersonalVocabularyValidationIssue])
    case conflicts([PersonalVocabularyConflict])
}

protocol PersonalVocabularyStoring: Sendable {
    func entries() async throws -> [PersonalVocabularyEntry]
    func entry(id: UUID) async throws -> PersonalVocabularyEntry?
    func snapshot() async throws -> PersonalVocabularySnapshot
    @discardableResult func save(_ entry: PersonalVocabularyEntry) async throws -> PersonalVocabularyEntry
    @discardableResult func saveAll(_ entries: [PersonalVocabularyEntry]) async throws -> [PersonalVocabularyEntry]
    @discardableResult func setEnabled(_ isEnabled: Bool, id: UUID, modifiedAt: Date) async throws -> PersonalVocabularyEntry
    func recordApplications(entryIDs: Set<UUID>, appliedAt: Date) async throws
    func recordDirectRecognitions(entryIDs: Set<UUID>, recognizedAt: Date) async throws
    func delete(id: UUID) async throws
    @discardableResult func deleteAll() async throws -> Int
}

extension PersonalVocabularyStoring {
    @discardableResult
    func setEnabled(_ isEnabled: Bool, id: UUID) async throws -> PersonalVocabularyEntry {
        try await self.setEnabled(isEnabled, id: id, modifiedAt: Date())
    }

    func recordApplications(entryIDs: Set<UUID>) async throws {
        try await self.recordApplications(entryIDs: entryIDs, appliedAt: Date())
    }

    func recordDirectRecognitions(entryIDs: Set<UUID>) async throws {
        try await self.recordDirectRecognitions(entryIDs: entryIDs, recognizedAt: Date())
    }
}

actor PersonalVocabularyStore: PersonalVocabularyStoring {
    private let connection: PersonalVocabularySQLiteConnection

    init(databaseURL: URL) throws {
        let fileManager = FileManager.default
        do {
            try Self.createPrivateDirectory(at: databaseURL.deletingLastPathComponent(), fileManager: fileManager)
        } catch {
            throw PersonalVocabularyStoreError.cannotCreateStorage
        }

        var opened: OpaquePointer?
        let result = sqlite3_open_v2(
            databaseURL.path,
            &opened,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let opened else {
            if let opened { sqlite3_close(opened) }
            throw PersonalVocabularyStoreError.cannotOpenDatabase(code: result)
        }
        do {
            sqlite3_busy_timeout(opened, 5_000)
            try Self.execute(opened, sql: "PRAGMA journal_mode = WAL")
            try Self.execute(opened, sql: "PRAGMA synchronous = NORMAL")
            try Self.execute(opened, sql: "PRAGMA foreign_keys = ON")
            try Self.createTables(opened)
            try? fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: databaseURL.path
            )
        } catch {
            sqlite3_close(opened)
            throw error
        }
        self.connection = PersonalVocabularySQLiteConnection(handle: opened)
    }

    static func makeDefault() throws -> PersonalVocabularyStore {
        let fileManager = FileManager.default
        guard let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw PersonalVocabularyStoreError.cannotCreateStorage
        }
        let root = applicationSupport.appendingPathComponent("MacTalk", isDirectory: true)
        return try PersonalVocabularyStore(databaseURL: root.appendingPathComponent("MacTeach.sqlite"))
    }

    func entries() throws -> [PersonalVocabularyEntry] {
        try self.loadEntries()
    }

    func entry(id: UUID) throws -> PersonalVocabularyEntry? {
        try self.loadEntries(id: id).first
    }

    func snapshot() throws -> PersonalVocabularySnapshot {
        PersonalVocabularySnapshot(entries: try self.loadEntries(), version: try self.revision())
    }

    @discardableResult
    func save(_ entry: PersonalVocabularyEntry) throws -> PersonalVocabularyEntry {
        let validation = PersonalVocabularyValidator.validate(entry)
        guard validation.isEmpty else { throw PersonalVocabularyStoreError.validation(validation) }

        return try self.withTransaction {
            let conflicts = PersonalVocabularyValidator.conflicts(for: entry, against: try self.loadEntries())
            guard conflicts.isEmpty else { throw PersonalVocabularyStoreError.conflicts(conflicts) }
            try self.write(entry)
            try self.advanceRevision()
            return entry
        }
    }

    @discardableResult
    func saveAll(_ entries: [PersonalVocabularyEntry]) throws -> [PersonalVocabularyEntry] {
        guard !entries.isEmpty else { return [] }
        let validation = entries.flatMap(PersonalVocabularyValidator.validate)
        guard validation.isEmpty else { throw PersonalVocabularyStoreError.validation(validation) }

        return try self.withTransaction {
            let importedIDs = Set(entries.map(\.id))
            let untouched = try self.loadEntries().filter { !importedIDs.contains($0.id) }
            var conflicts: [PersonalVocabularyConflict] = []
            for entry in entries {
                conflicts.append(contentsOf: PersonalVocabularyValidator.conflicts(
                    for: entry,
                    against: untouched + entries.filter { $0.id != entry.id }
                ))
            }
            guard conflicts.isEmpty else { throw PersonalVocabularyStoreError.conflicts(conflicts) }
            for entry in entries { try self.write(entry) }
            try self.advanceRevision()
            return entries
        }
    }

    @discardableResult
    func setEnabled(_ isEnabled: Bool, id: UUID, modifiedAt: Date) throws -> PersonalVocabularyEntry {
        guard let existing = try self.entry(id: id) else { throw PersonalVocabularyStoreError.notFound }
        guard existing.isEnabled != isEnabled else { return existing }
        let updated = self.copy(existing, isEnabled: isEnabled, updatedAt: modifiedAt)
        return try self.save(updated)
    }

    func recordApplications(entryIDs: Set<UUID>, appliedAt: Date) throws {
        guard !entryIDs.isEmpty else { return }
        try self.withTransaction {
            let database = try self.requireDatabase()
            let statement = try self.prepare(
                "UPDATE vocabulary_entries SET application_count = application_count + 1, last_applied_at = ? WHERE id = ?"
            )
            defer { sqlite3_finalize(statement) }
            var changed = false
            for id in entryIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                try self.bind(appliedAt.timeIntervalSince1970, at: 1, to: statement)
                try self.bind(id.uuidString.lowercased(), at: 2, to: statement)
                try self.step(statement)
                if sqlite3_changes(database) > 0 { changed = true }
            }
            if changed { try self.advanceRevision() }
        }
    }

    func recordDirectRecognitions(entryIDs: Set<UUID>, recognizedAt: Date) throws {
        guard !entryIDs.isEmpty else { return }
        try self.withTransaction {
            let database = try self.requireDatabase()
            let statement = try self.prepare(
                "UPDATE vocabulary_entries SET direct_recognition_count = direct_recognition_count + 1, last_recognized_at = ? WHERE id = ?"
            )
            defer { sqlite3_finalize(statement) }
            var changed = false
            for id in entryIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                try self.bind(recognizedAt.timeIntervalSince1970, at: 1, to: statement)
                try self.bind(id.uuidString.lowercased(), at: 2, to: statement)
                try self.step(statement)
                if sqlite3_changes(database) > 0 { changed = true }
            }
            if changed { try self.advanceRevision() }
        }
    }

    func delete(id: UUID) throws {
        try self.withTransaction {
            let statement = try self.prepare("DELETE FROM vocabulary_entries WHERE id = ?")
            defer { sqlite3_finalize(statement) }
            try self.bind(id.uuidString.lowercased(), at: 1, to: statement)
            try self.step(statement)
            guard sqlite3_changes(try self.requireDatabase()) > 0 else {
                throw PersonalVocabularyStoreError.notFound
            }
            try self.advanceRevision()
        }
    }

    @discardableResult
    func deleteAll() throws -> Int {
        try self.withTransaction {
            let countStatement = try self.prepare("SELECT COUNT(*) FROM vocabulary_entries")
            defer { sqlite3_finalize(countStatement) }
            guard sqlite3_step(countStatement) == SQLITE_ROW else { throw self.databaseError() }
            let count = Int(sqlite3_column_int64(countStatement, 0))
            guard count > 0 else { return 0 }

            try self.execute("DELETE FROM vocabulary_entries")
            try self.advanceRevision()
            return count
        }
    }

    private func write(_ entry: PersonalVocabularyEntry) throws {
        let sql = """
            INSERT INTO vocabulary_entries (
                id, written_form, spoken_form, language, priority,
                hint_enabled, replacement_enabled, enabled, source,
                source_history_id, created_at, updated_at, application_count,
                correction_count, last_applied_at, direct_recognition_count,
                last_recognized_at, schema_version
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                written_form = excluded.written_form,
                spoken_form = excluded.spoken_form,
                language = excluded.language,
                priority = excluded.priority,
                hint_enabled = excluded.hint_enabled,
                replacement_enabled = excluded.replacement_enabled,
                enabled = excluded.enabled,
                source = excluded.source,
                source_history_id = excluded.source_history_id,
                created_at = excluded.created_at,
                updated_at = excluded.updated_at,
                application_count = excluded.application_count,
                correction_count = excluded.correction_count,
                last_applied_at = excluded.last_applied_at,
                direct_recognition_count = excluded.direct_recognition_count,
                last_recognized_at = excluded.last_recognized_at,
                schema_version = excluded.schema_version
            """
        let statement = try self.prepare(sql)
        defer { sqlite3_finalize(statement) }
        let values: [SQLiteValue] = [
            .text(entry.id.uuidString.lowercased()), .text(entry.writtenForm), .optionalText(entry.spokenForm),
            .optionalText(entry.language), .text(entry.priority.rawValue), .bool(entry.recognitionHintEnabled),
            .bool(entry.replacementEnabled), .bool(entry.isEnabled), .text(entry.source.rawValue),
            .optionalText(entry.sourceHistoryRecordID?.uuidString.lowercased()), .real(entry.createdAt.timeIntervalSince1970),
            .real(entry.updatedAt.timeIntervalSince1970), .integer(Int64(entry.applicationCount)),
            .integer(Int64(entry.correctionCount)), .optionalReal(entry.lastAppliedAt?.timeIntervalSince1970),
            .integer(Int64(entry.directRecognitionCount)), .optionalReal(entry.lastRecognizedAt?.timeIntervalSince1970),
            .integer(Int64(entry.schemaVersion)),
        ]
        for (offset, value) in values.enumerated() { try self.bind(value, at: Int32(offset + 1), to: statement) }
        try self.step(statement)

        try self.deleteChildren(entryID: entry.id)
        let wrongStatement = try self.prepare(
            "INSERT INTO vocabulary_wrong_forms (id, vocabulary_entry_id, wrong_form, normalized_form, sort_index) VALUES (?, ?, ?, ?, ?)"
        )
        defer { sqlite3_finalize(wrongStatement) }
        for (index, wrongForm) in entry.wrongForms.enumerated() {
            sqlite3_reset(wrongStatement)
            sqlite3_clear_bindings(wrongStatement)
            try self.bind(wrongForm.id.uuidString.lowercased(), at: 1, to: wrongStatement)
            try self.bind(entry.id.uuidString.lowercased(), at: 2, to: wrongStatement)
            try self.bind(wrongForm.text, at: 3, to: wrongStatement)
            try self.bind(VocabularyNormalization.text(wrongForm.text), at: 4, to: wrongStatement)
            try self.bind(Int64(index), at: 5, to: wrongStatement)
            try self.step(wrongStatement)
        }

        let scopeStatement = try self.prepare(
            "INSERT INTO vocabulary_app_scopes (vocabulary_entry_id, bundle_id) VALUES (?, ?)"
        )
        defer { sqlite3_finalize(scopeStatement) }
        for bundleID in entry.applicationBundleIDs.sorted() {
            sqlite3_reset(scopeStatement)
            sqlite3_clear_bindings(scopeStatement)
            try self.bind(entry.id.uuidString.lowercased(), at: 1, to: scopeStatement)
            try self.bind(bundleID, at: 2, to: scopeStatement)
            try self.step(scopeStatement)
        }
    }

    private func deleteChildren(entryID: UUID) throws {
        for table in ["vocabulary_wrong_forms", "vocabulary_app_scopes"] {
            let statement = try self.prepare("DELETE FROM \(table) WHERE vocabulary_entry_id = ?")
            defer { sqlite3_finalize(statement) }
            try self.bind(entryID.uuidString.lowercased(), at: 1, to: statement)
            try self.step(statement)
        }
    }

    private func loadEntries(id: UUID? = nil) throws -> [PersonalVocabularyEntry] {
        var sql = """
            SELECT id, written_form, spoken_form, language, priority,
                   hint_enabled, replacement_enabled, enabled, source,
                   source_history_id, created_at, updated_at, application_count,
                   correction_count, last_applied_at, direct_recognition_count,
                   last_recognized_at, schema_version
            FROM vocabulary_entries
            """
        if id != nil { sql += " WHERE id = ?" }
        sql += " ORDER BY id"
        let statement = try self.prepare(sql)
        defer { sqlite3_finalize(statement) }
        if let id { try self.bind(id.uuidString.lowercased(), at: 1, to: statement) }

        var rows: [EntryRow] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_DONE:
                break
            case SQLITE_ROW:
                rows.append(try self.readEntryRow(statement))
                continue
            default:
                throw self.databaseError()
            }
            break
        }
        guard !rows.isEmpty else { return [] }
        let wrongForms = try self.loadWrongForms(entryIDs: Set(rows.map(\.id)))
        let scopes = try self.loadScopes(entryIDs: Set(rows.map(\.id)))
        return rows.map { row in
            PersonalVocabularyEntry(
                id: row.id, writtenForm: row.writtenForm, spokenForm: row.spokenForm,
                wrongForms: wrongForms[row.id] ?? [], language: row.language,
                applicationBundleIDs: scopes[row.id] ?? [], priority: row.priority,
                recognitionHintEnabled: row.hintEnabled, replacementEnabled: row.replacementEnabled,
                isEnabled: row.isEnabled, source: row.source, sourceHistoryRecordID: row.sourceHistoryRecordID,
                createdAt: row.createdAt, updatedAt: row.updatedAt, applicationCount: row.applicationCount,
                correctionCount: row.correctionCount, lastAppliedAt: row.lastAppliedAt,
                directRecognitionCount: row.directRecognitionCount, lastRecognizedAt: row.lastRecognizedAt,
                schemaVersion: row.schemaVersion
            )
        }
    }

    private func readEntryRow(_ statement: OpaquePointer) throws -> EntryRow {
        guard let id = UUID(uuidString: try self.requiredText(statement, 0)),
              let priority = PersonalVocabularyPriority(rawValue: try self.requiredText(statement, 4)),
              let source = PersonalVocabularySource(rawValue: try self.requiredText(statement, 8)) else {
            throw PersonalVocabularyStoreError.malformedRecord
        }
        let historyID: UUID?
        if let raw = self.optionalText(statement, 9) {
            guard let parsed = UUID(uuidString: raw) else { throw PersonalVocabularyStoreError.malformedRecord }
            historyID = parsed
        } else {
            historyID = nil
        }
        return EntryRow(
            id: id, writtenForm: try self.requiredText(statement, 1), spokenForm: self.optionalText(statement, 2),
            language: self.optionalText(statement, 3), priority: priority,
            hintEnabled: sqlite3_column_int(statement, 5) != 0,
            replacementEnabled: sqlite3_column_int(statement, 6) != 0,
            isEnabled: sqlite3_column_int(statement, 7) != 0, source: source,
            sourceHistoryRecordID: historyID, createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 10)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 11)),
            applicationCount: Int(sqlite3_column_int64(statement, 12)),
            correctionCount: Int(sqlite3_column_int64(statement, 13)),
            lastAppliedAt: sqlite3_column_type(statement, 14) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 14)),
            directRecognitionCount: Int(sqlite3_column_int64(statement, 15)),
            lastRecognizedAt: sqlite3_column_type(statement, 16) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 16)),
            schemaVersion: Int(sqlite3_column_int(statement, 17))
        )
    }

    private func loadWrongForms(entryIDs: Set<UUID>) throws -> [UUID: [PersonalVocabularyWrongForm]] {
        guard !entryIDs.isEmpty else { return [:] }
        let statement = try self.prepare(
            "SELECT id, vocabulary_entry_id, wrong_form FROM vocabulary_wrong_forms ORDER BY vocabulary_entry_id, sort_index"
        )
        defer { sqlite3_finalize(statement) }
        var result: [UUID: [PersonalVocabularyWrongForm]] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = UUID(uuidString: try self.requiredText(statement, 0)),
                  let entryID = UUID(uuidString: try self.requiredText(statement, 1)) else {
                throw PersonalVocabularyStoreError.malformedRecord
            }
            if entryIDs.contains(entryID) {
                result[entryID, default: []].append(.init(id: id, text: try self.requiredText(statement, 2)))
            }
        }
        return result
    }

    private func loadScopes(entryIDs: Set<UUID>) throws -> [UUID: Set<String>] {
        guard !entryIDs.isEmpty else { return [:] }
        let statement = try self.prepare(
            "SELECT vocabulary_entry_id, bundle_id FROM vocabulary_app_scopes ORDER BY vocabulary_entry_id, bundle_id"
        )
        defer { sqlite3_finalize(statement) }
        var result: [UUID: Set<String>] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let entryID = UUID(uuidString: try self.requiredText(statement, 0)) else {
                throw PersonalVocabularyStoreError.malformedRecord
            }
            if entryIDs.contains(entryID) { result[entryID, default: []].insert(try self.requiredText(statement, 1)) }
        }
        return result
    }

    private func revision() throws -> UInt64 {
        let statement = try self.prepare("SELECT revision FROM vocabulary_metadata WHERE singleton = 1")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw self.databaseError() }
        return UInt64(max(0, sqlite3_column_int64(statement, 0)))
    }

    private func advanceRevision() throws {
        try self.execute("UPDATE vocabulary_metadata SET revision = revision + 1 WHERE singleton = 1")
    }

    private func copy(_ entry: PersonalVocabularyEntry, isEnabled: Bool, updatedAt: Date) -> PersonalVocabularyEntry {
        PersonalVocabularyEntry(
            id: entry.id, writtenForm: entry.writtenForm, spokenForm: entry.spokenForm,
            wrongForms: entry.wrongForms, language: entry.language, applicationBundleIDs: entry.applicationBundleIDs,
            priority: entry.priority, recognitionHintEnabled: entry.recognitionHintEnabled,
            replacementEnabled: entry.replacementEnabled, isEnabled: isEnabled, source: entry.source,
            sourceHistoryRecordID: entry.sourceHistoryRecordID, createdAt: entry.createdAt, updatedAt: updatedAt,
            applicationCount: entry.applicationCount, correctionCount: entry.correctionCount,
            lastAppliedAt: entry.lastAppliedAt, directRecognitionCount: entry.directRecognitionCount,
            lastRecognizedAt: entry.lastRecognizedAt, schemaVersion: entry.schemaVersion
        )
    }

    private func withTransaction<T>(_ operation: () throws -> T) throws -> T {
        try self.execute("BEGIN IMMEDIATE")
        do {
            let value = try operation()
            try self.execute("COMMIT")
            return value
        } catch {
            try? self.execute("ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(try self.requireDatabase(), sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else { throw self.databaseError(code: result) }
        return statement
    }

    private func step(_ statement: OpaquePointer) throws {
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else { throw self.databaseError(code: result) }
    }

    private func bind(_ value: SQLiteValue, at index: Int32, to statement: OpaquePointer) throws {
        let result: Int32
        switch value {
        case let .text(text): result = sqlite3_bind_text(statement, index, text, -1, Self.sqliteTransient)
        case let .integer(integer): result = sqlite3_bind_int64(statement, index, integer)
        case let .real(real): result = sqlite3_bind_double(statement, index, real)
        case .null: result = sqlite3_bind_null(statement, index)
        }
        guard result == SQLITE_OK else { throw self.databaseError(code: result) }
    }

    private func bind(_ value: String, at index: Int32, to statement: OpaquePointer) throws { try self.bind(.text(value), at: index, to: statement) }
    private func bind(_ value: Int64, at index: Int32, to statement: OpaquePointer) throws { try self.bind(.integer(value), at: index, to: statement) }
    private func bind(_ value: Double, at index: Int32, to statement: OpaquePointer) throws { try self.bind(.real(value), at: index, to: statement) }

    private func execute(_ sql: String) throws { try Self.execute(try self.requireDatabase(), sql: sql) }
    private func requireDatabase() throws -> OpaquePointer {
        self.connection.handle
    }
    private func databaseError(code: Int32? = nil) -> PersonalVocabularyStoreError {
        .databaseFailure(code: code ?? sqlite3_errcode(self.connection.handle))
    }
    private func requiredText(_ statement: OpaquePointer, _ index: Int32) throws -> String {
        guard let value = self.optionalText(statement, index) else { throw PersonalVocabularyStoreError.malformedRecord }
        return value
    }
    private func optionalText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL, let raw = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: raw)
    }

    private static func createTables(_ database: OpaquePointer) throws {
        try self.execute(database, sql: "BEGIN IMMEDIATE")
        do {
            try self.execute(database, sql: """
                CREATE TABLE IF NOT EXISTS vocabulary_entries (
                    id TEXT PRIMARY KEY NOT NULL,
                    written_form TEXT NOT NULL,
                    spoken_form TEXT,
                    language TEXT,
                    priority TEXT NOT NULL,
                    hint_enabled INTEGER NOT NULL,
                    replacement_enabled INTEGER NOT NULL,
                    enabled INTEGER NOT NULL,
                    source TEXT NOT NULL,
                    source_history_id TEXT,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    application_count INTEGER NOT NULL,
                    correction_count INTEGER NOT NULL,
                    last_applied_at REAL,
                    direct_recognition_count INTEGER NOT NULL DEFAULT 0,
                    last_recognized_at REAL,
                    schema_version INTEGER NOT NULL
                )
                """)
            let entryColumns = try self.columnNames(database, table: "vocabulary_entries")
            if !entryColumns.contains("direct_recognition_count") {
                try self.execute(
                    database,
                    sql: "ALTER TABLE vocabulary_entries ADD COLUMN direct_recognition_count INTEGER NOT NULL DEFAULT 0"
                )
            }
            if !entryColumns.contains("last_recognized_at") {
                try self.execute(database, sql: "ALTER TABLE vocabulary_entries ADD COLUMN last_recognized_at REAL")
            }
            try self.execute(
                database,
                sql: "UPDATE vocabulary_entries SET schema_version = \(PersonalVocabularyEntry.currentSchemaVersion) WHERE schema_version < \(PersonalVocabularyEntry.currentSchemaVersion)"
            )
            try self.execute(database, sql: """
                CREATE TABLE IF NOT EXISTS vocabulary_wrong_forms (
                    id TEXT PRIMARY KEY NOT NULL,
                    vocabulary_entry_id TEXT NOT NULL REFERENCES vocabulary_entries(id) ON DELETE CASCADE,
                    wrong_form TEXT NOT NULL,
                    normalized_form TEXT NOT NULL,
                    sort_index INTEGER NOT NULL
                )
                """)
            try self.execute(database, sql: """
                CREATE TABLE IF NOT EXISTS vocabulary_app_scopes (
                    vocabulary_entry_id TEXT NOT NULL REFERENCES vocabulary_entries(id) ON DELETE CASCADE,
                    bundle_id TEXT NOT NULL,
                    PRIMARY KEY (vocabulary_entry_id, bundle_id)
                )
                """)
            try self.execute(database, sql: """
                CREATE TABLE IF NOT EXISTS vocabulary_metadata (
                    singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
                    revision INTEGER NOT NULL
                )
                """)
            try self.execute(database, sql: "INSERT OR IGNORE INTO vocabulary_metadata (singleton, revision) VALUES (1, 0)")
            try self.execute(database, sql: "CREATE INDEX IF NOT EXISTS vocabulary_wrong_normalized ON vocabulary_wrong_forms(normalized_form)")
            try self.execute(database, sql: "COMMIT")
        } catch {
            try? self.execute(database, sql: "ROLLBACK")
            throw error
        }
    }

    private static func execute(_ database: OpaquePointer, sql: String) throws {
        let result = sqlite3_exec(database, sql, nil, nil, nil)
        guard result == SQLITE_OK else { throw PersonalVocabularyStoreError.databaseFailure(code: result) }
    }

    private static func columnNames(_ database: OpaquePointer, table: String) throws -> Set<String> {
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(database, "PRAGMA table_info(\(table))", -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else {
            throw PersonalVocabularyStoreError.databaseFailure(code: prepared)
        }
        defer { sqlite3_finalize(statement) }
        var names: Set<String> = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let rawName = sqlite3_column_text(statement, 1) else {
                    throw PersonalVocabularyStoreError.malformedRecord
                }
                names.insert(String(cString: rawName))
            case SQLITE_DONE:
                return names
            default:
                throw PersonalVocabularyStoreError.databaseFailure(code: sqlite3_errcode(database))
            }
        }
    }

    private static func createPrivateDirectory(at url: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: Int16(0o700))], ofItemAtPath: url.path)
    }

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

private enum SQLiteValue {
    case text(String)
    case integer(Int64)
    case real(Double)
    case null

    static func optionalText(_ value: String?) -> SQLiteValue { value.map(SQLiteValue.text) ?? .null }
    static func optionalReal(_ value: Double?) -> SQLiteValue { value.map(SQLiteValue.real) ?? .null }
    static func bool(_ value: Bool) -> SQLiteValue { .integer(value ? 1 : 0) }
}

private struct EntryRow {
    let id: UUID
    let writtenForm: String
    let spokenForm: String?
    let language: String?
    let priority: PersonalVocabularyPriority
    let hintEnabled: Bool
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
}

private final class PersonalVocabularySQLiteConnection: @unchecked Sendable {
    let handle: OpaquePointer

    init(handle: OpaquePointer) {
        self.handle = handle
    }

    deinit {
        sqlite3_close(self.handle)
    }
}
