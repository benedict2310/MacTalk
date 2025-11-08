//
//  ShortcutRecorderView.swift
//  MacTalk
//
//  Custom view for recording keyboard shortcuts
//

import AppKit
import Carbon

/// A view that captures and displays keyboard shortcuts
final class ShortcutRecorderView: NSView {

    // MARK: - Properties

    var shortcut: KeyboardShortcut? {
        didSet {
            updateDisplay()
            onShortcutChanged?(shortcut)
        }
    }

    var onShortcutChanged: ((KeyboardShortcut?) -> Void)?

    private let label = NSTextField(labelWithString: "Click to record")
    private let clearButton = NSButton(title: "✕", target: nil, action: nil)
    private var isRecording = false
    private var eventMonitor: Any?

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    deinit {
        stopRecording()
    }

    // MARK: - UI Setup

    private func setupUI() {
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        // Label
        label.isEditable = false
        label.isBordered = false
        label.backgroundColor = .clear
        label.alignment = .center
        label.textColor = .secondaryLabelColor
        label.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        label.frame = NSRect(x: 5, y: 0, width: bounds.width - 30, height: bounds.height)
        label.autoresizingMask = [.width, .height]
        addSubview(label)

        // Clear button
        clearButton.frame = NSRect(x: bounds.width - 25, y: (bounds.height - 20) / 2, width: 20, height: 20)
        clearButton.autoresizingMask = [.minXMargin, .maxYMargin, .minYMargin]
        clearButton.bezelStyle = .inline
        clearButton.isBordered = false
        clearButton.target = self
        clearButton.action = #selector(clearShortcut)
        clearButton.isHidden = true
        addSubview(clearButton)

        updateDisplay()
    }

    // MARK: - Display

    private func updateDisplay() {
        if let shortcut = shortcut {
            label.stringValue = shortcut.displayString
            label.textColor = .labelColor
            clearButton.isHidden = false
        } else {
            label.stringValue = isRecording ? "Press shortcut..." : "Click to record"
            label.textColor = .secondaryLabelColor
            clearButton.isHidden = true
        }

        if isRecording {
            layer?.borderColor = NSColor.controlAccentColor.cgColor
            layer?.borderWidth = 2
        } else {
            layer?.borderColor = NSColor.separatorColor.cgColor
            layer?.borderWidth = 1
        }
    }

    // MARK: - Recording

    override func mouseDown(with event: NSEvent) {
        if !isRecording {
            startRecording()
        }
    }

    private func startRecording() {
        isRecording = true
        updateDisplay()
        window?.makeFirstResponder(self)

        // Monitor local key events
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyEvent(event)
            return nil // Consume the event
        }
    }

    private func stopRecording() {
        isRecording = false
        updateDisplay()

        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    private func handleKeyEvent(_ event: NSEvent) {
        guard isRecording else { return }

        // Ignore modifier-only keys
        let isModifierKey = [
            kVK_Command, kVK_Shift, kVK_Option, kVK_Control,
            kVK_RightCommand, kVK_RightShift, kVK_RightOption, kVK_RightControl,
            kVK_Function, kVK_CapsLock
        ].contains(Int(event.keyCode))

        if isModifierKey {
            return
        }

        // Require at least one modifier
        let modifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasModifier = modifierFlags.contains(.command) ||
                         modifierFlags.contains(.control) ||
                         modifierFlags.contains(.option) ||
                         modifierFlags.contains(.shift)

        if !hasModifier {
            NSSound.beep()
            return
        }

        // Create shortcut
        shortcut = KeyboardShortcut(
            keyCode: UInt32(event.keyCode),
            modifierFlags: modifierFlags
        )

        stopRecording()
    }

    @objc private func clearShortcut() {
        shortcut = nil
    }

    override var acceptsFirstResponder: Bool {
        return true
    }

    override func resignFirstResponder() -> Bool {
        stopRecording()
        return super.resignFirstResponder()
    }
}

// MARK: - KeyboardShortcut

struct KeyboardShortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifierFlags: NSEvent.ModifierFlags

    var displayString: String {
        var parts: [String] = []

        if modifierFlags.contains(.control) {
            parts.append("⌃")
        }
        if modifierFlags.contains(.option) {
            parts.append("⌥")
        }
        if modifierFlags.contains(.shift) {
            parts.append("⇧")
        }
        if modifierFlags.contains(.command) {
            parts.append("⌘")
        }

        parts.append(keyCodeToString(keyCode))

        return parts.joined()
    }

    var carbonModifiers: UInt32 {
        var modifiers: UInt32 = 0

        if modifierFlags.contains(.command) {
            modifiers |= UInt32(cmdKey)
        }
        if modifierFlags.contains(.shift) {
            modifiers |= UInt32(shiftKey)
        }
        if modifierFlags.contains(.option) {
            modifiers |= UInt32(optionKey)
        }
        if modifierFlags.contains(.control) {
            modifiers |= UInt32(controlKey)
        }

        return modifiers
    }

    private func keyCodeToString(_ keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Escape: return "⎋"
        case kVK_Delete: return "⌫"
        case kVK_Tab: return "⇥"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        default: return "�"
        }
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case keyCode
        case modifierFlags
    }

    init(keyCode: UInt32, modifierFlags: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try container.decode(UInt32.self, forKey: .keyCode)
        let rawValue = try container.decode(UInt.self, forKey: .modifierFlags)
        modifierFlags = NSEvent.ModifierFlags(rawValue: rawValue)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keyCode, forKey: .keyCode)
        try container.encode(modifierFlags.rawValue, forKey: .modifierFlags)
    }
}
