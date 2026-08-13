import AVFoundation
import CryptoKit
import Foundation

struct MacTeachSessionSnapshot: Sendable, Equatable {
    let id: UUID
    let settings: SettingsSnapshot
    let target: ApplicationIdentity?
    let vocabulary: PersonalVocabularySnapshot
    let matchContext: VocabularyMatchContext
    let requestContext: ASRRequestContext
    let startedAt: Date
}

struct MacTeachDeliveredTranscript: Sendable, Equatable {
    let recordID: UUID
    let completedAt: Date
    let terminal: TerminalTranscription
    let text: String
    let replacementEdits: [VocabularyReplacementEdit]
}

@MainActor
protocol MacTeachCoordinating: AnyObject {
    func captureSession(settings: SettingsSnapshot, target: ApplicationIdentity?) async -> MacTeachSessionSnapshot
    func deliver(_ terminal: TerminalTranscription, session: MacTeachSessionSnapshot) -> MacTeachDeliveredTranscript
    func persist(
        _ delivered: MacTeachDeliveredTranscript,
        session: MacTeachSessionSnapshot,
        selection: EngineSelection,
        insertionSucceeded: Bool?
    ) async throws -> HistoryPersistenceOutcome
}

extension Notification.Name {
    static let macTalkHistoryDidChange = Notification.Name("MacTalkHistoryDidChange")
}

extension HistoryPersistenceOutcome {
    var diagnosticOutcome: PipelineHistoryPersistenceOutcome {
        switch self {
        case .inserted: return .inserted
        case .alreadyRecorded: return .alreadyRecorded
        case .skipped(.historyDisabled): return .skippedHistoryDisabled
        case .skipped(.cancelled): return .skippedCancelled
        case .skipped(.emptyTranscript): return .skippedEmptyTranscript
        }
    }
}

@MainActor
final class MacTeachCoordinator: MacTeachCoordinating {
    private struct RecentAudio {
        let samples: [Float]
        let expiresAt: Date
    }

    let historyStore: HistoryStore
    let vocabularyStore: PersonalVocabularyStore

    private let replacementEngine = VocabularyReplacementEngine()
    private let hintSelector = VocabularyHintSelector()
    private let now: @MainActor () -> Date
    private var recentAudio: [UUID: RecentAudio] = [:]
    private nonisolated(unsafe) var settingsObserver: NSObjectProtocol?

    init(
        historyStore: HistoryStore,
        vocabularyStore: PersonalVocabularyStore,
        clock: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.historyStore = historyStore
        self.vocabularyStore = vocabularyStore
        self.now = clock
    }

    deinit {
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
    }

    static func makeDefault() throws -> MacTeachCoordinator {
        let coordinator = MacTeachCoordinator(
            historyStore: try HistoryStore.makeDefault(),
            vocabularyStore: try PersonalVocabularyStore.makeDefault()
        )
        coordinator.startMaintenance(settingsStore: .shared)
        return coordinator
    }

    func captureSession(
        settings: SettingsSnapshot,
        target: ApplicationIdentity?
    ) async -> MacTeachSessionSnapshot {
        // The immediately previous recording is the only raw recording retained
        // in memory. Persisted recordings have their own independently bounded policy.
        recentAudio.removeAll()
        let vocabulary: PersonalVocabularySnapshot
        if settings.macTeach.personalVocabularyEnabled,
           let stored = try? await vocabularyStore.snapshot() {
            vocabulary = stored
        } else {
            vocabulary = PersonalVocabularySnapshot(entries: [])
        }
        let matchContext = VocabularyMatchContext(
            language: settings.language,
            applicationBundleID: target?.bundleIdentifier
        )
        let selection = hintSelector.select(
            from: vocabulary,
            context: matchContext,
            budget: VocabularyHintBudget(maximumCount: 64, maximumTokenCost: 160)
        )
        let snapshotID = UUID()
        let hints = selection.hints.map { hint in
            ASRVocabularyHint(
                id: hint.entryID,
                writtenForm: hint.writtenForm,
                spokenForm: hint.spokenForm,
                priority: hint.priority == .important ? .high : .normal
            )
        }
        return MacTeachSessionSnapshot(
            id: snapshotID,
            settings: settings,
            target: target,
            vocabulary: vocabulary,
            matchContext: matchContext,
            requestContext: ASRRequestContext(
                language: settings.language,
                vocabularyHints: hints,
                vocabularySnapshotID: snapshotID
            ),
            startedAt: now()
        )
    }

