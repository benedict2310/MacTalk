//
//  HotkeyManager.swift
//  MacTalk
//
//  Global hotkey registration and management
//

import Carbon
import AppKit

final class HotkeyManager {
    typealias HotkeyHandler = @MainActor @Sendable () -> Void

    private var hotkeys: [UInt32: (EventHotKeyRef, HotkeyHandler)] = [:]
    private var nextHotkeyID: UInt32 = 1

    // Carbon event handler
    private var eventHandler: EventHandlerRef?

    init() {
        registerEventHandler()
    }

    deinit {
        unregisterAll()
        if let handler = eventHandler {
            RemoveEventHandler(handler)
        }
    }

    // MARK: - Registration

    /// Register a global hotkey
    @discardableResult
    func register(
        keyCode: UInt32,
        modifiers: UInt32,
        handler: @escaping HotkeyHandler
    ) -> UInt32? {
        let hotkeyID = nextHotkeyID
        nextHotkeyID += 1

        var eventHotkey: EventHotKeyRef?
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            EventHotKeyID(signature: OSType(kEventHotKeySignature ?? FourCharCode("htky".utf8.reduce(0) { $0 << 8 + FourCharCode($1) })), id: hotkeyID),
            GetEventDispatcherTarget(),
            0,
            &eventHotkey
        )

        guard status == noErr, let hotkey = eventHotkey else {
            print("Failed to register hotkey with status: \(status)")
            return nil
        }

        hotkeys[hotkeyID] = (hotkey, handler)
        print("Registered hotkey with ID: \(hotkeyID)")
        return hotkeyID
    }

    /// Unregister a hotkey by ID
    func unregister(hotkeyID: UInt32) {
        guard let (hotkey, _) = hotkeys[hotkeyID] else { return }
        UnregisterEventHotKey(hotkey)
        hotkeys.removeValue(forKey: hotkeyID)
        print("Unregistered hotkey with ID: \(hotkeyID)")
    }

    /// Unregister all hotkeys
    func unregisterAll() {
        for (_, (hotkey, _)) in hotkeys {
            UnregisterEventHotKey(hotkey)
        }
        hotkeys.removeAll()
        print("Unregistered all hotkeys")
    }

    // MARK: - Event Handling

    private func registerEventHandler() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

        let callback: EventHandlerUPP = { (nextHandler, theEvent, userData) -> OSStatus in
            guard let userData = userData else { return OSStatus(eventNotHandledErr) }

            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()

            var hotkeyID = EventHotKeyID()
            let status = GetEventParameter(
                theEvent,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotkeyID
            )

            guard status == noErr else { return status }

            manager.handleHotkeyPressed(id: hotkeyID.id)

            return noErr
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            GetEventDispatcherTarget(),
            callback,
            1,
            &eventType,
            selfPtr,
            &eventHandler
        )
    }

    private func handleHotkeyPressed(id: UInt32) {
        guard let (_, handler) = hotkeys[id] else { return }
        Task { @MainActor in
            handler()
        }
    }
}

// MARK: - Constants

private let kEventHotKeySignature = FourCharCode("MKTK") // MacTalk

// MARK: - Common Hotkey Configurations

extension HotkeyManager {
    /// Commonly used modifier combinations
    enum Modifiers {
        static let command: UInt32 = UInt32(cmdKey)
        static let shift: UInt32 = UInt32(shiftKey)
        static let option: UInt32 = UInt32(optionKey)
        static let control: UInt32 = UInt32(controlKey)

        static let commandShift: UInt32 = command | shift
        static let commandOption: UInt32 = command | option
        static let commandControl: UInt32 = command | control
        static let shiftOption: UInt32 = shift | option
        static let commandShiftOption: UInt32 = command | shift | option
    }

    /// Common key codes
    enum KeyCode {
        static let space: UInt32 = 49
        static let returnKey: UInt32 = 36
        static let escape: UInt32 = 53
        static let delete: UInt32 = 51

        // Function keys
        static let functionKey1: UInt32 = 122
        static let functionKey2: UInt32 = 120
        static let functionKey3: UInt32 = 99
        static let functionKey4: UInt32 = 118
        static let functionKey5: UInt32 = 96
        static let functionKey6: UInt32 = 97
        static let functionKey7: UInt32 = 98
        static let functionKey8: UInt32 = 100
        static let functionKey9: UInt32 = 101
        static let functionKey10: UInt32 = 109
        static let functionKey11: UInt32 = 103
        static let functionKey12: UInt32 = 111

        // Letters (a-z)
        static let keyA: UInt32 = 0
        static let keyB: UInt32 = 11
        static let keyC: UInt32 = 8
        static let keyD: UInt32 = 2
        static let keyE: UInt32 = 14
        static let keyM: UInt32 = 46
        static let keyS: UInt32 = 1
        static let keyV: UInt32 = 9
    }

    /// Register a common hotkey configuration
    @discardableResult
    func registerStartStop(handler: @escaping HotkeyHandler) -> UInt32? {
        // Default: Cmd+Shift+Space
        return register(
            keyCode: KeyCode.space,
            modifiers: Modifiers.commandShift,
            handler: handler
        )
    }
}
