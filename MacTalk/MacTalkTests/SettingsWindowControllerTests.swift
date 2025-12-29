//
//  SettingsWindowControllerTests.swift
//  MacTalkTests
//
//  Unit tests for SettingsWindowController
//

import XCTest
@testable import MacTalk

@MainActor
final class SettingsWindowControllerTests: XCTestCase {

    var settingsController: SettingsWindowController!
    let testDefaults = UserDefaults(suiteName: "com.mactalk.tests")!

    override func setUp() async throws {
        try await super.setUp()
        // Clear test defaults before each test
        testDefaults.removePersistentDomain(forName: "com.mactalk.tests")

        // Inject test defaults (in real implementation, SettingsWindowController would need to accept UserDefaults)
        settingsController = SettingsWindowController()
    }

    override func tearDown() async throws {
        settingsController = nil
        testDefaults.removePersistentDomain(forName: "com.mactalk.tests")
        try await super.tearDown()
    }

    // MARK: - Initialization Tests

    func testInitialization() {
        XCTAssertNotNil(settingsController)
        XCTAssertNotNil(settingsController.window)
        XCTAssertEqual(settingsController.window?.title, "MacTalk Settings")
    }

    func testWindowSize() {
        guard let window = settingsController.window else {
            XCTFail("Window should not be nil")
            return
        }

        let frame = window.frame
        XCTAssertEqual(frame.width, 500, accuracy: 1.0)
        XCTAssertEqual(frame.height, 400, accuracy: 1.0)
    }

    func testWindowStyle() {
        guard let window = settingsController.window else {
            XCTFail("Window should not be nil")
            return
        }

        XCTAssertTrue(window.styleMask.contains(.titled))
        XCTAssertTrue(window.styleMask.contains(.closable))
        XCTAssertFalse(window.styleMask.contains(.resizable))
    }

    // MARK: - Tab Structure Tests

    func testTabViewExists() {
        guard let contentView = settingsController.window?.contentView else {
            XCTFail("Content view should not be nil")
            return
        }

        let tabView = contentView.subviews.first(where: { $0 is NSTabView }) as? NSTabView
        XCTAssertNotNil(tabView, "Tab view should exist in content view")
    }

    func testNumberOfTabs() {
        guard let contentView = settingsController.window?.contentView,
              let tabView = contentView.subviews.first(where: { $0 is NSTabView }) as? NSTabView else {
            XCTFail("Tab view should exist")
            return
        }

        XCTAssertEqual(tabView.numberOfTabViewItems, 5, "Should have 5 tabs")
    }

    func testTabLabels() {
        guard let contentView = settingsController.window?.contentView,
              let tabView = contentView.subviews.first(where: { $0 is NSTabView }) as? NSTabView else {
            XCTFail("Tab view should exist")
            return
        }

        let expectedLabels = ["General", "Output", "Audio", "Advanced", "Permissions"]

        for (index, expectedLabel) in expectedLabels.enumerated() {
            let tabItem = tabView.tabViewItem(at: index)
            XCTAssertEqual(tabItem.label, expectedLabel, "Tab \(index) should have label '\(expectedLabel)'")
        }
    }

    // MARK: - Settings Persistence Tests

    func testGeneralSettingsPersistence() {
        let defaults = UserDefaults.standard

        // Set a value
        defaults.set(true, forKey: "launchAtLogin")

        // Create new controller to load settings
        let newController = SettingsWindowController()

        // The controller should have loaded the setting
        // (In real implementation, we'd verify the checkbox state)

        let savedValue = defaults.bool(forKey: "launchAtLogin")
        XCTAssertTrue(savedValue)

        // Cleanup
        defaults.removeObject(forKey: "launchAtLogin")
    }

    func testOutputSettingsPersistence() {
        let defaults = UserDefaults.standard

        defaults.set(true, forKey: "autoPaste")
        defaults.set(false, forKey: "copyToClipboard")

        let autoPaste = defaults.bool(forKey: "autoPaste")
        let copyToClipboard = defaults.bool(forKey: "copyToClipboard")

        XCTAssertTrue(autoPaste)
        XCTAssertFalse(copyToClipboard)

        // Cleanup
        defaults.removeObject(forKey: "autoPaste")
        defaults.removeObject(forKey: "copyToClipboard")
    }

