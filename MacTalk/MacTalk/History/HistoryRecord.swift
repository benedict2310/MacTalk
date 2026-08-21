import Foundation

struct HistoryRecord: Identifiable, Sendable, Equatable {
    static let currentSchemaVersion = 1

    let id: UUID
    let sessionID: UUID
    let createdAt: Date
    let completedAt: Date
    let provider: String
    let modelID: String
    let modelRevision: String
    let requestedLanguage: String?
    let detectedLanguage: String?
    let captureMode: String
    let sourceBundleID: String?
    let sourceDisplayName: String?
    let rawASRText: String
    let cleanedText: String
    let deliveredText: String
    let correctedText: String?
    let durationMilliseconds: Int64
    let inferenceMilliseconds: Int64
    let insertionSucceeded: Bool?
    let audio: HistoryAudioMetadata?
    let schemaVersion: Int

    var currentText: String {
        self.correctedText ?? self.deliveredText
    }

    var hasRetainedAudio: Bool {
        self.audio != nil
    }
}

struct HistoryAudioMetadata: Sendable, Equatable {
    let fileExtension: String
    let byteCount: Int64
    let createdAt: Date
}

enum HistoryTerminalOutcome: Sendable, Equatable {
    case completed
    case cancelled
}

struct HistoryTerminalResult: Sendable, Equatable {
    let recordID: UUID
    let sessionID: UUID
    let createdAt: Date
    let completedAt: Date
    let provider: String
    let modelID: String
    let modelRevision: String
    let requestedLanguage: String?
    let detectedLanguage: String?
    let captureMode: String
    let sourceBundleID: String?
    let sourceDisplayName: String?
    let rawASRText: String
    let cleanedText: String
    let deliveredText: String
    let durationMilliseconds: Int64
    let inferenceMilliseconds: Int64
    let insertionSucceeded: Bool?
    let outcome: HistoryTerminalOutcome

    init(
        recordID: UUID = UUID(),
        sessionID: UUID,
        createdAt: Date,
        completedAt: Date,
        provider: String,
        modelID: String,
        modelRevision: String,
        requestedLanguage: String?,
        detectedLanguage: String?,
        captureMode: String,
        sourceBundleID: String?,
        sourceDisplayName: String?,
        rawASRText: String,
        cleanedText: String,
        deliveredText: String,
        durationMilliseconds: Int64,
        inferenceMilliseconds: Int64,
        insertionSucceeded: Bool?,
        outcome: HistoryTerminalOutcome
    ) {
        self.recordID = recordID
        self.sessionID = sessionID
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.provider = provider
        self.modelID = modelID
        self.modelRevision = modelRevision
        self.requestedLanguage = requestedLanguage
        self.detectedLanguage = detectedLanguage
        self.captureMode = captureMode
        self.sourceBundleID = sourceBundleID
        self.sourceDisplayName = sourceDisplayName
        self.rawASRText = rawASRText
        self.cleanedText = cleanedText
        self.deliveredText = deliveredText
        self.durationMilliseconds = durationMilliseconds
        self.inferenceMilliseconds = inferenceMilliseconds
        self.insertionSucceeded = insertionSucceeded
        self.outcome = outcome
    }
}

enum HistoryPersistenceSkipReason: Sendable, Equatable {
    case cancelled
    case emptyTranscript
    case historyDisabled
}

enum HistoryPersistenceOutcome: Sendable, Equatable {
    case inserted(HistoryRecord)
    case alreadyRecorded(HistoryRecord)
    case skipped(HistoryPersistenceSkipReason)
}

enum HistoryCorrectionOperation: String, Sendable, Equatable {
    case created
    case updated
}

struct HistoryCorrectionEvent: Identifiable, Sendable, Equatable {
    let id: UUID
    let historyRecordID: UUID
    let vocabularyEntryID: UUID
    let wrongText: String
    let intendedText: String
    let sourceTextVersion: String
    let createdAt: Date
    let operation: HistoryCorrectionOperation

    init(
        id: UUID = UUID(),
        historyRecordID: UUID,
        vocabularyEntryID: UUID,
        wrongText: String,
        intendedText: String,
        sourceTextVersion: String,
        createdAt: Date,
        operation: HistoryCorrectionOperation
    ) {
        self.id = id
        self.historyRecordID = historyRecordID
        self.vocabularyEntryID = vocabularyEntryID
        self.wrongText = wrongText
        self.intendedText = intendedText
        self.sourceTextVersion = sourceTextVersion
        self.createdAt = createdAt
        self.operation = operation
    }
}

enum HistoryExportCodec {
    static func plainText(_ record: HistoryRecord) -> String {
        record.currentText
    }

    static func json(_ record: HistoryRecord) throws -> Data {
        let formatter = ISO8601DateFormatter()
        var object: [String: Any] = [
            "schemaVersion": record.schemaVersion,
            "id": record.id.uuidString.lowercased(),
            "sessionID": record.sessionID.uuidString.lowercased(),
            "createdAt": formatter.string(from: record.createdAt),
            "completedAt": formatter.string(from: record.completedAt),
            "provider": record.provider,
            "modelID": record.modelID,
            "modelRevision": record.modelRevision,
            "captureMode": record.captureMode,
            "rawASRText": record.rawASRText,
            "cleanedText": record.cleanedText,
            "deliveredText": record.deliveredText,
            "currentText": record.currentText,
            "durationMilliseconds": record.durationMilliseconds,
            "inferenceMilliseconds": record.inferenceMilliseconds,
            "hasRetainedAudio": record.hasRetainedAudio,
        ]
        if let value = record.correctedText { object["correctedText"] = value }
        if let value = record.requestedLanguage { object["requestedLanguage"] = value }
        if let value = record.detectedLanguage { object["detectedLanguage"] = value }
        if let value = record.sourceBundleID { object["sourceBundleID"] = value }
        if let value = record.sourceDisplayName { object["sourceDisplayName"] = value }
        if let value = record.insertionSucceeded { object["insertionSucceeded"] = value }
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }
}
