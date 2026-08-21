import Foundation
import SQLite3

enum HistoryStoreError: Error, LocalizedError, Sendable, Equatable {
    case cannotCreateStorage
    case cannotOpenDatabase(code: Int32)
    case databaseFailure(code: Int32)
    case unsupportedDatabaseVersion(Int)
    case malformedDatabaseRecord
    case recordNotFound
    case invalidAudioFile
    case invalidAudioFileExtension

    var errorDescription: String? {
        switch self {
        case .cannotCreateStorage:
            return "MacTalk could not create private History storage."
        case let .cannotOpenDatabase(code):
            return "MacTalk could not open History (SQLite error \(code))."
        case let .databaseFailure(code):
            return "MacTalk History encountered a database error (\(code))."
        case let .unsupportedDatabaseVersion(version):
            return "This History database uses unsupported schema version \(version)."
        case .malformedDatabaseRecord:
            return "MacTalk History contains a malformed record."
        case .recordNotFound:
            return "The History record no longer exists."
        case .invalidAudioFile:
            return "The retained recording is not a valid regular file."
        case .invalidAudioFileExtension:
            return "The retained recording has an invalid file extension."
        }
    }
}

protocol HistoryStoring: Sendable {
    func recordTerminalResult(
        _ terminal: HistoryTerminalResult,
        historyEnabled: Bool
    ) async throws -> HistoryPersistenceOutcome

    func record(id: UUID) async throws -> HistoryRecord?
    func search(_ query: HistorySearchQuery) async throws -> [HistoryRecord]
}