    func deliver(
        _ terminal: TerminalTranscription,
        session: MacTeachSessionSnapshot
    ) -> MacTeachDeliveredTranscript {
        let replacement: VocabularyReplacementResult
        if session.settings.macTeach.personalVocabularyEnabled {
            replacement = replacementEngine.apply(
                to: terminal.cleanedText,
                snapshot: session.vocabulary,
                context: session.matchContext
            )
        } else {
            replacement = VocabularyReplacementResult(text: terminal.cleanedText, edits: [])
        }
        return MacTeachDeliveredTranscript(
            recordID: UUID(),
            completedAt: now(),
            terminal: terminal,
            text: replacement.text,
            replacementEdits: replacement.edits
        )
    }

    func persist(
        _ delivered: MacTeachDeliveredTranscript,
        session: MacTeachSessionSnapshot,
        selection: EngineSelection,
        insertionSucceeded: Bool?
    ) async throws -> HistoryPersistenceOutcome {
        self.pruneExpiredRecentAudio()
        if !delivered.terminal.audioSamples.isEmpty {
            recentAudio[delivered.recordID] = RecentAudio(
                samples: delivered.terminal.audioSamples,
                expiresAt: now().addingTimeInterval(15 * 60)
            )
        }

        let outcome = try await historyStore.recordTerminalResult(
            HistoryTerminalResult(
                recordID: delivered.recordID,
                sessionID: delivered.terminal.sessionID,
                createdAt: session.startedAt,
                completedAt: delivered.completedAt,
                provider: delivered.terminal.provider.rawValue,
                modelID: selection.modelID,
                modelRevision: selection.revision,
                requestedLanguage: delivered.terminal.requestedLanguage,
                detectedLanguage: nil,
                captureMode: delivered.terminal.captureMode.rawValue,
                sourceBundleID: session.target?.bundleIdentifier,
                sourceDisplayName: session.target?.displayName,
                rawASRText: delivered.terminal.rawASRText,
                cleanedText: delivered.terminal.cleanedText,
                deliveredText: delivered.text,
                durationMilliseconds: delivered.terminal.durationMilliseconds,
                inferenceMilliseconds: 0,
                insertionSucceeded: insertionSucceeded,
                outcome: .completed
            ),
            historyEnabled: session.settings.macTeach.textHistoryEnabled
        )

        if case .inserted = outcome, !delivered.replacementEdits.isEmpty {
            try? await vocabularyStore.recordApplications(
                entryIDs: Set(delivered.replacementEdits.map(\.entryID)),
                appliedAt: delivered.completedAt
            )
        }

        let record: HistoryRecord
        switch outcome {
        case let .inserted(inserted), let .alreadyRecorded(inserted):
            record = inserted
        case .skipped:
            return outcome
        }
        NotificationCenter.default.post(name: .macTalkHistoryDidChange, object: self)
        if session.settings.macTeach.keepRecordings,
           !record.hasRetainedAudio,
           !delivered.terminal.audioSamples.isEmpty {
            let temporaryURL = try await Task.detached(priority: .utility) {
                try Self.writeTemporaryAudio(delivered.terminal.audioSamples)
            }.value
            defer { try? FileManager.default.removeItem(at: temporaryURL) }
            _ = try await historyStore.attachAudioFile(
                from: temporaryURL,
                to: record.id,
                fileExtension: "caf"
            )
        }

        try? await self.applyRetention(settings: session.settings, timestamp: delivered.completedAt)
        return outcome
    }

