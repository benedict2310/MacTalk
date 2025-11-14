# MacTalk Localization Guide

**Version:** 1.0
**Last Updated:** 2025-10-22
**Target:** v1.1+ (Preparation in Phase 5)

---

## Overview

MacTalk is prepared for internationalization and localization. This guide covers how to add support for new languages and maintain translations.

---

## Current Status

- **Base Language:** English (en)
- **Localization Ready:** Yes (all strings externalized)
- **Supported Languages (v1.0):** English only
- **Planned Languages (v1.1+):** Spanish, French, German, Japanese, Chinese

---

## String Externalization

All user-facing strings should use `NSLocalizedString`:

### Basic Usage

```swift
// Format:
NSLocalizedString("key", comment: "Description for translators")

// Example:
let title = NSLocalizedString("menu.start_recording",
                               comment: "Menu item to start recording")
```

### With Arguments

```swift
// Format strings with placeholders
let message = String(format:
    NSLocalizedString("model.download_progress",
                      comment: "Model download progress message"),
    modelName,
    percentage
)

// In Localizable.strings:
// "model.download_progress" = "Downloading %@ (%d%%)";
```

### Plurals

```swift
// Use .stringsdict for proper pluralization
let count = transcripts.count
let message = String(format:
    NSLocalizedString("transcript.count",
                      comment: "Number of transcripts"),
    count
)

// In Localizable.stringsdict:
/*
<key>transcript.count</key>
<dict>
    <key>NSStringLocalizedFormatKey</key>
    <string>%#@transcripts@</string>
    <key>transcripts</key>
    <dict>
        <key>NSStringFormatSpecTypeKey</key>
        <string>NSStringPluralRuleType</string>
        <key>NSStringFormatValueTypeKey</key>
        <string>d</string>
        <key>zero</key>
        <string>No transcripts</string>
        <key>one</key>
        <string>1 transcript</string>
        <key>other</key>
        <string>%d transcripts</string>
    </dict>
</dict>
*/
```

---

## Localization Keys Structure

Use hierarchical naming convention:

```
category.subcategory.specific_item

Examples:
- menu.file.open
- menu.edit.copy
- button.start_recording
- label.microphone_level
- message.error.model_not_found
- alert.permission.microphone_denied
```

### Current Keys

**Menu Items:**
```
menu.start_mic_only
menu.start_mic_plus_app
menu.stop_recording
menu.settings
menu.check_permissions
menu.about
menu.quit
```

**Buttons:**
```
button.start
button.stop
button.select
button.cancel
button.ok
```

**Labels:**
```
label.live_transcript
label.microphone_level
label.app_audio_level
label.model_selection
label.language_selection
```

**Messages:**
```
message.recording_started
message.recording_stopped
message.app_audio_lost
message.fallback_to_mic
message.model_loading
message.model_not_found
```

**Errors:**
```
error.microphone_permission_denied
error.screen_recording_permission_denied
error.model_load_failed
error.transcription_failed
error.audio_capture_failed
```

---

## Setup Localization

### 1. Create Base Localization

```bash
# In Xcode project
# 1. Select project in navigator
# 2. Select target
# 3. Info tab → Localizations → + → Add language

# Or manually create:
mkdir MacTalk/en.lproj
touch MacTalk/en.lproj/Localizable.strings
```

### 2. Export Strings

```bash
# Extract all NSLocalizedString calls
find MacTalk -name "*.swift" -print0 | \
    xargs -0 genstrings -o MacTalk/en.lproj

# Or use Xcode:
# Editor → Export For Localization...
```

### 3. Create Translation Files

```bash
# For each new language, copy base strings
cp MacTalk/en.lproj/Localizable.strings MacTalk/es.lproj/Localizable.strings

# Edit MacTalk/es.lproj/Localizable.strings
# Translate all values (keep keys unchanged)
```

---

## Translation Process

### Workflow

1. **Development**
   - Add `NSLocalizedString` to all user-facing strings
   - Use descriptive keys and comments

2. **String Export**
   ```bash
   xcodebuild -exportLocalizations \
       -project MacTalk.xcodeproj \
       -localizationPath Localizations
   ```

3. **Translation**
   - Send `.xliff` files to translators
   - Or use translation management platform (Crowdin, Lokalise, etc.)

4. **Import**
   ```bash
   xcodebuild -importLocalizations \
       -project MacTalk.xcodeproj \
       -localizationPath Localizations/es.xliff
   ```

5. **Testing**
   - Test each language in UI
   - Verify layout (especially RTL languages)
   - Check truncation and wrapping

---

## Language-Specific Considerations

### Text Length

Different languages have different text lengths:

| Language | Expansion Factor |
|----------|------------------|
| German   | +30-40% longer  |
| French   | +20-30% longer  |
| Spanish  | +20-30% longer  |
| Japanese | -20% shorter    |
| Chinese  | -30% shorter    |

**Solution:** Design UI with flexible layouts

```swift
// ✅ Good: Flexible width
label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

// ❌ Bad: Fixed width
label.widthAnchor.constraint(equalToConstant: 100)
```

### Right-to-Left (RTL) Languages

For Arabic, Hebrew:

```swift
// Enable automatic RTL support
view.userInterfaceLayoutDirection = .leftToRight  // or .rightToLeft

// Use leading/trailing instead of left/right
view.leadingAnchor.constraint(equalTo: superview.leadingAnchor)

// Images
let flippedImage = image.withHorizontallyFlippedOrientation()
```

### Date and Time

