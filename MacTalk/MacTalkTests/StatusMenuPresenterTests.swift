import AppKit
import XCTest
@testable import MacTalk

@MainActor
final class StatusMenuPresenterTests: XCTestCase {
    func test_menuUsesStableOrderIdentifiersAndActions() {
        let target = NSObject()
        let presenter = StatusMenuPresenter(target: target, catalog: [])
        let ids = presenter.menu.items.map { $0.identifier?.rawValue ?? "" }
        XCTAssertEqual(ids, [
            StatusMenuPresenter.ItemID.micOnly,
            StatusMenuPresenter.ItemID.micPlusApp,
            StatusMenuPresenter.ItemID.stop,
            "",
            StatusMenuPresenter.ItemID.autoPaste,
            "",
            StatusMenuPresenter.ItemID.model,
            StatusMenuPresenter.ItemID.progress,
            "",
            StatusMenuPresenter.ItemID.performanceReport,
            StatusMenuPresenter.ItemID.settings,
            StatusMenuPresenter.ItemID.permissions,
            "",
            StatusMenuPresenter.ItemID.about,
            StatusMenuPresenter.ItemID.quit
        ])
        XCTAssertEqual(presenter.menu.items[0].action, #selector(StatusBarController.startMicOnly))
        XCTAssertEqual(presenter.menu.items[1].action, #selector(StatusBarController.startMicPlusApp))
        XCTAssertEqual(presenter.menu.items[2].action, #selector(StatusBarController.stopRecording))
        XCTAssertEqual(presenter.menu.items[4].keyEquivalent, "p")
        XCTAssertEqual(presenter.menu.items[9].action, #selector(StatusBarController.copyPerformanceReport))
        XCTAssertEqual(
            presenter.menu.items.first(where: { $0.identifier == .init(StatusMenuPresenter.ItemID.performanceReport) })?.title,
            "Copy Performance Report"
        )
        XCTAssertEqual(
            presenter.menu.items.first(where: { $0.identifier == .init(StatusMenuPresenter.ItemID.performanceReport) })?.action,
            #selector(StatusBarController.copyPerformanceReport)
        )
        XCTAssertEqual(presenter.menu.items[10].keyEquivalent, ",")
    }

    func test_renderUpdatesEnablementChecksAndShortcutTitles() {
        let presenter = StatusMenuPresenter(target: NSObject(), catalog: [])
        let settings = SettingsSnapshot(
            provider: .whisper,
            whisperModelID: "model",
            language: "en",
            captureMode: .micOnly,
            showNotifications: true,
            autoPaste: false
        )
        let permission = PermissionViewState(
            microphone: .granted,
            screenRecordingGranted: true,
            accessibilityTrusted: true,
            effectiveAutoPaste: true
        )
        let shortcut = KeyboardShortcut(keyCode: 46, modifierFlags: [.command])
        let state = StatusBarViewStateReducer.reduce(
            recording: RecordingSessionState(phase: .recording, requestID: UUID(), mode: .micOnly, selection: nil),
            settings: settings,
            permission: permission,
            download: .idle,
            shortcuts: ShortcutConfiguration(micOnly: shortcut, micPlusAppAudio: nil)
        )
        presenter.render(state)
        XCTAssertFalse(presenter.menu.items[0].isEnabled)
        XCTAssertTrue(presenter.menu.items[2].isEnabled)
        XCTAssertTrue(presenter.menu.items[4].state == .on)
        XCTAssertTrue(presenter.menu.items[0].attributedTitle?.string.contains("⌘M") == true)
    }
}
