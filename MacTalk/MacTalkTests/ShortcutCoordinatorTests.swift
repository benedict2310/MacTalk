import AppKit
import XCTest
@testable import MacTalk

@MainActor
final class ShortcutCoordinatorTests: XCTestCase {
    func test_reloadUnregistersBeforeRegisteringAndMapsTypedIntents() {
        let registrar = HotkeyRegistrarFake()
        let reader = ShortcutReaderFake(configuration: ShortcutConfiguration(
            micOnly: KeyboardShortcut(keyCode: 49, modifierFlags: [.command, .shift]),
            micPlusAppAudio: KeyboardShortcut(keyCode: 36, modifierFlags: [.command])
        ))
        let coordinator = ShortcutCoordinator(registrar: registrar, reader: reader)
        var intents: [StatusBarIntent] = []
        coordinator.onIntent = { intents.append($0) }

        coordinator.reload()

        XCTAssertEqual(registrar.operations, [.unregisterAll, .register(49), .register(36)])
        registrar.invoke(keyCode: 49)
        registrar.invoke(keyCode: 36)
        XCTAssertEqual(intents, [.startMicOnly, .startMicPlusAppAudio])
        XCTAssertEqual(coordinator.configuration, reader.configuration)
    }

    func test_cleanupUnregistersAll() {
        let registrar = HotkeyRegistrarFake()
        let coordinator = ShortcutCoordinator(
            registrar: registrar,
            reader: ShortcutReaderFake(configuration: .empty)
        )

        coordinator.reload()
        coordinator.cleanup()

        XCTAssertEqual(registrar.operations, [.unregisterAll, .unregisterAll])
    }

    func test_malformedPersistedShortcutsRegisterNothing() throws {
        let suite = "ShortcutCoordinatorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("not-json".utf8), forKey: "startMicOnlyShortcut")
        defaults.set(Data("also-not-json".utf8), forKey: "startMicPlusAppShortcut")

        let registrar = HotkeyRegistrarFake()
        let coordinator = ShortcutCoordinator(
            registrar: registrar,
            reader: UserDefaultsShortcutConfigurationReader(defaults: defaults)
        )
        coordinator.reload()

        XCTAssertEqual(coordinator.configuration, .empty)
        XCTAssertEqual(registrar.operations, [.unregisterAll])
    }
}

@MainActor
private final class HotkeyRegistrarFake: HotkeyRegistering {
    enum Operation: Equatable { case unregisterAll; case register(UInt32) }
    var operations: [Operation] = []
    private var handlers: [UInt32: @MainActor @Sendable () -> Void] = [:]
    private var nextID: UInt32 = 1

    func register(
        keyCode: UInt32,
        modifiers: UInt32,
        handler: @escaping @MainActor @Sendable () -> Void
    ) -> UInt32? {
        operations.append(.register(keyCode))
        let id = nextID
        nextID += 1
        handlers[keyCode] = handler
        return id
    }

    func unregister(id: UInt32) {}
    func unregisterAll() {
        operations.append(.unregisterAll)
        handlers.removeAll()
    }

    func invoke(keyCode: UInt32) { handlers[keyCode]?() }
}

private struct ShortcutReaderFake: ShortcutConfigurationReading {
    let configuration: ShortcutConfiguration
    func shortcuts() -> ShortcutConfiguration { configuration }
}
