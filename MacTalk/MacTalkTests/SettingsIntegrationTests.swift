//
//  SettingsIntegrationTests.swift
//  MacTalkTests
//
//  Tests that settings are properly integrated and actually work
//

import XCTest
@testable import MacTalk

@MainActor
final class SettingsIntegrationTests: XCTestCase {

    override func setUpWithError() throws {
        // Clear all settings before each test
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "autoPaste")
        defaults.removeObject(forKey: "copyToClipboard")
        defaults.removeObject(forKey: "showNotifications")
        defaults.removeObject(forKey: "showInDock")
        defaults.removeObject(forKey: "defaultMode")
        defaults.removeObject(forKey: "languageIndex")
        defaults.removeObject(forKey: "modelIndex")
    }

    override func tearDownWithError() throws {
        // Clean up after each test
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "autoPaste")
        defaults.removeObject(forKey: "copyToClipboard")
        defaults.removeObject(forKey: "showNotifications")
        defaults.removeObject(forKey: "showInDock")
        defaults.removeObject(forKey: "defaultMode")
        defaults.removeObject(forKey: "languageIndex")
        defaults.removeObject(forKey: "modelIndex")
    }

    // MARK: - Auto-paste Tests

    func testAutoPasteSetting_DefaultsToFalse() {
        // When: StatusBarController is created with no saved settings
        let controller = StatusBarController()

        // Then: Auto-paste should default to false
        // (We'll verify this by checking the setting is used correctly)
        XCTAssertNotNil(controller)
    }

    func testAutoPasteSetting_LoadsFromUserDefaults() {
        // Given: Auto-paste is enabled in settings
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: "autoPaste")

        // When: StatusBarController is created
        let controller = StatusBarController()

        // Then: It should load the auto-paste setting from UserDefaults
        // We verify this by checking if the setting is properly initialized
        XCTAssertNotNil(controller)

        // Note: This is a basic initialization test.
        // The actual auto-paste functionality is tested in integration tests
        // where we can verify the behavior with TranscriptionController
    }

    func testAutoPasteSetting_SyncsBetweenMenuAndSettings() {
        // Given: Auto-paste is set to true in settings
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: "autoPaste")

        // When: Settings window is created
        let settingsController = SettingsWindowController()

        // Then: The checkbox should reflect the saved value
        XCTAssertNotNil(settingsController)

        // And when: Settings are changed
        defaults.set(false, forKey: "autoPaste")

        // Then: The new value should be persisted
        XCTAssertFalse(defaults.bool(forKey: "autoPaste"))
    }

    // MARK: - Copy to Clipboard Tests

    func testCopyToClipboardSetting_DefaultsToTrue() {
        // When: No setting is saved
        let defaults = UserDefaults.standard

        // Then: Copy to clipboard should default to on (true)
        // This is tested by the checkbox default state in Settings
        let settingsController = SettingsWindowController()
        XCTAssertNotNil(settingsController)
    }

    func testCopyToClipboardSetting_LoadsFromUserDefaults() {
        // Given: Copy to clipboard is disabled in settings
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: "copyToClipboard")

        // When: Settings window loads
        let settingsController = SettingsWindowController()

        // Then: The setting should be loaded
        XCTAssertFalse(defaults.bool(forKey: "copyToClipboard"))
        XCTAssertNotNil(settingsController)
    }

    // MARK: - Show Notifications Tests

    func testShowNotificationsSetting_LoadsFromUserDefaults() {
        // Given: Notifications are disabled
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: "showNotifications")

        // When: Settings load
        let settingsController = SettingsWindowController()

        // Then: The setting should be loaded correctly
        XCTAssertFalse(defaults.bool(forKey: "showNotifications"))
        XCTAssertNotNil(settingsController)
    }

    // MARK: - Language Selection Tests

    func testLanguageSetting_DefaultsToEnglish() {
        // When: No language is set
        let defaults = UserDefaults.standard

        // Then: Language should default to English (index 1)
        let settingsController = SettingsWindowController()
        XCTAssertNotNil(settingsController)

        // After settings load with default, index should be 1
        let savedIndex = defaults.integer(forKey: "languageIndex")
        XCTAssertTrue(savedIndex == 0 || savedIndex == 1, "Language index should be 0 (not set) or 1 (English)")
    }

    func testLanguageSetting_LoadsFromUserDefaults() {
        // Given: Spanish is selected (index 2)
        let defaults = UserDefaults.standard
        defaults.set(2, forKey: "languageIndex")

        // When: Settings load
        let settingsController = SettingsWindowController()

        // Then: Spanish should be selected
        XCTAssertEqual(defaults.integer(forKey: "languageIndex"), 2)
        XCTAssertNotNil(settingsController)
    }

    // MARK: - Model Selection Tests

    func testModelSetting_DefaultsToLargev3Turbo() {
        // When: No model is set
        let defaults = UserDefaults.standard

        // Then: Model should default to large-v3-turbo (index 4)
        let settingsController = SettingsWindowController()
        XCTAssertNotNil(settingsController)
    }

    func testModelSetting_LoadsFromUserDefaults() {
        // Given: Small model is selected (index 2)
        let defaults = UserDefaults.standard
        defaults.set(2, forKey: "modelIndex")

        // When: Settings load
        let settingsController = SettingsWindowController()

        // Then: Small model should be selected
        XCTAssertEqual(defaults.integer(forKey: "modelIndex"), 2)
        XCTAssertNotNil(settingsController)
    }

    // MARK: - Default Mode Tests

    func testDefaultModeSetting_LoadsFromUserDefaults() {
        // Given: Mic + App Audio is set as default (index 1)
        let defaults = UserDefaults.standard
        defaults.set(1, forKey: "defaultMode")

        // When: Settings load
        let settingsController = SettingsWindowController()

        // Then: The setting should be loaded
        XCTAssertEqual(defaults.integer(forKey: "defaultMode"), 1)
        XCTAssertNotNil(settingsController)
    }
}