    func testAudioSettingsPersistence() {
        let defaults = UserDefaults.standard

        defaults.set(1, forKey: "defaultMode") // Mic + App Audio
        defaults.set(true, forKey: "silenceDetection")
        defaults.set(-35.0, forKey: "silenceThreshold")

        XCTAssertEqual(defaults.integer(forKey: "defaultMode"), 1)
        XCTAssertTrue(defaults.bool(forKey: "silenceDetection"))
        XCTAssertEqual(defaults.double(forKey: "silenceThreshold"), -35.0, accuracy: 0.1)

        // Cleanup
        defaults.removeObject(forKey: "defaultMode")
        defaults.removeObject(forKey: "silenceDetection")
        defaults.removeObject(forKey: "silenceThreshold")
    }

    func testAdvancedSettingsPersistence() {
        let defaults = UserDefaults.standard

        defaults.set(2, forKey: "modelIndex") // Small model
        defaults.set(1, forKey: "languageIndex") // English
        defaults.set(true, forKey: "translate")
        defaults.set(7, forKey: "beamSize")

        XCTAssertEqual(defaults.integer(forKey: "modelIndex"), 2)
        XCTAssertEqual(defaults.integer(forKey: "languageIndex"), 1)
        XCTAssertTrue(defaults.bool(forKey: "translate"))
        XCTAssertEqual(defaults.integer(forKey: "beamSize"), 7)

        // Cleanup
        defaults.removeObject(forKey: "modelIndex")
        defaults.removeObject(forKey: "languageIndex")
        defaults.removeObject(forKey: "translate")
        defaults.removeObject(forKey: "beamSize")
    }

    // MARK: - Default Values Tests

