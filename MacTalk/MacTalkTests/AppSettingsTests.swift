//
//  AppSettingsTests.swift
//  MacTalkTests
//
//  Tests for AppSettings provider persistence and notifications
//

import XCTest
@testable import MacTalk

final class AppSettingsTests: XCTestCase {

    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "AppSettingsTests")
        defaults.removePersistentDomain(forName: "AppSettingsTests")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "AppSettingsTests")
        defaults = nil
        super.tearDown()
    }

    func test_defaultsAreExplicitAndProviderCompatible() {
        let settings = AppSettings.makeForTesting(defaults: defaults)
        let snapshot = settings.snapshot

        XCTAssertEqual(snapshot.provider, .whisper)
        XCTAssertEqual(snapshot.whisperModelID, "whisper-large-v3-turbo-q5_0")
        XCTAssertEqual(snapshot.language, "en")
        XCTAssertEqual(snapshot.captureMode, .micOnly)
        XCTAssertTrue(snapshot.showNotifications)
        XCTAssertFalse(snapshot.autoPaste)
        XCTAssertEqual(snapshot.provider, snapshot.whisperModel?.provider)

        settings.provider = .parakeet
        XCTAssertNil(settings.snapshot.whisperModel)
        XCTAssertEqual(settings.snapshot.whisperModelID, snapshot.whisperModelID)
        settings.provider = .whisper
        XCTAssertEqual(settings.snapshot.whisperModel?.provider, .whisper)
    }

    func test_migratesLegacyIndexesToStableIDsOnce() {
        defaults.set(1, forKey: "modelIndex")
        defaults.set(3, forKey: "languageIndex")
        defaults.set(1, forKey: "defaultMode")
        defaults.set("parakeet", forKey: "asrProvider")

        let settings = AppSettings.makeForTesting(defaults: defaults)
        XCTAssertEqual(settings.snapshot.whisperModelID, "whisper-base-q5_1")
        XCTAssertEqual(settings.snapshot.language, "fr")
        XCTAssertEqual(settings.snapshot.captureMode, .micPlusAppAudio)
        XCTAssertEqual(settings.snapshot.provider, .parakeet)
        XCTAssertEqual(defaults.string(forKey: "whisperModelID"), "whisper-base-q5_1")
        XCTAssertEqual(defaults.string(forKey: "language"), "fr")
        XCTAssertEqual(defaults.string(forKey: "captureMode"), "micPlusAppAudio")

        defaults.set(4, forKey: "modelIndex")
        let reloaded = AppSettings.makeForTesting(defaults: defaults)
        XCTAssertEqual(reloaded.snapshot.whisperModelID, "whisper-base-q5_1")
    }

    func test_invalidValuesUseSafeDefaultsAndKeepProviderModelSiloed() {
        defaults.set("not-a-provider", forKey: "asrProvider")
        defaults.set("parakeet-model", forKey: "whisperModelID")
        defaults.set("not-a-language", forKey: "language")
        defaults.set("not-a-mode", forKey: "captureMode")

        let settings = AppSettings.makeForTesting(defaults: defaults)
        let snapshot = settings.snapshot
        XCTAssertEqual(snapshot.provider, .whisper)
        XCTAssertEqual(snapshot.whisperModelID, "whisper-large-v3-turbo-q5_0")
        XCTAssertEqual(snapshot.language, "en")
        XCTAssertEqual(snapshot.captureMode, .micOnly)
        XCTAssertEqual(snapshot.whisperModel?.provider, .whisper)
    }

    func test_autoDetectIsDistinctFromEnglishAndPersists() {
        let settings = AppSettings.makeForTesting(defaults: defaults)
        settings.setLanguage(nil)

        XCTAssertNil(settings.snapshot.language)
        XCTAssertEqual(defaults.string(forKey: "language"), "auto")

        let reloaded = AppSettings.makeForTesting(defaults: defaults)
        XCTAssertNil(reloaded.snapshot.language)
        reloaded.setLanguage("en")
        XCTAssertEqual(reloaded.snapshot.language, "en")
    }

    func test_snapshotAtRecordingStartIsStableWhenSettingsChange() {
        let settings = AppSettings.makeForTesting(defaults: defaults)
        let recordingSnapshot = settings.snapshotAtRecordingStart()
        settings.setLanguage("de")
        settings.setCaptureMode(.micPlusAppAudio)
        settings.provider = .parakeet

        XCTAssertEqual(recordingSnapshot.provider, .whisper)
        XCTAssertEqual(recordingSnapshot.language, "en")
        XCTAssertEqual(recordingSnapshot.captureMode, .micOnly)
        XCTAssertEqual(settings.snapshot.language, "de")
        XCTAssertEqual(settings.snapshot.captureMode, .micPlusAppAudio)
        XCTAssertEqual(settings.snapshot.provider, .parakeet)
    }

    func test_pendingRetrySnapshotIgnoresLaterSettingsEdits() {
        let settings = AppSettings.makeForTesting(defaults: defaults)
        var latch = RecordingStartSnapshotLatch()
        let requested = settings.snapshotAtRecordingStart().withCaptureMode(.micPlusAppAudio)
        latch.captureIfNeeded(requested)

        settings.setLanguage("de")
        settings.setWhisperModelID("whisper-base-q5_1")
        settings.provider = .parakeet
        settings.setCaptureMode(.micOnly)

        // A preparation/download retry must use the original request, not a
        // fresh AppSettings snapshot taken after these edits.
        latch.captureIfNeeded(settings.snapshotAtRecordingStart())
        XCTAssertEqual(latch.snapshot, requested)

        latch.clear()
        XCTAssertNil(latch.snapshot)
    }

    func test_abandonedStartDoesNotLatchSettingsForNextRequest() {
        let settings = AppSettings.makeForTesting(defaults: defaults)
        var latch = RecordingStartSnapshotLatch()

        latch.captureIfNeeded(settings.snapshotAtRecordingStart().withCaptureMode(.micPlusAppAudio))
        settings.setLanguage("de")
        settings.setCaptureMode(.micOnly)
        settings.setWhisperModelID("whisper-base-q5_1")

        // Permission denial, picker cancellation, and source-load failures all
        // abandon the request. A later request must capture the updated values.
        latch.clear()
        latch.captureIfNeeded(settings.snapshotAtRecordingStart().withCaptureMode(.micOnly))

        XCTAssertEqual(latch.snapshot?.language, "de")
        XCTAssertEqual(latch.snapshot?.captureMode, .micOnly)
        XCTAssertEqual(latch.snapshot?.whisperModelID, "whisper-base-q5_1")
    }

    func test_persistsProviderSelection() {
        let settings = AppSettings.makeForTesting(defaults: defaults)
        settings.provider = .parakeet

        let stored = defaults.string(forKey: "asrProvider")
        XCTAssertEqual(stored, ASRProvider.parakeet.rawValue)
    }

    func test_postsNotificationOnProviderChange() {
        let settings = AppSettings.makeForTesting(defaults: defaults)
        let expectation = expectation(forNotification: .providerDidChange, object: nil) { notification in
            guard let provider = notification.object as? ASRProvider else { return false }
            return provider == .parakeet
        }

        settings.provider = .parakeet

        wait(for: [expectation], timeout: 1.0)
    }
}