    func teach(
        historyRecordID: UUID,
        wrongForm: String,
        writtenForm: String,
        spokenForm: String?,
        language: String?,
        applicationBundleIDs: Set<String>,
        recognitionHintEnabled: Bool? = nil,
        replacementEnabled: Bool? = nil,
        priority: PersonalVocabularyPriority? = nil
    ) async throws -> PersonalVocabularyEntry {
        guard let history = try await historyStore.record(id: historyRecordID) else {
            throw HistoryStoreError.recordNotFound
        }
        let existingEntries = try await vocabularyStore.entries()
        let normalizedWritten = VocabularyNormalization.text(writtenForm)
        let existing = existingEntries.first {
            VocabularyNormalization.text($0.writtenForm) == normalizedWritten
                && VocabularyNormalization.language($0.language) == VocabularyNormalization.language(language)
                && $0.applicationBundleIDs == applicationBundleIDs
        }
        let wrong = PersonalVocabularyWrongForm(text: wrongForm)
        let timestamp = now()
        let entry: PersonalVocabularyEntry
        if let existing {
            let alreadyKnown = existing.wrongForms.contains {
                VocabularyNormalization.text($0.text) == VocabularyNormalization.text(wrongForm)
            }
            entry = PersonalVocabularyEntry(
                id: existing.id,
                writtenForm: writtenForm,
                spokenForm: spokenForm ?? existing.spokenForm,
                wrongForms: alreadyKnown ? existing.wrongForms : existing.wrongForms + [wrong],
                language: language,
                applicationBundleIDs: applicationBundleIDs,
                priority: priority ?? existing.priority,
                recognitionHintEnabled: recognitionHintEnabled ?? existing.recognitionHintEnabled,
                replacementEnabled: replacementEnabled ?? existing.replacementEnabled,
                isEnabled: true,
                source: .correction,
                sourceHistoryRecordID: historyRecordID,
                createdAt: existing.createdAt,
                updatedAt: timestamp,
                applicationCount: existing.applicationCount,
                correctionCount: existing.correctionCount + 1,
                lastAppliedAt: existing.lastAppliedAt
            )
        } else {
            entry = PersonalVocabularyEntry(
                writtenForm: writtenForm,
                spokenForm: spokenForm,
                wrongForms: [wrong],
                language: language,
                applicationBundleIDs: applicationBundleIDs,
                priority: priority ?? .normal,
                recognitionHintEnabled: recognitionHintEnabled ?? true,
                replacementEnabled: replacementEnabled ?? true,
                source: .correction,
                sourceHistoryRecordID: historyRecordID,
                createdAt: timestamp,
                updatedAt: timestamp,
                correctionCount: 1
            )
        }
        let saved = try await vocabularyStore.save(entry)
        let updatedSnapshot = try await vocabularyStore.snapshot()
        let replacement = replacementEngine.apply(
            to: history.cleanedText,
            snapshot: updatedSnapshot,
            context: VocabularyMatchContext(
                language: history.detectedLanguage ?? history.requestedLanguage,
                applicationBundleID: history.sourceBundleID
            )
        )
        _ = try await historyStore.setCorrectedText(replacement.text, for: historyRecordID)
        let sourceTextVersion = SHA256.hash(data: Data(history.cleanedText.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        try await historyStore.recordCorrectionEvent(HistoryCorrectionEvent(
            historyRecordID: historyRecordID,
            vocabularyEntryID: saved.id,
            wrongText: wrongForm,
            intendedText: writtenForm,
            sourceTextVersion: sourceTextVersion,
            createdAt: timestamp,
            operation: existing == nil ? .created : .updated
        ))
        return saved
    }

    func historyRecords(
        searchText: String = "",
        provider: String? = nil,
        language: String? = nil,
        sourceBundleID: String? = nil,
        isCorrected: Bool? = nil
    ) async throws -> [HistoryRecord] {
        try await historyStore.search(HistorySearchQuery(
            text: searchText,
            provider: provider,
            language: language,
            sourceBundleID: sourceBundleID,
            isCorrected: isCorrected
        ))
    }

    func vocabularyEntries() async throws -> [PersonalVocabularyEntry] {
        try await vocabularyStore.entries()
    }

    func correctionEvents(for historyRecordID: UUID) async throws -> [HistoryCorrectionEvent] {
        try await historyStore.correctionEvents(historyRecordID: historyRecordID)
    }

    func saveVocabularyEntry(_ entry: PersonalVocabularyEntry) async throws {
        _ = try await vocabularyStore.save(entry)
    }

    func importVocabularyEntries(_ entries: [PersonalVocabularyEntry]) async throws {
        _ = try await vocabularyStore.saveAll(entries)
    }

    func setVocabularyEntryEnabled(_ enabled: Bool, id: UUID) async throws {
        _ = try await vocabularyStore.setEnabled(enabled, id: id)
    }

    func deleteVocabularyEntry(id: UUID) async throws {
        try await vocabularyStore.delete(id: id)
    }

    func deleteAllVocabulary() async throws {
        _ = try await vocabularyStore.deleteAll()
    }

    func deleteHistoryRecord(id: UUID) async throws {
        _ = try await historyStore.delete(recordID: id)
        recentAudio[id] = nil
    }

    func deleteAllHistory() async throws {
        _ = try await historyStore.deleteAll()
        recentAudio.removeAll()
    }

    func recentAudioSamples(for recordID: UUID) -> [Float]? {
        self.pruneExpiredRecentAudio()
        return recentAudio[recordID]?.samples
    }

    func performMaintenance(settings: SettingsSnapshot) async throws {
        _ = try await historyStore.reconcileAudioFiles()
        try await self.applyRetention(settings: settings, timestamp: now())
    }

    private func startMaintenance(settingsStore: AppSettings) {
        Task { @MainActor [weak self] in
            try? await self?.performMaintenance(settings: settingsStore.snapshot)
        }
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .settingsDidChange,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let settings = notification.object as? SettingsSnapshot else { return }
            Task { @MainActor [weak self] in
                try? await self?.performMaintenance(settings: settings)
            }
        }
    }

    private func applyRetention(settings: SettingsSnapshot, timestamp: Date) async throws {
        let retention = HistoryRetentionConfiguration(
            policy: Self.retentionPolicy(
                enabled: settings.macTeach.textHistoryEnabled,
                days: settings.macTeach.textRetentionDays
            ),
            maximumRecordCount: settings.macTeach.maximumTextRecords
        )
        _ = try await historyStore.prune(retention: retention, now: timestamp)
        let audioCutoff = timestamp.addingTimeInterval(
            -TimeInterval(max(1, settings.macTeach.audioRetentionDays)) * 86_400
        )
        _ = try await historyStore.pruneAudio(olderThan: audioCutoff)
    }

    private func pruneExpiredRecentAudio() {
        let timestamp = now()
        recentAudio = recentAudio.filter { $0.value.expiresAt > timestamp }
    }

    private nonisolated static func retentionPolicy(enabled: Bool, days: Int?) -> HistoryRetentionPolicy {
        guard enabled else { return .off }
        switch days {
        case 1: return .oneDay
        case 7: return .sevenDays
        case 30: return .thirtyDays
        case 90: return .ninetyDays
        case nil: return .forever
        default: return .thirtyDays
        }
    }

    private nonisolated static func writeTemporaryAudio(_ samples: [Float]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacTalk-History-\(UUID().uuidString).caf")
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ),
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ),
        let channel = buffer.floatChannelData?[0] else {
            throw HistoryStoreError.invalidAudioFile
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            guard let baseAddress = source.baseAddress else { return }
            channel.update(from: baseAddress, count: samples.count)
        }
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try file.write(from: buffer)
        return url
    }
}
