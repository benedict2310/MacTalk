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

    func test_defaultsToWhisperWhenUnset() {
        let settings = AppSettings.makeForTesting(defaults: defaults)
        XCTAssertEqual(settings.provider, .whisper)
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
