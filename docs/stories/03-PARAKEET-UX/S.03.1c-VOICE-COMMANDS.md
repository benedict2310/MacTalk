# S.03.1c - Voice Commands (Hotwords)

**Epic:** Real-Time Streaming Transcription
**Status:** Draft
**Date:** 2025-12-14
**Dependency:** S.03.1a (Streaming Infrastructure)
**Priority:** Medium

---

## 1. Objective

Enable voice-activated commands during dictation that execute actions rather than being transcribed.

**Goal:** Users can say "new line", "delete last sentence", etc., and have those commands execute immediately.

---

## 2. Architecture Context & Reuse

- Run command detection on stabilized partials (after `PartialDiffer` in S.03.1a).
- Apply mutations through the streaming text controller (e.g., `StreamingManager`) rather than direct UI edits.
- Clipboard/paste operations must go through `ClipboardManager` (main thread only).

## 3. Acceptance Criteria

- [ ] Commands are recognized within partials and consumed (not pasted)
- [ ] Supported commands: "new line", "new paragraph", "delete that", "undo", "send"
- [ ] Command execution latency <200ms from recognition
- [ ] Cool-down period (600ms) prevents double-triggers
- [ ] Commands work in any language that Parakeet supports (with localized triggers)
- [ ] Commands can be enabled/disabled per-command in Settings

---

## 4. Supported Commands

### Core Commands (MVP)

| Voice Trigger | Action | Notes |
|--------------|--------|-------|
| "new line" | Insert `\n` | Common dictation command |
| "new paragraph" | Insert `\n\n` | Double line break |
| "period" | Insert `.` | When not naturally detected |
| "comma" | Insert `,` | When not naturally detected |
| "question mark" | Insert `?` | Explicit punctuation |

### Extended Commands (Post-MVP)

| Voice Trigger | Action | Notes |
|--------------|--------|-------|
| "delete that" | Remove last segment | Undo last finalized text |
| "delete last word" | Remove last word | Fine-grained deletion |
| "delete last sentence" | Remove last sentence | Sentence-level deletion |
| "undo" | Revert last action | General undo |
| "send" / "done" | Finalize and paste | End dictation, paste result |
| "insert timestamp" | Insert current time | `[14:32]` format |
| "scratch that" | Clear current partial | Discard in-progress text |

---

## 5. Implementation Plan

### Step 1: Command Registry

```swift
/// Voice command definition
struct VoiceCommand {
    let id: String
    let triggers: [String]           // Multiple phrases per command
    let action: VoiceCommandAction
    var isEnabled: Bool = true
    let cooldownMs: Int = 600
}

enum VoiceCommandAction {
    case insertText(String)
    case deleteLastWord
    case deleteLastSentence
    case deleteLastSegment
    case undo
    case finalize
    case insertTimestamp
    case clearPartial
}

/// Registry of all available commands
final class VoiceCommandRegistry {
    static let shared = VoiceCommandRegistry()

    private(set) var commands: [VoiceCommand] = [
        VoiceCommand(
            id: "newLine",
            triggers: ["new line", "newline", "line break"],
            action: .insertText("\n")
        ),
        VoiceCommand(
            id: "newParagraph",
            triggers: ["new paragraph", "paragraph break"],
            action: .insertText("\n\n")
        ),
        VoiceCommand(
            id: "period",
            triggers: ["period", "full stop", "dot"],
            action: .insertText(".")
        ),
        // ... more commands
    ]

    func command(matching text: String) -> VoiceCommand? {
        let normalized = text.lowercased().trimmingCharacters(in: .whitespaces)
        return commands.first { cmd in
            cmd.isEnabled && cmd.triggers.contains { normalized.hasSuffix($0) }
        }
    }
}
```

**File:** `MacTalk/MacTalk/Audio/VoiceCommandRegistry.swift`

### Step 2: Command Detector

```swift
/// Detects and handles voice commands in transcription stream
final class VoiceCommandHandler {
    private let registry = VoiceCommandRegistry.shared
    private var lastCommandTime: Date?
    private let cooldownInterval: TimeInterval = 0.6

    var onCommandDetected: ((VoiceCommand, String) -> Void)?  // (command, remainingText)

    /// Process partial text, return text with commands removed
    func process(partial: String) -> String {
        // Check cooldown
        if let lastTime = lastCommandTime,
           Date().timeIntervalSince(lastTime) < cooldownInterval {
            return partial
        }

        // Check for command at end of partial
        if let command = registry.command(matching: partial) {
            lastCommandTime = Date()

            // Remove command from text
            let trigger = command.triggers.first { partial.lowercased().hasSuffix($0) }!
            let remainingText = String(partial.dropLast(trigger.count))
                .trimmingCharacters(in: .whitespaces)

            onCommandDetected?(command, remainingText)
            return remainingText
        }

        return partial
    }

    func reset() {
        lastCommandTime = nil
    }
}
```

