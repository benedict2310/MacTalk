import Foundation

enum HistoryRetentionPolicy: String, CaseIterable, Codable, Sendable {
    case off
    case oneDay
    case sevenDays
    case thirtyDays
    case ninetyDays
    case forever

    var isHistoryEnabled: Bool {
        self != .off
    }

    var maximumAge: TimeInterval? {
        switch self {
        case .off, .forever:
            return nil
        case .oneDay:
            return 86_400
        case .sevenDays:
            return 7 * 86_400
        case .thirtyDays:
            return 30 * 86_400
        case .ninetyDays:
            return 90 * 86_400
        }
    }
}
struct HistoryRetentionConfiguration: Sendable, Equatable {
    static let defaultConfiguration = HistoryRetentionConfiguration(
        policy: .thirtyDays,
        maximumRecordCount: 500
    )

    let policy: HistoryRetentionPolicy
    let maximumRecordCount: Int

    init(policy: HistoryRetentionPolicy, maximumRecordCount: Int) {
        self.policy = policy
        self.maximumRecordCount = max(0, maximumRecordCount)
    }
}

struct HistoryPruneReport: Sendable, Equatable {
    let deletedRecordCount: Int
    let removedAudioFileCount: Int
}

struct HistoryAudioReconciliationReport: Sendable, Equatable {
    let removedOrphanCount: Int
    let clearedMissingReferenceCount: Int
}

struct HistorySearchQuery: Sendable, Equatable {
    let text: String
    let provider: String?
    let language: String?
    let sourceBundleID: String?
    let isCorrected: Bool?
    let limit: Int
    let offset: Int

    init(
        text: String = "",
        provider: String? = nil,
        language: String? = nil,
        sourceBundleID: String? = nil,
        isCorrected: Bool? = nil,
        limit: Int = 100,
        offset: Int = 0
    ) {
        self.text = text
        self.provider = provider
        self.language = language
        self.sourceBundleID = sourceBundleID
        self.isCorrected = isCorrected
        self.limit = min(max(1, limit), 200)
        self.offset = max(0, offset)
    }
}
