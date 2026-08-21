//
//  AppSettings.swift
//  MacTalk
//
//  Authoritative, thread-safe application settings.
//

import Foundation
import os

enum SettingsCaptureMode: String, CaseIterable, Codable, Sendable {
    case micOnly
    case micPlusAppAudio
}

struct MacTeachSettingsSnapshot: Equatable, Sendable {
    var textHistoryEnabled: Bool
    /// Nil represents “Forever”.
    var textRetentionDays: Int?
    var maximumTextRecords: Int
    var keepRecordings: Bool
    var audioRetentionDays: Int
    var personalVocabularyEnabled: Bool
    var suggestCorrections: Bool

    static let defaults = MacTeachSettingsSnapshot(
        textHistoryEnabled: true,
        textRetentionDays: 30,
        maximumTextRecords: 500,
        keepRecordings: false,
        audioRetentionDays: 7,
        personalVocabularyEnabled: true,
        suggestCorrections: true
    )
}

struct SettingsSnapshot: Equatable, Sendable {
    var provider: ASRProvider
    var whisperModelID: String
    /// A nil language means explicit Auto-detect. A non-nil value is an ISO-639-1 language code.
    var language: String?
    var captureMode: SettingsCaptureMode
    var showNotifications: Bool
    var autoPaste: Bool
    var macTeach: MacTeachSettingsSnapshot

    init(
        provider: ASRProvider,
        whisperModelID: String,
        language: String?,
        captureMode: SettingsCaptureMode,
        showNotifications: Bool,
        autoPaste: Bool,
        macTeach: MacTeachSettingsSnapshot = .defaults
    ) {
        self.provider = provider
        self.whisperModelID = whisperModelID
        self.language = language
        self.captureMode = captureMode
        self.showNotifications = showNotifications
        self.autoPaste = autoPaste
        self.macTeach = macTeach
    }

    var whisperModel: ModelSpec? {
        guard provider == .whisper else { return nil }
        return ModelCatalog.findById(whisperModelID)
    }

    func withCaptureMode(_ mode: SettingsCaptureMode) -> SettingsSnapshot {
        var copy = self
        copy.captureMode = mode
        return copy
    }
}

/// Holds the immutable settings selected when a recording request begins.
/// Retries must reuse this value instead of reading AppSettings again.
struct RecordingStartSnapshotLatch: Sendable {
    private(set) var snapshot: SettingsSnapshot?

    mutating func captureIfNeeded(_ snapshot: SettingsSnapshot) {
        if self.snapshot == nil {
            self.snapshot = snapshot
        }
    }

    mutating func clear() {
        snapshot = nil
    }
}

final class AppSettings: @unchecked Sendable {
    static let shared = AppSettings()

    private struct State {
        var snapshot: SettingsSnapshot
    }

    private let stateLock: OSAllocatedUnfairLock<State>
    private let defaults: UserDefaults
    private let beforePersist: @Sendable () -> Void

    private static let providerKey = "asrProvider"
    private static let whisperModelIDKey = "whisperModelID"
    private static let languageKey = "language"
    private static let captureModeKey = "captureMode"
    private static let showNotificationsKey = "showNotifications"
    private static let autoPasteKey = "autoPaste"
    private static let textHistoryEnabledKey = "macTeach.textHistoryEnabled"
    private static let textRetentionDaysKey = "macTeach.textRetentionDays"
    private static let maximumTextRecordsKey = "macTeach.maximumTextRecords"
    private static let keepRecordingsKey = "macTeach.keepRecordings"
    private static let audioRetentionDaysKey = "macTeach.audioRetentionDays"
    private static let personalVocabularyEnabledKey = "macTeach.personalVocabularyEnabled"
    private static let suggestCorrectionsKey = "macTeach.suggestCorrections"

    private static let defaultModelID = "whisper-large-v3-turbo-q5_0"
    private static let defaultLanguage = "en"

    private init(
        defaults: UserDefaults = .standard,
        beforePersist: @escaping @Sendable () -> Void = {}
    ) {
        self.defaults = defaults
        self.beforePersist = beforePersist
        Self.migrateLegacyKeys(in: defaults)
        let snapshot = Self.loadSnapshot(from: defaults)
        self.stateLock = OSAllocatedUnfairLock(initialState: State(snapshot: snapshot))
        Self.persist(snapshot, to: defaults)
    }

    var snapshot: SettingsSnapshot {
        stateLock.withLock { $0.snapshot }
    }

    /// Captures the settings used for one recording. Later edits are persisted
    /// for the next session and cannot mutate this value.
    func snapshotAtRecordingStart() -> SettingsSnapshot {
        snapshot
    }