**File:** `MacTalk/MacTalk/Audio/VoiceCommandHandler.swift`

### Step 3: Command Executor

```swift
/// Executes voice command actions
final class VoiceCommandExecutor {
    weak var clipboardManager: ClipboardManager?
    weak var streamingManager: StreamingManager?

    func execute(_ command: VoiceCommand) {
        switch command.action {
        case .insertText(let text):
            // Append to current transcription
            streamingManager?.injectText(text)

        case .deleteLastWord:
            streamingManager?.deleteLastWord()

        case .deleteLastSentence:
            streamingManager?.deleteLastSentence()

        case .deleteLastSegment:
            streamingManager?.deleteLastSegment()

        case .undo:
            streamingManager?.undo()

        case .finalize:
            Task {
                await streamingManager?.finalizeAndPaste()
            }

        case .insertTimestamp:
            let formatter = DateFormatter()
            formatter.dateFormat = "[HH:mm]"
            let timestamp = formatter.string(from: Date())
            streamingManager?.injectText(timestamp)

        case .clearPartial:
            streamingManager?.clearCurrentPartial()
        }

        // Play subtle audio feedback
        NSSound.beep()  // Or custom sound
    }
}
```

**File:** `MacTalk/MacTalk/Audio/VoiceCommandExecutor.swift`

### Step 4: Integration with StreamingManager

```swift
// In StreamingManager
private let commandHandler = VoiceCommandHandler()
private let commandExecutor = VoiceCommandExecutor()

func setupCommandHandling() {
    commandHandler.onCommandDetected = { [weak self] command, remainingText in
        // Execute command
        self?.commandExecutor.execute(command)

        // Update partial with remaining text
        if !remainingText.isEmpty {
            self?.onPartial?(remainingText)
        }
    }
}

// In transcription loop
func processPartial(_ text: String) {
    let processedText = commandHandler.process(partial: text)
    onPartial?(processedText)
}
```

### Step 5: Settings UI

Add command configuration to Settings:

```swift
// In SettingsWindowController - new "Commands" tab
func setupCommandsTab() {
    // Table view with:
    // - Command name
    // - Triggers (editable)
    // - Enabled checkbox

    // Allow users to:
    // - Enable/disable individual commands
    // - Add custom triggers
    // - Reset to defaults
}
```

---

## 6. Localization

Support command triggers in multiple languages:

```swift
// In VoiceCommandRegistry
func loadLocalizedTriggers() {
    // Load from Localizable.strings or JSON
    // "newLine" = "new line|neue zeile|nouvelle ligne"

    for var command in commands {
        if let localizedTriggers = localizedTrigger(for: command.id) {
            command.triggers = localizedTriggers.components(separatedBy: "|")
        }
    }
}
```

---

## 7. Test Plan

### Unit Tests
- `VoiceCommandRegistryTests` - Command matching, trigger variations
- `VoiceCommandHandlerTests` - Detection, cooldown, text cleanup
- `VoiceCommandExecutorTests` - Action execution

### Integration Tests
- Commands detected in streaming flow
- Cooldown prevents rapid re-trigger
- Text properly cleaned after command removal

### Manual Testing
- Speak "new line" mid-sentence, verify line break inserted
- Rapid "new line new line" only triggers once
- "Delete that" removes previous segment

---

## 8. Files Summary

### New Files
- `MacTalk/MacTalk/Audio/VoiceCommandRegistry.swift`
- `MacTalk/MacTalk/Audio/VoiceCommandHandler.swift`
- `MacTalk/MacTalk/Audio/VoiceCommandExecutor.swift`
- `MacTalk/MacTalkTests/VoiceCommandHandlerTests.swift`

### Modified Files
- `MacTalk/MacTalk/Whisper/StreamingManager.swift` - Command integration
- `MacTalk/MacTalk/SettingsWindowController.swift` - Commands tab
- `MacTalk/MacTalk/Utilities/AppSettings.swift` - Command settings

---

## 9. Edge Cases

| Scenario | Handling |
|----------|----------|
| "I said new line" (quoting) | Context-aware: only trigger at natural pause |
| Command in middle of word | Only match at word boundaries |
| Multiple commands in one partial | Process leftmost first, re-check |
| Command while command executing | Cooldown prevents |
