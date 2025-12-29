# S.03.1g - Language Auto-Detect UX

**Epic:** Real-Time Streaming Transcription
**Status:** Draft
**Date:** 2025-12-14
**Dependency:** S.03.1a (requires streaming segments)
**Priority:** Low

---

## 1. Objective

Surface Parakeet's automatic language detection in the UI and allow users to pin a language for session stability.

**Goal:** Users see which language is being transcribed and can lock to a specific language to prevent detection jitter.

---

## 2. Background

Parakeet-v3 supports 25 European languages with automatic detection:
- English, German, French, Spanish, Italian, Portuguese
- Dutch, Polish, Russian, Ukrainian, Czech, Romanian
- Hungarian, Swedish, Norwegian, Danish, Finnish
- Greek, Turkish, Bulgarian, Croatian, Slovak, Slovenian
- And more...

The model automatically detects language per segment, which can cause:
- Jitter when switching between similar languages
- Confusion for multilingual speakers
- Inconsistent formatting/punctuation per language

---

## 3. Architecture Context & Reuse

- `MacTalk/MacTalk/Audio/ASREngine.swift` defines `ASRPartial`/`ASRFinalSegment`; extend these to include `detectedLanguage`.
- `ParakeetEngine` already maps word timings; add language extraction without re-resampling audio.
- UI should surface language in the same places partials/finals are shown (HUD/caption strip) and in Settings.

## 4. Acceptance Criteria

- [ ] Detected language shown in HUD (e.g., small "EN" badge)
- [ ] Detected language shown in Settings engine status
- [ ] User can pin/lock to a specific language
- [ ] When pinned, Parakeet uses that language exclusively
- [ ] Language preference persisted across sessions
- [ ] Language shown in exported transcripts (SRT/VTT)

---

## 5. Implementation Plan

### Step 1: Extend ASR Protocol

```swift
// In ASREngine.swift
struct ASRFinalSegment {
    let text: String
    let words: [ASRWord]
    let detectedLanguage: String?  // NEW: ISO 639-1 code (e.g., "en", "de")
}

struct ASRPartial {
    let text: String
    let words: [ASRWord]
    let detectedLanguage: String?  // NEW
}
```

### Step 2: ParakeetEngine Language Extraction

```swift
// In ParakeetEngine
func process(_ buffer: AVAudioPCMBuffer, language: String?) async throws -> ASRPartial? {
    let result = try await core.transcribe(buffer: buffer)
    let words = mapWords(from: result)
    let detectedLanguage = result.language ?? inferLanguage(from: result.text)
    let partial = ASRPartial(text: result.text, words: words, detectedLanguage: detectedLanguage)
    partialHandler?(partial)
    return partial
}

func finalize(_ buffer: AVAudioPCMBuffer, language: String?) async throws -> ASRFinalSegment? {
    let result = try await core.transcribe(buffer: buffer)
    let words = mapWords(from: result)
    let detectedLanguage = result.language ?? inferLanguage(from: result.text)
    return ASRFinalSegment(text: result.text, words: words, detectedLanguage: detectedLanguage)
}

// Fallback language inference if API doesn't expose it
private func inferLanguage(from text: String) -> String? {
    // Use NLLanguageRecognizer as fallback
    let recognizer = NLLanguageRecognizer()
    recognizer.processString(text)
    return recognizer.dominantLanguage?.rawValue
}
```

### Step 3: Language Settings

```swift
extension AppSettings {
    /// User's preferred language (nil = auto-detect)
    var preferredLanguage: String? {
        get { UserDefaults.standard.string(forKey: "preferredLanguage") }
        set { UserDefaults.standard.set(newValue, forKey: "preferredLanguage") }
    }

    /// Lock to preferred language (ignore auto-detection)
    var languageLocked: Bool {
        get { UserDefaults.standard.bool(forKey: "languageLocked") }
        set { UserDefaults.standard.set(newValue, forKey: "languageLocked") }
    }
}
```

### Step 4: HUD Language Badge