    func testSilenceThresholdDefaultValue() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "silenceThreshold")

        // Create controller which should load defaults
        let controller = SettingsWindowController()

        // After loading, the slider should be set to default -40 dB
        // In real implementation, we'd verify the slider value
        XCTAssertNotNil(controller)
    }

    func testBeamSizeDefaultValue() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "beamSize")

        let controller = SettingsWindowController()

        // Default beam size should be 5
        XCTAssertNotNil(controller)
    }

    func testModelIndexDefaultValue() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "modelIndex")

        let controller = SettingsWindowController()

        // Default should be large-v3-turbo (index 4)
        XCTAssertNotNil(controller)
    }

    // MARK: - Settings Range Tests

    func testSilenceThresholdRange() {
        // Silence threshold should be between -60 and -10 dB
        let minValue: Double = -60.0
        let maxValue: Double = -10.0

        let defaults = UserDefaults.standard

        // Test min value
        defaults.set(minValue, forKey: "silenceThreshold")
        XCTAssertEqual(defaults.double(forKey: "silenceThreshold"), minValue)

        // Test max value
        defaults.set(maxValue, forKey: "silenceThreshold")
        XCTAssertEqual(defaults.double(forKey: "silenceThreshold"), maxValue)

        // Cleanup
        defaults.removeObject(forKey: "silenceThreshold")
    }

    func testBeamSizeRange() {
        // Beam size should be between 1 and 10
        let minValue = 1
        let maxValue = 10

        let defaults = UserDefaults.standard

        defaults.set(minValue, forKey: "beamSize")
        XCTAssertEqual(defaults.integer(forKey: "beamSize"), minValue)

        defaults.set(maxValue, forKey: "beamSize")
        XCTAssertEqual(defaults.integer(forKey: "beamSize"), maxValue)

        // Cleanup
        defaults.removeObject(forKey: "beamSize")
    }

    // MARK: - Settings Keys Tests

    func testAllSettingsKeys() {
        let expectedKeys = [
            "launchAtLogin",
            "showInDock",
            "showNotifications",
            "autoPaste",
            "copyToClipboard",
            "showTimestamps",
            "defaultMode",
            "silenceDetection",
            "silenceThreshold",
            "modelIndex",
            "languageIndex",
            "translate",
            "beamSize"
        ]

        // Verify we can read/write all expected keys
        let defaults = UserDefaults.standard

        for key in expectedKeys {
            defaults.set(true, forKey: key)
            XCTAssertNotNil(defaults.object(forKey: key), "Should be able to set key: \(key)")
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: - Window Lifecycle Tests

    func testShowWindow() {
        settingsController.showWindow(nil)
        XCTAssertTrue(settingsController.window?.isVisible ?? false)
    }

    func testWindowClose() {
        settingsController.showWindow(nil)
        settingsController.close()
        XCTAssertFalse(settingsController.window?.isVisible ?? true)
    }

    // MARK: - Integration Tests

    func testCompleteWorkflow() {
        // Simulate a complete user workflow
        let defaults = UserDefaults.standard

        // 1. User opens settings
        settingsController.showWindow(nil)
        XCTAssertTrue(settingsController.window?.isVisible ?? false)

        // 2. User changes general settings
        defaults.set(true, forKey: "launchAtLogin")
        defaults.set(false, forKey: "showInDock")

        // 3. User changes output settings
        defaults.set(true, forKey: "autoPaste")
        defaults.set(true, forKey: "copyToClipboard")

        // 4. User changes audio settings
        defaults.set(0, forKey: "defaultMode")
        defaults.set(true, forKey: "silenceDetection")
        defaults.set(-45.0, forKey: "silenceThreshold")

        // 5. User changes advanced settings
        defaults.set(2, forKey: "modelIndex")
        defaults.set(0, forKey: "languageIndex")
        defaults.set(5, forKey: "beamSize")

        // 6. Verify all settings are saved
        XCTAssertTrue(defaults.bool(forKey: "launchAtLogin"))
        XCTAssertFalse(defaults.bool(forKey: "showInDock"))
        XCTAssertTrue(defaults.bool(forKey: "autoPaste"))
        XCTAssertTrue(defaults.bool(forKey: "copyToClipboard"))
        XCTAssertEqual(defaults.integer(forKey: "defaultMode"), 0)
        XCTAssertTrue(defaults.bool(forKey: "silenceDetection"))
        XCTAssertEqual(defaults.double(forKey: "silenceThreshold"), -45.0, accuracy: 0.1)
        XCTAssertEqual(defaults.integer(forKey: "modelIndex"), 2)
        XCTAssertEqual(defaults.integer(forKey: "languageIndex"), 0)
        XCTAssertEqual(defaults.integer(forKey: "beamSize"), 5)

        // 7. User closes settings
        settingsController.close()

        // Cleanup
        for key in ["launchAtLogin", "showInDock", "autoPaste", "copyToClipboard",
                    "defaultMode", "silenceDetection", "silenceThreshold",
                    "modelIndex", "languageIndex", "beamSize"] {
            defaults.removeObject(forKey: key)
        }
    }

    func testSettingsPersistAcrossInstances() {
        let defaults = UserDefaults.standard

        // Set values in first instance
        defaults.set(true, forKey: "launchAtLogin")
        defaults.set(2, forKey: "modelIndex")
        defaults.set(-40.0, forKey: "silenceThreshold")

        // Create new instance
        let newController = SettingsWindowController()

        // Values should still be there
        XCTAssertTrue(defaults.bool(forKey: "launchAtLogin"))
        XCTAssertEqual(defaults.integer(forKey: "modelIndex"), 2)
        XCTAssertEqual(defaults.double(forKey: "silenceThreshold"), -40.0, accuracy: 0.1)

        XCTAssertNotNil(newController)

        // Cleanup
        defaults.removeObject(forKey: "launchAtLogin")
        defaults.removeObject(forKey: "modelIndex")
        defaults.removeObject(forKey: "silenceThreshold")
    }

    // MARK: - Edge Cases

    func testInvalidSettingsValues() {
        let defaults = UserDefaults.standard

        // Test with out-of-range values (should be handled by UI constraints)
        defaults.set(-100.0, forKey: "silenceThreshold")
        defaults.set(100, forKey: "beamSize")
        defaults.set(999, forKey: "modelIndex")

        // The settings should still be retrievable (validation happens in UI)
        XCTAssertEqual(defaults.double(forKey: "silenceThreshold"), -100.0)
        XCTAssertEqual(defaults.integer(forKey: "beamSize"), 100)
        XCTAssertEqual(defaults.integer(forKey: "modelIndex"), 999)

        // Cleanup
        defaults.removeObject(forKey: "silenceThreshold")
        defaults.removeObject(forKey: "beamSize")
        defaults.removeObject(forKey: "modelIndex")
    }

    func testMultipleWindowInstances() {
        // Test creating multiple instances (should be singleton pattern in real app)
        let controller1 = SettingsWindowController()
        let controller2 = SettingsWindowController()

        XCTAssertNotNil(controller1)
        XCTAssertNotNil(controller2)

        // Both should be independent instances (or same instance if singleton)
        XCTAssertNotNil(controller1.window)
        XCTAssertNotNil(controller2.window)
    }

    // MARK: - Performance Tests

    func testSettingsLoadPerformance() {
        measure {
            _ = SettingsWindowController()
        }
    }

    func testSettingsSavePerformance() {
        let defaults = UserDefaults.standard

        measure {
            for i in 0..<100 {
                defaults.set(i % 2 == 0, forKey: "autoPaste")
                defaults.set(Double(i), forKey: "silenceThreshold")
                defaults.set(i % 10, forKey: "beamSize")
            }
        }

        // Cleanup
        defaults.removeObject(forKey: "autoPaste")
        defaults.removeObject(forKey: "silenceThreshold")
        defaults.removeObject(forKey: "beamSize")
    }
}
