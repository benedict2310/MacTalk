import Foundation

struct ShortcutConfiguration: Equatable {
    let micOnly: KeyboardShortcut?
    let micPlusAppAudio: KeyboardShortcut?
    let correctLast: KeyboardShortcut?

    static let empty = ShortcutConfiguration(micOnly: nil, micPlusAppAudio: nil, correctLast: nil)
}

@MainActor
protocol HotkeyRegistering: AnyObject {
    func register(
        keyCode: UInt32,
        modifiers: UInt32,
        handler: @escaping @MainActor @Sendable () -> Void
    ) -> UInt32?
    func unregister(id: UInt32)
    func unregisterAll()
}

protocol ShortcutConfigurationReading {
    func shortcuts() -> ShortcutConfiguration
}

struct UserDefaultsShortcutConfigurationReader: ShortcutConfigurationReading {
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func shortcuts() -> ShortcutConfiguration {
        ShortcutConfiguration(
            micOnly: decode("startMicOnlyShortcut"),
            micPlusAppAudio: decode("startMicPlusAppShortcut"),
            correctLast: decode("correctLastTranscriptionShortcut")
        )
    }

    private func decode(_ key: String) -> KeyboardShortcut? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(KeyboardShortcut.self, from: data)
    }
}

@MainActor
final class SystemHotkeyRegistrar: HotkeyRegistering {
    private let manager: HotkeyManager

    init(manager: HotkeyManager = HotkeyManager()) {
        self.manager = manager
    }

    func register(
        keyCode: UInt32,
        modifiers: UInt32,
        handler: @escaping @MainActor @Sendable () -> Void
    ) -> UInt32? {
        manager.register(keyCode: keyCode, modifiers: modifiers, handler: handler)
    }

    func unregister(id: UInt32) { manager.unregister(hotkeyID: id) }
    func unregisterAll() { manager.unregisterAll() }
}

@MainActor
protocol ShortcutCoordinating: AnyObject {
    var onIntent: ((StatusBarIntent) -> Void)? { get set }
    var configuration: ShortcutConfiguration { get }
    func reload()
    func cleanup()
}

/// Owns registration lifetime and maps both global shortcuts to the same
/// typed intents used by the menu. It intentionally has no recording state.
@MainActor
final class ShortcutCoordinator: ShortcutCoordinating {
    private let registrar: any HotkeyRegistering
    private let reader: any ShortcutConfigurationReading
    private var registeredIDs: [UInt32] = []
    private(set) var configuration: ShortcutConfiguration = .empty
    var onIntent: ((StatusBarIntent) -> Void)?

    init(
        registrar: any HotkeyRegistering,
        reader: any ShortcutConfigurationReading
    ) {
        self.registrar = registrar
        self.reader = reader
    }

    func reload() {
        registrar.unregisterAll()
        registeredIDs.removeAll()
        configuration = reader.shortcuts()

        if let shortcut = configuration.micOnly {
            register(shortcut, intent: .toggleMicOnly)
        }
        if let shortcut = configuration.micPlusAppAudio {
            register(shortcut, intent: .toggleMicPlusAppAudio)
        }
        if let shortcut = configuration.correctLast {
            register(shortcut, intent: .correctLastTranscription)
        }
    }

    func cleanup() {
        registrar.unregisterAll()
        registeredIDs.removeAll()
    }

    private func register(_ shortcut: KeyboardShortcut, intent: StatusBarIntent) {
        guard let id = registrar.register(
            keyCode: shortcut.keyCode,
            modifiers: shortcut.carbonModifiers,
            handler: { [weak self] in self?.onIntent?(intent) }
        ) else { return }
        registeredIDs.append(id)
    }
}