```swift
// In HUDWindowController
private let languageBadge = NSTextField(labelWithString: "")

func setupLanguageBadge() {
    languageBadge.font = .systemFont(ofSize: 10, weight: .medium)
    languageBadge.textColor = .secondaryLabelColor
    languageBadge.backgroundColor = NSColor.black.withAlphaComponent(0.3)
    languageBadge.isBordered = false
    languageBadge.wantsLayer = true
    languageBadge.layer?.cornerRadius = 4

    // Position in corner of HUD
    contentView.addSubview(languageBadge)
    // Layout constraints...
}

func updateLanguage(_ code: String?) {
    guard let code = code else {
        languageBadge.isHidden = true
        return
    }

    languageBadge.isHidden = false
    languageBadge.stringValue = " \(code.uppercased()) "

    // Show lock icon if pinned
    if AppSettings.shared.languageLocked {
        languageBadge.stringValue = " \(code.uppercased()) 🔒 "
    }
}
```

### Step 5: Settings UI

```swift
// In SettingsWindowController - Advanced tab
func setupLanguageSettings() {
    // Language dropdown
    let languagePopup = NSPopUpButton()
    languagePopup.addItem(withTitle: "Auto-detect")
    languagePopup.menu?.addItem(NSMenuItem.separator())

    // Add supported languages
    let languages = [
        ("en", "English"),
        ("de", "German"),
        ("fr", "French"),
        ("es", "Spanish"),
        ("it", "Italian"),
        // ... more
    ]

    for (code, name) in languages {
        let item = NSMenuItem(title: name, action: nil, keyEquivalent: "")
        item.representedObject = code
        languagePopup.menu?.addItem(item)
    }

    // Lock checkbox
    let lockCheckbox = NSButton(checkboxWithTitle: "Lock to selected language", target: self, action: #selector(toggleLanguageLock))
}
```

### Step 6: Engine Configuration

```swift
// In TranscriptionController, pass pinned language into process/finalize
let pinnedLanguage = AppSettings.shared.languageLocked
    ? AppSettings.shared.preferredLanguage
    : nil

let partial = try await engine.process(samples: chunkSamples, language: pinnedLanguage)
let final = try await engine.finalize(samples: allSamples, language: pinnedLanguage)

// In ParakeetEngineCore, pass language if FluidAudio exposes it
// manager.setLanguage(pinnedLanguage) or equivalent (if supported)
```

---

## 6. Supported Languages

Display in Settings with native names:

| Code | English Name | Native Name |
|------|--------------|-------------|
| en | English | English |
| de | German | Deutsch |
| fr | French | Français |
| es | Spanish | Español |
| it | Italian | Italiano |
| pt | Portuguese | Português |
| nl | Dutch | Nederlands |
| pl | Polish | Polski |
| ru | Russian | Русский |
| uk | Ukrainian | Українська |
| cs | Czech | Čeština |
| ro | Romanian | Română |
| hu | Hungarian | Magyar |
| sv | Swedish | Svenska |
| no | Norwegian | Norsk |
| da | Danish | Dansk |
| fi | Finnish | Suomi |
| el | Greek | Ελληνικά |
| tr | Turkish | Türkçe |
| bg | Bulgarian | Български |
| hr | Croatian | Hrvatski |
| sk | Slovak | Slovenčina |
| sl | Slovenian | Slovenščina |

---

## 7. Test Plan

### Unit Tests
- Language detection fallback (NLLanguageRecognizer)
- Settings persistence
- Badge display logic

### Manual Testing
- Speak in different languages, verify badge updates
- Pin to German, verify English text shows German formatting
- Test export includes language metadata

---

## 8. Files Summary

### Modified Files
- `MacTalk/MacTalk/Audio/ASREngine.swift` - Add detectedLanguage to ASRPartial/ASRFinalSegment
- `MacTalk/MacTalk/Whisper/NativeWhisperEngine.swift` - Populate detectedLanguage (where possible)
- `MacTalk/MacTalk/Whisper/ParakeetEngine.swift` - Extract language from result
- `MacTalk/MacTalk/TranscriptionController.swift` - Pass pinned language into engine calls
- `MacTalk/MacTalk/HUDWindowController.swift` - Language badge
- `MacTalk/MacTalk/SettingsWindowController.swift` - Language settings UI
- `MacTalk/MacTalk/Utilities/AppSettings.swift` - Language preferences