actor HistoryStore: HistoryStoring {
    static let currentDatabaseSchemaVersion = 2

    private static let recordColumns = """
        id, session_id, created_at, completed_at,
        provider, model_id, model_revision,
        requested_language, detected_language, capture_mode,
        source_bundle_id, source_display_name,
        raw_asr_text, cleaned_text, delivered_text, corrected_text,
        duration_ms, inference_ms, insertion_succeeded,
        audio_extension, audio_byte_count, audio_created_at, schema_version
        """

    private let databaseURL: URL
    private let audioDirectoryURL: URL
    private let connection: HistorySQLiteConnection

    init(
        databaseURL: URL,
        audioDirectoryURL: URL
    ) throws {
        self.databaseURL = databaseURL
        self.audioDirectoryURL = audioDirectoryURL
        let fileManager = FileManager.default

        do {
            try Self.createPrivateDirectory(
                at: databaseURL.deletingLastPathComponent(),
                fileManager: fileManager
            )
            try Self.createPrivateDirectory(at: audioDirectoryURL, fileManager: fileManager)
        } catch {
            throw HistoryStoreError.cannotCreateStorage
        }

        var openedDatabase: OpaquePointer?
        let openResult = sqlite3_open_v2(
            databaseURL.path,
            &openedDatabase,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let openedDatabase else {
            if let openedDatabase {
                sqlite3_close(openedDatabase)
            }
            throw HistoryStoreError.cannotOpenDatabase(code: openResult)
        }
        do {
            sqlite3_busy_timeout(openedDatabase, 5_000)
            try Self.configure(openedDatabase)
            try Self.migrate(openedDatabase)
            try? fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: databaseURL.path
            )
        } catch {
            sqlite3_close(openedDatabase)
            throw error
        }
        self.connection = HistorySQLiteConnection(handle: openedDatabase)
    }

    static func makeDefault() throws -> HistoryStore {
        let fileManager = FileManager.default
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw HistoryStoreError.cannotCreateStorage
        }
        let root = applicationSupport.appendingPathComponent("MacTalk", isDirectory: true)
        return try HistoryStore(
            databaseURL: root.appendingPathComponent("MacTeach.sqlite"),
            audioDirectoryURL: root.appendingPathComponent("HistoryAudio", isDirectory: true)
        )
    }

    func recordTerminalResult(
        _ terminal: HistoryTerminalResult,
        historyEnabled: Bool = true
    ) throws -> HistoryPersistenceOutcome {
        guard historyEnabled else {
            return .skipped(.historyDisabled)
        }
        guard terminal.outcome == .completed else {
            return .skipped(.cancelled)
        }
        guard !terminal.deliveredText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .skipped(.emptyTranscript)
        }

        let sql = """
            INSERT OR IGNORE INTO history_records (
                id, session_id, created_at, completed_at,
                provider, model_id, model_revision,
                requested_language, detected_language, capture_mode,
                source_bundle_id, source_display_name,
                raw_asr_text, cleaned_text, delivered_text, corrected_text,
                duration_ms, inference_ms, insertion_succeeded,
                audio_extension, audio_byte_count, audio_created_at,
                schema_version, search_text
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?, ?, NULL, NULL, NULL, ?, ?)
            """
        let database = try self.requireDatabase()
        let statement = try self.prepare(sql)
        defer { sqlite3_finalize(statement) }

        try self.bind(terminal.recordID.uuidString.lowercased(), at: 1, to: statement)
        try self.bind(terminal.sessionID.uuidString.lowercased(), at: 2, to: statement)
        try self.bind(terminal.createdAt.timeIntervalSince1970, at: 3, to: statement)
        try self.bind(terminal.completedAt.timeIntervalSince1970, at: 4, to: statement)
        try self.bind(terminal.provider, at: 5, to: statement)
        try self.bind(terminal.modelID, at: 6, to: statement)
        try self.bind(terminal.modelRevision, at: 7, to: statement)
        try self.bind(terminal.requestedLanguage, at: 8, to: statement)
        try self.bind(terminal.detectedLanguage, at: 9, to: statement)
        try self.bind(terminal.captureMode, at: 10, to: statement)
        try self.bind(terminal.sourceBundleID, at: 11, to: statement)
        try self.bind(terminal.sourceDisplayName, at: 12, to: statement)
        try self.bind(terminal.rawASRText, at: 13, to: statement)
        try self.bind(terminal.cleanedText, at: 14, to: statement)
        try self.bind(terminal.deliveredText, at: 15, to: statement)
        try self.bind(terminal.durationMilliseconds, at: 16, to: statement)
        try self.bind(terminal.inferenceMilliseconds, at: 17, to: statement)
        try self.bind(terminal.insertionSucceeded, at: 18, to: statement)
        try self.bind(Int64(HistoryRecord.currentSchemaVersion), at: 19, to: statement)
        try self.bind(Self.normalizedForSearch(terminal.deliveredText), at: 20, to: statement)
        try self.stepDone(statement)

        if sqlite3_changes(database) == 1 {
            guard let inserted = try self.record(id: terminal.recordID) else {
                throw HistoryStoreError.malformedDatabaseRecord
            }
            return .inserted(inserted)
        }
        guard let existing = try self.record(sessionID: terminal.sessionID) else {
            throw HistoryStoreError.databaseFailure(code: SQLITE_CONSTRAINT)
        }
        return .alreadyRecorded(existing)
    }

    func record(id: UUID) throws -> HistoryRecord? {
        try self.fetchOne(
            sql: "SELECT \(Self.recordColumns) FROM history_records WHERE id = ? LIMIT 1",
            value: id.uuidString.lowercased()
        )
    }

    func count() throws -> Int {
        let statement = try self.prepare("SELECT COUNT(*) FROM history_records")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw self.lastDatabaseError()
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    func databaseSchemaVersion() throws -> Int {
        let statement = try self.prepare("PRAGMA user_version")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw self.lastDatabaseError()
        }
        return Int(sqlite3_column_int(statement, 0))
    }

    func search(_ query: HistorySearchQuery) throws -> [HistoryRecord] {
        var clauses: [String] = []
        var bindings: [SQLiteBinding] = []
        let normalizedText = Self.normalizedForSearch(query.text)
        if !normalizedText.isEmpty {
            clauses.append("search_text LIKE ? ESCAPE '\\'")
            bindings.append(.text("%\(Self.escapeLike(normalizedText))%"))
        }
        if let provider = query.provider {
            clauses.append("provider = ?")
            bindings.append(.text(provider))
        }
        if let language = query.language {
            clauses.append("COALESCE(detected_language, requested_language) = ?")
            bindings.append(.text(language))
        }
        if let sourceBundleID = query.sourceBundleID {
            clauses.append("source_bundle_id = ?")
            bindings.append(.text(sourceBundleID))
        }
        if let isCorrected = query.isCorrected {
            clauses.append(isCorrected ? "corrected_text IS NOT NULL" : "corrected_text IS NULL")
        }

        let whereClause = clauses.isEmpty ? "" : " WHERE \(clauses.joined(separator: " AND "))"
        let sql = """
            SELECT \(Self.recordColumns)
            FROM history_records\(whereClause)
            ORDER BY completed_at DESC, id DESC
            LIMIT ? OFFSET ?
            """
        bindings.append(.integer(Int64(query.limit)))
        bindings.append(.integer(Int64(query.offset)))

        let statement = try self.prepare(sql)
        defer { sqlite3_finalize(statement) }
        for (offset, binding) in bindings.enumerated() {
            try self.bind(binding, at: Int32(offset + 1), to: statement)
        }

        var records: [HistoryRecord] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                records.append(try self.decodeRecord(statement))
            case SQLITE_DONE:
                return records
            default:
                throw self.lastDatabaseError()
            }
        }
    }

    func setCorrectedText(_ correctedText: String?, for recordID: UUID) throws -> HistoryRecord {
        guard let original = try self.record(id: recordID) else {
            throw HistoryStoreError.recordNotFound
        }
        let normalizedCorrection: String?
        if let correctedText,
           !correctedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            normalizedCorrection = correctedText
        } else {
            normalizedCorrection = nil
        }
        let currentText = normalizedCorrection ?? original.deliveredText
        let statement = try self.prepare(
            "UPDATE history_records SET corrected_text = ?, search_text = ? WHERE id = ?"
        )
        defer { sqlite3_finalize(statement) }
        try self.bind(normalizedCorrection, at: 1, to: statement)
        try self.bind(Self.normalizedForSearch(currentText), at: 2, to: statement)
        try self.bind(recordID.uuidString.lowercased(), at: 3, to: statement)
        try self.stepDone(statement)
        guard let updated = try self.record(id: recordID) else {
            throw HistoryStoreError.recordNotFound
        }
        return updated
    }

    func recordCorrectionEvent(_ event: HistoryCorrectionEvent) throws {
        guard try self.record(id: event.historyRecordID) != nil else {
            throw HistoryStoreError.recordNotFound
        }
        let statement = try self.prepare(
            """
            INSERT INTO correction_events (
                id, history_record_id, vocabulary_entry_id, wrong_text,
                intended_text, source_text_version, created_at, operation
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """
        )
        defer { sqlite3_finalize(statement) }
        try self.bind(event.id.uuidString.lowercased(), at: 1, to: statement)
        try self.bind(event.historyRecordID.uuidString.lowercased(), at: 2, to: statement)
        try self.bind(event.vocabularyEntryID.uuidString.lowercased(), at: 3, to: statement)
        try self.bind(event.wrongText, at: 4, to: statement)
        try self.bind(event.intendedText, at: 5, to: statement)
        try self.bind(event.sourceTextVersion, at: 6, to: statement)
        try self.bind(event.createdAt.timeIntervalSince1970, at: 7, to: statement)
        try self.bind(event.operation.rawValue, at: 8, to: statement)
        try self.stepDone(statement)
    }

    func correctionEvents(historyRecordID: UUID) throws -> [HistoryCorrectionEvent] {
        let statement = try self.prepare(
            """
            SELECT id, history_record_id, vocabulary_entry_id, wrong_text,
                   intended_text, source_text_version, created_at, operation
            FROM correction_events
            WHERE history_record_id = ?
            ORDER BY created_at, id
            """
        )
        defer { sqlite3_finalize(statement) }
        try self.bind(historyRecordID.uuidString.lowercased(), at: 1, to: statement)
        var events: [HistoryCorrectionEvent] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let id = self.uuidColumn(statement, index: 0),
                      let recordID = self.uuidColumn(statement, index: 1),
                      let entryID = self.uuidColumn(statement, index: 2),
                      let wrongText = self.stringColumn(statement, index: 3),
                      let intendedText = self.stringColumn(statement, index: 4),
                      let sourceVersion = self.stringColumn(statement, index: 5),
                      let operationText = self.stringColumn(statement, index: 7),
                      let operation = HistoryCorrectionOperation(rawValue: operationText) else {
                    throw HistoryStoreError.malformedDatabaseRecord
                }
                events.append(HistoryCorrectionEvent(
                    id: id,
                    historyRecordID: recordID,
                    vocabularyEntryID: entryID,
                    wrongText: wrongText,
                    intendedText: intendedText,
                    sourceTextVersion: sourceVersion,
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
                    operation: operation
                ))
            case SQLITE_DONE:
                return events
            default:
                throw self.lastDatabaseError()
            }
        }
    }

    func attachAudioFile(
        from sourceURL: URL,
        to recordID: UUID,
        fileExtension: String,
        createdAt: Date = Date()
    ) throws -> HistoryRecord {
        guard try self.record(id: recordID) != nil else {
            throw HistoryStoreError.recordNotFound
        }
        let normalizedExtension = try Self.validateAudioFileExtension(fileExtension)
        let values = try sourceURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw HistoryStoreError.invalidAudioFile
        }

        let destinationURL = self.audioFileURL(recordID: recordID, fileExtension: normalizedExtension)
        let stagingURL = self.audioDirectoryURL
            .appendingPathComponent(".\(UUID().uuidString).staging", isDirectory: false)
        do {
            try FileManager.default.copyItem(at: sourceURL, to: stagingURL)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: stagingURL.path
            )
            let attributes = try FileManager.default.attributesOfItem(atPath: stagingURL.path)
            let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            guard byteCount > 0 else {
                throw HistoryStoreError.invalidAudioFile
            }
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.moveItem(at: stagingURL, to: destinationURL)

            let statement = try self.prepare(
                """
                UPDATE history_records
                SET audio_extension = ?, audio_byte_count = ?, audio_created_at = ?
                WHERE id = ?
                """
            )
            defer { sqlite3_finalize(statement) }
            try self.bind(normalizedExtension, at: 1, to: statement)
            try self.bind(byteCount, at: 2, to: statement)
            try self.bind(createdAt.timeIntervalSince1970, at: 3, to: statement)
            try self.bind(recordID.uuidString.lowercased(), at: 4, to: statement)
            try self.stepDone(statement)
        } catch {
            try? FileManager.default.removeItem(at: stagingURL)
            throw error
        }

        guard let updated = try self.record(id: recordID) else {
            throw HistoryStoreError.recordNotFound
        }
        return updated
    }

    func audioURL(for recordID: UUID) throws -> URL? {
        guard let record = try self.record(id: recordID), let audio = record.audio else {
            return nil
        }
        let normalizedExtension = try Self.validateAudioFileExtension(audio.fileExtension)
        let url = self.audioFileURL(recordID: recordID, fileExtension: normalizedExtension)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    @discardableResult
    func delete(recordID: UUID) throws -> Bool {
        guard let record = try self.record(id: recordID) else {
            return false
        }
        let statement = try self.prepare("DELETE FROM history_records WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        try self.bind(recordID.uuidString.lowercased(), at: 1, to: statement)
        try self.stepDone(statement)

        if let audio = record.audio,
           let normalizedExtension = try? Self.validateAudioFileExtension(audio.fileExtension) {
            let url = self.audioFileURL(recordID: recordID, fileExtension: normalizedExtension)
            try? FileManager.default.removeItem(at: url)
        }
        return true
    }

    func deleteAll() throws -> HistoryPruneReport {
        try self.delete(records: self.allRecords())
    }

    func prune(
        retention: HistoryRetentionConfiguration,
        now: Date = Date()
    ) throws -> HistoryPruneReport {
        guard retention.policy != .off else {
            return HistoryPruneReport(deletedRecordCount: 0, removedAudioFileCount: 0)
        }
        let records = try self.allRecords()
        var IDsToDelete = Set<UUID>()
        if let maximumAge = retention.policy.maximumAge {
            let cutoff = now.addingTimeInterval(-maximumAge)
            for record in records where record.completedAt < cutoff {
                IDsToDelete.insert(record.id)
            }
        }
        let survivors = records.filter { !IDsToDelete.contains($0.id) }
        if survivors.count > retention.maximumRecordCount {
            for record in survivors.dropFirst(retention.maximumRecordCount) {
                IDsToDelete.insert(record.id)
            }
        }
        let recordsToDelete = records.filter { IDsToDelete.contains($0.id) }
        return try self.delete(records: recordsToDelete)
    }

    /// Applies the recording-retention policy independently from text History.
    /// Database references are cleared transactionally; any filesystem failure
    /// becomes an orphan that launch maintenance will reconcile safely.
    @discardableResult
    func pruneAudio(olderThan cutoff: Date) throws -> Int {
        let expired = try self.allRecords().filter { record in
            guard let audio = record.audio else { return false }
            return audio.createdAt < cutoff
        }
        guard !expired.isEmpty else { return 0 }

        try self.withTransaction {
            let statement = try self.prepare(
                """
                UPDATE history_records
                SET audio_extension = NULL, audio_byte_count = NULL, audio_created_at = NULL
                WHERE id = ?
                """
            )
            defer { sqlite3_finalize(statement) }
            for record in expired {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                try self.bind(record.id.uuidString.lowercased(), at: 1, to: statement)
                try self.stepDone(statement)
            }
        }

        for record in expired {
            guard let audio = record.audio,
                  let normalizedExtension = try? Self.validateAudioFileExtension(audio.fileExtension) else {
                continue
            }
            try? FileManager.default.removeItem(
                at: self.audioFileURL(recordID: record.id, fileExtension: normalizedExtension)
            )
        }
        return expired.count
    }

    func reconcileAudioFiles() throws -> HistoryAudioReconciliationReport {
        let records = try self.allRecords()
        var referencedNames = Set<String>()
        var missingIDs: [UUID] = []
        for record in records {
            guard let audio = record.audio,
                  let normalizedExtension = try? Self.validateAudioFileExtension(audio.fileExtension) else {
                if record.audio != nil { missingIDs.append(record.id) }
                continue
            }
            let url = self.audioFileURL(recordID: record.id, fileExtension: normalizedExtension)
            referencedNames.insert(url.lastPathComponent)
            if !FileManager.default.fileExists(atPath: url.path) {
                missingIDs.append(record.id)
            }
        }

        if !missingIDs.isEmpty {
            try self.withTransaction {
                let statement = try self.prepare(
                    """
                    UPDATE history_records
                    SET audio_extension = NULL, audio_byte_count = NULL, audio_created_at = NULL
                    WHERE id = ?
                    """
                )
                defer { sqlite3_finalize(statement) }
                for id in missingIDs {
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                    try self.bind(id.uuidString.lowercased(), at: 1, to: statement)
                    try self.stepDone(statement)
                }
            }
        }

        var removedOrphans = 0
        let contents = try FileManager.default.contentsOfDirectory(
            at: self.audioDirectoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []
        )
        for url in contents where !referencedNames.contains(url.lastPathComponent) {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isRegularFile == true || values?.isSymbolicLink == true else {
                continue
            }
            do {
                try FileManager.default.removeItem(at: url)
                removedOrphans += 1
            } catch {
                continue
            }
        }
        return HistoryAudioReconciliationReport(
            removedOrphanCount: removedOrphans,
            clearedMissingReferenceCount: missingIDs.count
        )
    }

    private func record(sessionID: UUID) throws -> HistoryRecord? {
        try self.fetchOne(
            sql: "SELECT \(Self.recordColumns) FROM history_records WHERE session_id = ? LIMIT 1",
            value: sessionID.uuidString.lowercased()
        )
    }

    private func allRecords() throws -> [HistoryRecord] {
        let statement = try self.prepare(
            "SELECT \(Self.recordColumns) FROM history_records ORDER BY completed_at DESC, id DESC"
        )
        defer { sqlite3_finalize(statement) }
        var records: [HistoryRecord] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                records.append(try self.decodeRecord(statement))
            case SQLITE_DONE:
                return records
            default:
                throw self.lastDatabaseError()
            }
        }
    }

    private func delete(records: [HistoryRecord]) throws -> HistoryPruneReport {
        guard !records.isEmpty else {
            return HistoryPruneReport(deletedRecordCount: 0, removedAudioFileCount: 0)
        }
        try self.withTransaction {
            let statement = try self.prepare("DELETE FROM history_records WHERE id = ?")
            defer { sqlite3_finalize(statement) }
            for record in records {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                try self.bind(record.id.uuidString.lowercased(), at: 1, to: statement)
                try self.stepDone(statement)
            }
        }
        var removedAudioCount = 0
        for record in records {
            guard let audio = record.audio,
                  let normalizedExtension = try? Self.validateAudioFileExtension(audio.fileExtension) else {
                continue
            }
            let url = self.audioFileURL(recordID: record.id, fileExtension: normalizedExtension)
            do {
                try FileManager.default.removeItem(at: url)
                removedAudioCount += 1
            } catch CocoaError.fileNoSuchFile {
                continue
            } catch {
                continue
            }
        }
        return HistoryPruneReport(
            deletedRecordCount: records.count,
            removedAudioFileCount: removedAudioCount
        )
    }

    private func fetchOne(sql: String, value: String) throws -> HistoryRecord? {
        let statement = try self.prepare(sql)
        defer { sqlite3_finalize(statement) }
        try self.bind(value, at: 1, to: statement)
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return try self.decodeRecord(statement)
        case SQLITE_DONE:
            return nil
        default:
            throw self.lastDatabaseError()
        }
    }

    private func decodeRecord(_ statement: OpaquePointer?) throws -> HistoryRecord {
        guard
            let id = self.uuidColumn(statement, index: 0),
            let sessionID = self.uuidColumn(statement, index: 1),
            let provider = self.stringColumn(statement, index: 4),
            let modelID = self.stringColumn(statement, index: 5),
            let modelRevision = self.stringColumn(statement, index: 6),
            let captureMode = self.stringColumn(statement, index: 9),
            let rawASRText = self.stringColumn(statement, index: 12),
            let cleanedText = self.stringColumn(statement, index: 13),
            let deliveredText = self.stringColumn(statement, index: 14)
        else {
            throw HistoryStoreError.malformedDatabaseRecord
        }
        let insertionSucceeded: Bool?
        if sqlite3_column_type(statement, 18) == SQLITE_NULL {
            insertionSucceeded = nil
        } else {
            insertionSucceeded = sqlite3_column_int(statement, 18) != 0
        }
        let audio: HistoryAudioMetadata?
        if let fileExtension = self.stringColumn(statement, index: 19),
           sqlite3_column_type(statement, 20) != SQLITE_NULL,
           sqlite3_column_type(statement, 21) != SQLITE_NULL {
            audio = HistoryAudioMetadata(
                fileExtension: fileExtension,
                byteCount: sqlite3_column_int64(statement, 20),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 21))
            )
        } else {
            audio = nil
        }
        return HistoryRecord(
            id: id,
            sessionID: sessionID,
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
            completedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
            provider: provider,
            modelID: modelID,
            modelRevision: modelRevision,
            requestedLanguage: self.stringColumn(statement, index: 7),
            detectedLanguage: self.stringColumn(statement, index: 8),
            captureMode: captureMode,
            sourceBundleID: self.stringColumn(statement, index: 10),
            sourceDisplayName: self.stringColumn(statement, index: 11),
            rawASRText: rawASRText,
            cleanedText: cleanedText,
            deliveredText: deliveredText,
            correctedText: self.stringColumn(statement, index: 15),
            durationMilliseconds: sqlite3_column_int64(statement, 16),
            inferenceMilliseconds: sqlite3_column_int64(statement, 17),
            insertionSucceeded: insertionSucceeded,
            audio: audio,
            schemaVersion: Int(sqlite3_column_int(statement, 22))
        )
    }

    private func audioFileURL(recordID: UUID, fileExtension: String) -> URL {
        self.audioDirectoryURL.appendingPathComponent(
            "\(recordID.uuidString.lowercased()).\(fileExtension)",
            isDirectory: false
        )
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        let database = try self.requireDatabase()
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard result == SQLITE_OK else {
            throw HistoryStoreError.databaseFailure(code: result)
        }
        return statement
    }

    private func stepDone(_ statement: OpaquePointer?) throws {
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else {
            throw HistoryStoreError.databaseFailure(code: result)
        }
    }

    private func bind(_ value: SQLiteBinding, at index: Int32, to statement: OpaquePointer?) throws {
        let result: Int32
        switch value {
        case let .text(text):
            result = sqlite3_bind_text(statement, index, text, -1, Self.sqliteTransient)
        case let .integer(integer):
            result = sqlite3_bind_int64(statement, index, integer)
        case let .real(real):
            result = sqlite3_bind_double(statement, index, real)
        case .null:
            result = sqlite3_bind_null(statement, index)
        }
        guard result == SQLITE_OK else {
            throw HistoryStoreError.databaseFailure(code: result)
        }
    }

    private func bind(_ value: String, at index: Int32, to statement: OpaquePointer?) throws {
        try self.bind(.text(value), at: index, to: statement)
    }

    private func bind(_ value: String?, at index: Int32, to statement: OpaquePointer?) throws {
        try self.bind(value.map(SQLiteBinding.text) ?? .null, at: index, to: statement)
    }

    private func bind(_ value: Double, at index: Int32, to statement: OpaquePointer?) throws {
        try self.bind(.real(value), at: index, to: statement)
    }

    private func bind(_ value: Int64, at index: Int32, to statement: OpaquePointer?) throws {
        try self.bind(.integer(value), at: index, to: statement)
    }

    private func bind(_ value: Bool?, at index: Int32, to statement: OpaquePointer?) throws {
        try self.bind(value.map { .integer($0 ? 1 : 0) } ?? .null, at: index, to: statement)
    }

    private func requireDatabase() throws -> OpaquePointer {
        self.connection.handle
    }

    private func lastDatabaseError() -> HistoryStoreError {
        HistoryStoreError.databaseFailure(code: sqlite3_errcode(self.connection.handle))
    }

    private func stringColumn(_ statement: OpaquePointer?, index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let characters = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: characters)
    }

    private func uuidColumn(_ statement: OpaquePointer?, index: Int32) -> UUID? {
        self.stringColumn(statement, index: index).flatMap(UUID.init(uuidString:))
    }

    private func withTransaction<T>(_ operation: () throws -> T) throws -> T {
        try self.execute("BEGIN IMMEDIATE")
        do {
            let result = try operation()
            try self.execute("COMMIT")
            return result
        } catch {
            try? self.execute("ROLLBACK")
            throw error
        }
    }

    private func execute(_ sql: String) throws {
        try Self.execute(try self.requireDatabase(), sql: sql)
    }

    private static func configure(_ database: OpaquePointer) throws {
        try self.execute(database, sql: "PRAGMA journal_mode = WAL")
        try self.execute(database, sql: "PRAGMA synchronous = NORMAL")
        try self.execute(database, sql: "PRAGMA foreign_keys = ON")
    }

    private static func migrate(_ database: OpaquePointer) throws {
        let version = try self.userVersion(database)
        guard version <= self.currentDatabaseSchemaVersion else {
            throw HistoryStoreError.unsupportedDatabaseVersion(version)
        }
        if version == 0 {
            try self.execute(database, sql: "BEGIN IMMEDIATE")
            do {
            try self.execute(
                database,
                sql: """
                CREATE TABLE history_records (
                    id TEXT PRIMARY KEY NOT NULL,
                    session_id TEXT NOT NULL UNIQUE,
                    created_at REAL NOT NULL,
                    completed_at REAL NOT NULL,
                    provider TEXT NOT NULL,
                    model_id TEXT NOT NULL,
                    model_revision TEXT NOT NULL,
                    requested_language TEXT,
                    detected_language TEXT,
                    capture_mode TEXT NOT NULL,
                    source_bundle_id TEXT,
                    source_display_name TEXT,
                    raw_asr_text TEXT NOT NULL,
                    cleaned_text TEXT NOT NULL,
                    delivered_text TEXT NOT NULL,
                    corrected_text TEXT,
                    duration_ms INTEGER NOT NULL,
                    inference_ms INTEGER NOT NULL,
                    insertion_succeeded INTEGER,
                    audio_extension TEXT,
                    audio_byte_count INTEGER,
                    audio_created_at REAL,
                    schema_version INTEGER NOT NULL,
                    search_text TEXT NOT NULL
                )
                """
            )
            try self.execute(
                database,
                sql: "CREATE INDEX history_records_completed_at ON history_records(completed_at DESC)"
            )
            try self.execute(
                database,
                sql: "CREATE INDEX history_records_provider ON history_records(provider)"
            )
            try self.execute(
                database,
                sql: "CREATE INDEX history_records_language ON history_records(detected_language, requested_language)"
            )
                try self.execute(database, sql: "PRAGMA user_version = 1")
                try self.execute(database, sql: "COMMIT")
            } catch {
                try? self.execute(database, sql: "ROLLBACK")
                throw error
            }
        }

        if try self.userVersion(database) < 2 {
            try self.execute(database, sql: "BEGIN IMMEDIATE")
            do {
                try self.execute(
                    database,
                    sql: """
                    CREATE TABLE correction_events (
                        id TEXT PRIMARY KEY NOT NULL,
                        history_record_id TEXT NOT NULL REFERENCES history_records(id) ON DELETE CASCADE,
                        vocabulary_entry_id TEXT NOT NULL,
                        wrong_text TEXT NOT NULL,
                        intended_text TEXT NOT NULL,
                        source_text_version TEXT NOT NULL,
                        created_at REAL NOT NULL,
                        operation TEXT NOT NULL
                    )
                    """
                )
                try self.execute(
                    database,
                    sql: "CREATE INDEX correction_events_history ON correction_events(history_record_id, created_at)"
                )
                try self.execute(database, sql: "PRAGMA user_version = 2")
                try self.execute(database, sql: "COMMIT")
            } catch {
                try? self.execute(database, sql: "ROLLBACK")
                throw error
            }
        }
    }

    private static func userVersion(_ database: OpaquePointer) throws -> Int {
        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil)
        guard prepareResult == SQLITE_OK else {
            throw HistoryStoreError.databaseFailure(code: prepareResult)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw HistoryStoreError.databaseFailure(code: sqlite3_errcode(database))
        }
        return Int(sqlite3_column_int(statement, 0))
    }

    private static func execute(_ database: OpaquePointer, sql: String) throws {
        let result = sqlite3_exec(database, sql, nil, nil, nil)
        guard result == SQLITE_OK else {
            throw HistoryStoreError.databaseFailure(code: result)
        }
    }

    private static func createPrivateDirectory(at url: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: url.path
        )
    }

    private static func validateAudioFileExtension(_ value: String) throws -> String {
        let normalized = value.lowercased()
        guard !normalized.isEmpty,
              normalized.count <= 8,
              normalized.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0) && $0.isASCII
              }) else {
            throw HistoryStoreError.invalidAudioFileExtension
        }
        return normalized
    }

    private static func normalizedForSearch(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    private static func escapeLike(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

private enum SQLiteBinding {
    case text(String)
    case integer(Int64)
    case real(Double)
    case null
}

private final class HistorySQLiteConnection: @unchecked Sendable {
    let handle: OpaquePointer

    init(handle: OpaquePointer) {
        self.handle = handle
    }

    deinit {
        sqlite3_close(self.handle)
    }
}