    var provider: ASRProvider {
        get { snapshot.provider }
        set { update({ $0.provider = newValue }, postProviderNotification: true) }
    }

    func setWhisperModelID(_ id: String) {
        guard ModelCatalog.findById(id) != nil else { return }
        update { $0.whisperModelID = id }
    }

    func setLanguage(_ language: String?) {
        guard language == nil || Self.validLanguages.contains(language!) else { return }
        update { $0.language = language }
    }

    func setCaptureMode(_ mode: SettingsCaptureMode) {
        update { $0.captureMode = mode }
    }

    func setShowNotifications(_ enabled: Bool) {
        update { $0.showNotifications = enabled }
    }

    func setAutoPaste(_ enabled: Bool) {
        update { $0.autoPaste = enabled }
    }

    func setTextHistoryEnabled(_ enabled: Bool) {
        update { $0.macTeach.textHistoryEnabled = enabled }
    }

    func setTextRetention(days: Int?, maximumRecords: Int) {
        guard days == nil || days! > 0, maximumRecords > 0 else { return }
        update {
            $0.macTeach.textRetentionDays = days
            $0.macTeach.maximumTextRecords = maximumRecords
        }
    }

    func setKeepRecordings(_ enabled: Bool) {
        update { $0.macTeach.keepRecordings = enabled }
    }

    func setAudioRetentionDays(_ days: Int) {
        guard days > 0 else { return }
        update { $0.macTeach.audioRetentionDays = days }
    }

    func setPersonalVocabularyEnabled(_ enabled: Bool) {
        update { $0.macTeach.personalVocabularyEnabled = enabled }
    }

    func setSuggestCorrections(_ enabled: Bool) {
        update { $0.macTeach.suggestCorrections = enabled }
    }

    #if DEBUG
    static func makeForTesting(
        defaults: UserDefaults,
        beforePersist: @escaping @Sendable () -> Void = {}
    ) -> AppSettings {
        AppSettings(defaults: defaults, beforePersist: beforePersist)
    }
    #else
    static func makeForTesting(
        defaults: UserDefaults,
        beforePersist: @escaping @Sendable () -> Void = {}
    ) -> AppSettings {
        AppSettings(defaults: defaults, beforePersist: beforePersist)
    }
    #endif

    private func update(
        _ change: @Sendable (inout SettingsSnapshot) -> Void,
        postProviderNotification: Bool = false
    ) {
        let changedSnapshot: SettingsSnapshot? = stateLock.withLock { state in
            var next = state.snapshot
            change(&next)
            guard next != state.snapshot else { return nil }
            state.snapshot = next

            // Keep persistence in the same critical section as the state
            // mutation. Otherwise a slower older write can overwrite a newer
            // snapshot in UserDefaults after this lock has been released.
            beforePersist()
            Self.persist(next, to: defaults)
            return next
        }
        guard let changedSnapshot else { return }
        if postProviderNotification {
            NotificationCenter.default.post(name: .providerDidChange, object: changedSnapshot.provider)
        }
        NotificationCenter.default.post(name: .settingsDidChange, object: changedSnapshot)
    }

    private static func loadSnapshot(from defaults: UserDefaults) -> SettingsSnapshot {
        let provider = ASRProvider(rawValue: defaults.string(forKey: providerKey) ?? "") ?? .whisper
        let modelID = validModelID(defaults.string(forKey: whisperModelIDKey))
        let storedLanguage = defaults.string(forKey: languageKey)
        let language: String?
        if storedLanguage == "auto" {
            language = nil
        } else if let storedLanguage, validLanguages.contains(storedLanguage) {
            language = storedLanguage
        } else {
            language = defaultLanguage
        }
        let mode = SettingsCaptureMode(rawValue: defaults.string(forKey: captureModeKey) ?? "") ?? .micOnly
        let showNotifications = defaults.object(forKey: showNotificationsKey) == nil
            ? true : defaults.bool(forKey: showNotificationsKey)
        let defaultMacTeach = MacTeachSettingsSnapshot.defaults
        let storedTextRetention = defaults.object(forKey: textRetentionDaysKey) as? Int
        let macTeach = MacTeachSettingsSnapshot(
            textHistoryEnabled: defaults.object(forKey: textHistoryEnabledKey) == nil
                ? defaultMacTeach.textHistoryEnabled : defaults.bool(forKey: textHistoryEnabledKey),
            textRetentionDays: storedTextRetention == -1
                ? nil : (storedTextRetention ?? defaultMacTeach.textRetentionDays),
            maximumTextRecords: positiveInt(
                defaults.object(forKey: maximumTextRecordsKey) as? Int,
                fallback: defaultMacTeach.maximumTextRecords
            ),
            keepRecordings: defaults.object(forKey: keepRecordingsKey) == nil
                ? defaultMacTeach.keepRecordings : defaults.bool(forKey: keepRecordingsKey),
            audioRetentionDays: positiveInt(
                defaults.object(forKey: audioRetentionDaysKey) as? Int,
                fallback: defaultMacTeach.audioRetentionDays
            ),
            personalVocabularyEnabled: defaults.object(forKey: personalVocabularyEnabledKey) == nil
                ? defaultMacTeach.personalVocabularyEnabled : defaults.bool(forKey: personalVocabularyEnabledKey),
            suggestCorrections: defaults.object(forKey: suggestCorrectionsKey) == nil
                ? defaultMacTeach.suggestCorrections : defaults.bool(forKey: suggestCorrectionsKey)
        )
        return SettingsSnapshot(
            provider: provider,
            whisperModelID: modelID,
            language: language,
            captureMode: mode,
            showNotifications: showNotifications,
            autoPaste: defaults.bool(forKey: autoPasteKey),
            macTeach: macTeach
        )
    }

