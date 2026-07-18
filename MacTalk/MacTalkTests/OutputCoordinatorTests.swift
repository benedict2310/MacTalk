import XCTest
@testable import MacTalk

@MainActor
final class OutputCoordinatorTests: XCTestCase {
    func test_clipboardIsWrittenBeforeInsertion() {
        let events = EventLog()
        let permission = OutputPermissionFake(trusted: true)
        let output = makeOutput(events: events, permission: permission, insertion: .axSetValueSuccess)
        output.setTarget(ApplicationIdentity(processIdentifier: 10, displayName: "Editor"))
        let result = output.handleFinal(
            text: "secret",
            context: OutputContext(target: ApplicationIdentity(processIdentifier: 10, displayName: "Editor"), autoPastePreference: true, showNotifications: false)
        )
        XCTAssertEqual(result.insertOutcome, .axSetValueSuccess)
        XCTAssertEqual(events.values, ["clipboard", "insert"])
    }

    func test_disabledOrUntrustedAutoPasteCopiesOnly() {
        for trusted in [true, false] {
            let events = EventLog()
            let output = makeOutput(events: events, permission: OutputPermissionFake(trusted: trusted), insertion: .axSetValueSuccess)
            let result = output.handleFinal(
                text: "text",
                context: OutputContext(target: nil, autoPastePreference: trusted, showNotifications: false)
            )
            if trusted {
                XCTAssertEqual(result.insertOutcome, .axSetValueSuccess)
            } else {
                XCTAssertEqual(result.insertOutcome, .notAttempted)
            }
            XCTAssertEqual(events.values.filter { $0 == "clipboard" }.count, 1)
            XCTAssertFalse(events.values.contains("insert") && !trusted)
        }
    }

    func test_targetMatrixPreservesPermissiveFallbacks() {
        let target = ApplicationIdentity(processIdentifier: 10, displayName: "Editor")
        let changedFrontmost = WorkspaceFake(frontmost: ApplicationIdentity(processIdentifier: 20, displayName: "Other"))
        let changed = OutputCoordinator(
            clipboardWriter: ClipboardFake(), textInserter: InserterFake(result: .axSetValueSuccess),
            workspaceReader: changedFrontmost, notifications: NotificationFake(),
            permissionFlow: OutputPermissionFake(trusted: true), processIdentifier: 99
        )
        changed.setTarget(target)
        XCTAssertEqual(changed.handleFinal(text: "x", context: OutputContext(target: target, autoPastePreference: true, showNotifications: false)).insertOutcome, .skippedTargetChanged)

        for frontmost in [nil, ApplicationIdentity(processIdentifier: 99, displayName: "MacTalk")] {
            let output = OutputCoordinator(
                clipboardWriter: ClipboardFake(), textInserter: InserterFake(result: .cmdVFallback),
                workspaceReader: WorkspaceFake(frontmost: frontmost), notifications: NotificationFake(),
                permissionFlow: OutputPermissionFake(trusted: true), processIdentifier: 99
            )
            output.setTarget(target)
            XCTAssertEqual(output.handleFinal(text: "x", context: OutputContext(target: target, autoPastePreference: true, showNotifications: false)).insertOutcome, .cmdVFallback)
        }
    }

    func test_permissionDenialReturnsPromptAndClearsTarget() {
        let permission = OutputPermissionFake(trusted: false, effective: true)
        let notifications = NotificationFake()
        let output = OutputCoordinator(
            clipboardWriter: ClipboardFake(), textInserter: InserterFake(result: .permissionDenied),
            workspaceReader: WorkspaceFake(frontmost: nil), notifications: notifications,
            permissionFlow: permission
        )
        output.setTarget(ApplicationIdentity(processIdentifier: 10, displayName: "Editor"))
        let result = output.handleFinal(text: "x", context: OutputContext(target: nil, autoPastePreference: true, showNotifications: true))
        XCTAssertEqual(result.permissionEffect, .requestAccessibility)
        XCTAssertEqual(notifications.events, [.transcriptionComplete])
        XCTAssertNil(output.currentTarget)
    }

    private func makeOutput(events: EventLog, permission: OutputPermissionFake, insertion: AutoInsertResult) -> OutputCoordinator {
        OutputCoordinator(
            clipboardWriter: ClipboardFake(events: events),
            textInserter: InserterFake(result: insertion, events: events),
            workspaceReader: WorkspaceFake(frontmost: ApplicationIdentity(processIdentifier: 10, displayName: "Editor")),
            notifications: NotificationFake(), permissionFlow: permission, processIdentifier: 99
        )
    }
}

@MainActor private final class EventLog { var values: [String] = [] }
@MainActor private final class ClipboardFake: ClipboardWriting {
    let events: EventLog?
    init(events: EventLog? = nil) { self.events = events }
    func write(_ text: String) -> Bool { events?.values.append("clipboard"); return true }
}
@MainActor private final class InserterFake: TextInserting {
    let result: AutoInsertResult
    let events: EventLog?
    init(result: AutoInsertResult, events: EventLog? = nil) { self.result = result; self.events = events }
    func insert(_ text: String) -> AutoInsertResult { events?.values.append("insert"); return result }
}
@MainActor private final class WorkspaceFake: WorkspaceReading {
    var frontmostApplication: ApplicationIdentity?
    var activeApplications: [ApplicationIdentity] = []
    init(frontmost: ApplicationIdentity?) { frontmostApplication = frontmost }
}
@MainActor private final class NotificationFake: NotificationSubmitting {
    var events: [AppNotificationEvent] = []
    func submit(_ event: AppNotificationEvent, enabled: Bool) { if enabled { events.append(event) } }
}
@MainActor private final class OutputPermissionFake: PermissionFlowCoordinating {
    var trusted: Bool
    let effective: Bool
    init(trusted: Bool, effective: Bool? = nil) {
        self.trusted = trusted
        self.effective = effective ?? trusted
    }
    var effectiveAutoPaste: Bool { effective }
    func refresh(storedAutoPaste: Bool) -> PermissionViewState { fatalError() }
    func requestEnableAutoPaste() async -> AutoPasteEnableResult { .unavailable }
    func permissionDeniedByInsert(at now: Date) -> AccessibilityPromptDecision { .requestPrompt }
    func recordSuccessfulInsert() {}
    func statusReport() -> PermissionStatusReport { fatalError() }
}