```swift
// ✅ Good: Locale-aware formatting
let formatter = DateFormatter()
formatter.dateStyle = .medium
formatter.timeStyle = .short
formatter.locale = Locale.current
let dateString = formatter.string(from: date)

// ❌ Bad: Hardcoded format
let dateString = "MM/DD/YYYY"  // US-specific
```

### Numbers

```swift
// ✅ Good: Locale-aware
let formatter = NumberFormatter()
formatter.numberStyle = .decimal
let numberString = formatter.string(from: NSNumber(value: 1234.56))

// ❌ Bad: Hardcoded
let numberString = "1,234.56"  // US-specific
```

---

## Testing Localizations

### Change Language in App

```swift
// For testing, temporarily override locale
UserDefaults.standard.set(["es"], forKey: "AppleLanguages")
UserDefaults.standard.synchronize()

// Restart app to see changes
```

### Pseudo-Localization

Test UI flexibility with exaggerated strings:

```
"Start Recording" → "[!!! Śţàŕţ Ŕēćōŕďîñğ !!!]"
```

This reveals:
- Truncation issues
- Layout problems
- Missing localizations

### Test Checklist

- [ ] All text strings localized
- [ ] No hardcoded strings in UI
- [ ] Layout handles longer text
- [ ] No truncation of important text
- [ ] RTL languages mirror correctly
- [ ] Dates/times formatted correctly
- [ ] Numbers formatted correctly
- [ ] Images have text alternatives
- [ ] Keyboard shortcuts work in all languages

---

## Localizable.strings Template

```
/* MacTalk Localizations - English (Base) */

/* Menu Items */
"menu.start_mic_only" = "Start (Mic Only)";
"menu.start_mic_plus_app" = "Start (Mic + App Audio)";
"menu.stop_recording" = "Stop Recording";
"menu.settings" = "Settings...";
"menu.check_permissions" = "Check Permissions";
"menu.about" = "About MacTalk";
"menu.quit" = "Quit MacTalk";

/* Buttons */
"button.start" = "Start";
"button.stop" = "Stop";
"button.select" = "Select";
"button.cancel" = "Cancel";
"button.ok" = "OK";

/* Labels */
"label.live_transcript" = "Live Transcript";
"label.microphone_level" = "Microphone Level";
"label.app_audio_level" = "App Audio Level";
"label.model_selection" = "Model";
"label.language_selection" = "Language";

/* Settings */
"settings.general" = "General";
"settings.output" = "Output";
"settings.audio" = "Audio";
"settings.advanced" = "Advanced";
"settings.permissions" = "Permissions";

/* Messages */
"message.recording_started" = "Recording started";
"message.recording_stopped" = "Recording stopped";
"message.app_audio_lost" = "App audio lost. Retrying...";
"message.fallback_to_mic" = "Switched to mic-only mode";
"message.model_loading" = "Loading model...";

/* Errors */
"error.microphone_permission_denied" = "Microphone permission denied";
"error.screen_recording_permission_denied" = "Screen recording permission denied";
"error.model_not_found" = "Model file not found: %@";
"error.model_load_failed" = "Failed to load model";
"error.transcription_failed" = "Transcription failed";
"error.audio_capture_failed" = "Failed to capture audio";

/* Alerts */
"alert.permission.title" = "Permission Required";
"alert.permission.microphone" = "MacTalk needs microphone access to transcribe your voice.";
"alert.permission.screen_recording" = "MacTalk needs screen recording permission to capture app audio.";
"alert.permission.accessibility" = "MacTalk needs accessibility permission for auto-paste.";

/* Notifications */
"notification.transcription_complete" = "Transcription Complete";
"notification.copied_to_clipboard" = "Text copied to clipboard";
```

---

## Tools & Resources

### Translation Management

- **Crowdin:** https://crowdin.com/
- **Lokalise:** https://lokalise.com/
- **POEditor:** https://poeditor.com/

### Testing

- **Pseudo-Localization:** Test UI flexibility
- **Xcode Localization Preview:** Preview UI in different languages
- **Language Switcher:** Test in-app language switching

### Guidelines

- [Apple Internationalization Guide](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPInternational/)
- [Unicode CLDR](https://cldr.unicode.org/) - Locale data
- [iOS Human Interface Guidelines - Localization](https://developer.apple.com/design/human-interface-guidelines/localization)

---

## Future Plans

### v1.1 (Planned)

- [ ] Add Spanish (es) localization
- [ ] Add French (fr) localization
- [ ] Add German (de) localization

### v1.2 (Planned)

- [ ] Add Japanese (ja) localization
- [ ] Add Chinese Simplified (zh-Hans) localization
- [ ] Add Chinese Traditional (zh-Hant) localization

### v2.0 (Planned)

- [ ] Add Arabic (ar) - RTL support
- [ ] Add Portuguese (pt) localization
- [ ] Add Italian (it) localization
- [ ] Community translations via Crowdin

---

## Contributing Translations

Want to help translate MacTalk?

1. Fork the repository
2. Create localization directory: `MacTalk/{language-code}.lproj/`
3. Copy `en.lproj/Localizable.strings` to your language directory
4. Translate all string values (keep keys unchanged)
5. Test the translation
6. Submit a pull request

**Guidelines:**
- Maintain consistent terminology
- Keep UI strings concise
- Preserve placeholder format (%@, %d, etc.)
- Test in the actual UI
- Include screenshots in PR

---

**Document Version:** 1.0
**Last Updated:** 2025-10-22
**Next Review:** Before v1.1 localization effort