    private static func persist(_ snapshot: SettingsSnapshot, to defaults: UserDefaults) {
        defaults.set(snapshot.provider.rawValue, forKey: providerKey)
        defaults.set(snapshot.whisperModelID, forKey: whisperModelIDKey)
        defaults.set(snapshot.language ?? "auto", forKey: languageKey)
        defaults.set(snapshot.captureMode.rawValue, forKey: captureModeKey)
        defaults.set(snapshot.showNotifications, forKey: showNotificationsKey)
        defaults.set(snapshot.autoPaste, forKey: autoPasteKey)
        defaults.set(snapshot.macTeach.textHistoryEnabled, forKey: textHistoryEnabledKey)
        defaults.set(snapshot.macTeach.textRetentionDays ?? -1, forKey: textRetentionDaysKey)
        defaults.set(snapshot.macTeach.maximumTextRecords, forKey: maximumTextRecordsKey)
        defaults.set(snapshot.macTeach.keepRecordings, forKey: keepRecordingsKey)
        defaults.set(snapshot.macTeach.audioRetentionDays, forKey: audioRetentionDaysKey)
        defaults.set(snapshot.macTeach.personalVocabularyEnabled, forKey: personalVocabularyEnabledKey)
        defaults.set(snapshot.macTeach.suggestCorrections, forKey: suggestCorrectionsKey)
    }

    private static func migrateLegacyKeys(in defaults: UserDefaults) {
        if defaults.string(forKey: whisperModelIDKey) == nil {
            let modelIDs = [
                defaultModelID,
                "whisper-base-q5_1",
                "whisper-small-q5_1",
                "whisper-medium-q5_0",
                defaultModelID
            ]
            let index = defaults.object(forKey: "modelIndex") as? Int ?? 0
            let safeIndex = index >= 0 && index < modelIDs.count ? index : 0
            defaults.set(modelIDs[safeIndex], forKey: whisperModelIDKey)
        }
        if defaults.string(forKey: languageKey) == nil {
            let languages: [String?] = [nil, "en", "es", "fr", "de", "it", "pt", "nl", "ja", "zh"]
            let index = defaults.object(forKey: "languageIndex") as? Int ?? 1
            let safeIndex = index >= 0 && index < languages.count ? index : 1
            defaults.set(languages[safeIndex] ?? "auto", forKey: languageKey)
        }
        if defaults.string(forKey: captureModeKey) == nil {
            let index = defaults.object(forKey: "defaultMode") as? Int ?? 0
            defaults.set(index == 1 ? SettingsCaptureMode.micPlusAppAudio.rawValue : SettingsCaptureMode.micOnly.rawValue, forKey: captureModeKey)
        }
    }

    private static func validModelID(_ id: String?) -> String {
        guard let id, ModelCatalog.findById(id) != nil else { return defaultModelID }
        return id
    }

    private static func positiveInt(_ value: Int?, fallback: Int) -> Int {
        guard let value, value > 0 else { return fallback }
        return value
    }

    static let languageOptions: [String?] = [nil, "en", "es", "fr", "de", "it", "pt", "nl", "ja", "zh"]
    static let languageDisplayNames = ["Auto-detect", "English", "Spanish", "French", "German", "Italian", "Portuguese", "Dutch", "Japanese", "Chinese"]
    private static let validLanguages = languageOptions.compactMap { $0 }
}
