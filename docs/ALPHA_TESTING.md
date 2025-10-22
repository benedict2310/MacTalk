# MacTalk Alpha Testing Guide

**Version:** 1.0 (Phase 5)
**Last Updated:** 2025-10-22
**Target:** Alpha Testers

---

## Welcome Alpha Testers!

Thank you for participating in the MacTalk alpha testing program. Your feedback is crucial in making MacTalk the best local voice transcription tool for macOS.

---

## Table of Contents

1. [Installation](#installation)
2. [First Launch](#first-launch)
3. [Testing Checklist](#testing-checklist)
4. [Reporting Issues](#reporting-issues)
5. [Feedback Form](#feedback-form)
6. [Known Limitations](#known-limitations)

---

## Installation

### Prerequisites

- macOS 14.0 (Sonoma) or later
- Apple Silicon (M1/M2/M3/M4) recommended
- 8 GB RAM minimum, 16 GB recommended
- 5 GB free disk space

### Installation Steps

1. **Download** the Alpha build from the provided link
2. **Open** the `.dmg` file
3. **Drag** MacTalk to your Applications folder
4. **Launch** MacTalk from Applications or Spotlight

**Important:** On first launch, you may see a warning about an unidentified developer. This is expected for alpha builds. To open:

1. Right-click MacTalk.app in Applications
2. Select "Open"
3. Click "Open" in the dialog

---

## First Launch

### Permission Setup

MacTalk will request the following permissions:

#### 1. Microphone Access (Required)
- **When:** Immediately on first launch
- **Purpose:** Capture your voice for transcription
- **How to grant:** Click "OK" when prompted

#### 2. Screen Recording (Optional - for Mode B)
- **When:** When using "Mic + App Audio" mode
- **Purpose:** Capture app/system audio for call transcription
- **How to grant:** System Settings → Privacy & Security → Screen Recording → Enable MacTalk

#### 3. Accessibility (Optional - for Auto-Paste)
- **When:** When enabling auto-paste feature
- **Purpose:** Automatically paste transcripts at cursor position
- **How to grant:** System Settings → Privacy & Security → Accessibility → Enable MacTalk

### Download Your First Model

1. Click the MacTalk menu bar icon
2. Select "Model → ggml-small-q5_0.gguf" (recommended for testing)
3. MacTalk will show the download location
4. Download the model from: https://huggingface.co/ggerganov/whisper.cpp
5. Place it in: `~/Library/Application Support/MacTalk/Models/`

---

## Testing Checklist

Please test as many scenarios as possible and report any issues.

### Core Functionality

- [ ] **Basic Dictation (Mode A)**
  - [ ] Start recording with hotkey (Cmd+Shift+Space)
  - [ ] Speak a short sentence
  - [ ] Stop recording
  - [ ] Verify transcript appears in HUD
  - [ ] Verify transcript copied to clipboard
  - [ ] Try pasting in TextEdit

- [ ] **App Audio Capture (Mode B)**
  - [ ] Select "Mic + App Audio" from menu
  - [ ] Choose an app from picker (e.g., Safari, Zoom)
  - [ ] Start recording
  - [ ] Play audio or have a conversation
  - [ ] Verify both mic and app audio transcribed

- [ ] **Model Switching**
  - [ ] Try different model sizes (tiny, base, small)
  - [ ] Verify quality differences
  - [ ] Note performance differences

### UI/UX Testing

- [ ] **Menu Bar**
  - [ ] Icon changes when recording (🎙️ → 🔴)
  - [ ] All menu items accessible
  - [ ] Model selection works

- [ ] **HUD Overlay**
  - [ ] Appears during recording
  - [ ] Shows live transcript
  - [ ] Level meters animate smoothly
  - [ ] Can be dragged to reposition
  - [ ] Disappears after recording

- [ ] **Settings Window (Cmd+,)**
  - [ ] General tab settings persist
  - [ ] Output tab settings work (auto-paste, clipboard)
  - [ ] Audio tab settings apply
  - [ ] Advanced tab model/language selection
  - [ ] Permissions tab shows correct status

### Advanced Features

- [ ] **Auto-Paste**
  - [ ] Enable in Settings or menu
  - [ ] Start recording in a text editor
  - [ ] Verify transcript auto-pastes at cursor

- [ ] **Language Selection**
  - [ ] Change language in Settings
  - [ ] Test transcription in selected language

- [ ] **App Picker Search**
  - [ ] Open app picker for Mode B
  - [ ] Test search/filter functionality
  - [ ] Verify app icons display

### Performance Testing

- [ ] **Short Utterances** (< 5 seconds)
  - [ ] Latency acceptable?
  - [ ] Accuracy good?

- [ ] **Long Recordings** (> 30 seconds)
  - [ ] No crashes or hangs?
  - [ ] Memory usage acceptable?
  - [ ] Final transcript complete?

- [ ] **Rapid Start/Stop**
  - [ ] Start and stop recording quickly multiple times
  - [ ] Any issues?

- [ ] **Background Apps**
  - [ ] Use MacTalk while other apps running
  - [ ] Performance impact on other apps?

### Edge Cases

- [ ] **No microphone input** (silence)
  - [ ] How does it handle?

- [ ] **Very long transcript** (> 2 minutes)
  - [ ] Does it complete?
  - [ ] Memory usage?

- [ ] **App closure during Mode B**
  - [ ] Close target app during recording
  - [ ] Fallback to mic-only?
  - [ ] Notification shown?

- [ ] **Network disconnected**
  - [ ] Verify works offline
  - [ ] Models already downloaded

- [ ] **Battery mode** (MacBook only)
  - [ ] On battery vs. plugged in
  - [ ] Performance differences?

---

## Reporting Issues

### How to Report

**Option 1: GitHub Issues (Preferred)**
1. Go to: https://github.com/yourusername/MacTalk/issues
2. Click "New Issue"
3. Use the template below

**Option 2: Email**
- Send to: alpha-testing@mactalk.app (if provided)
- Use subject: "MacTalk Alpha - [Brief Description]"

### Issue Template

```markdown
**Issue Title:** Brief description

**Description:**
Detailed description of the issue

**Steps to Reproduce:**
1. Step 1
2. Step 2
3. Step 3

**Expected Behavior:**
What you expected to happen

**Actual Behavior:**
What actually happened

**Environment:**
- macOS Version: (e.g., 14.5)
- Mac Model: (e.g., M4 MacBook Pro)
- MacTalk Version: (see About MacTalk)
- Model Used: (e.g., ggml-small-q5_0.gguf)

**Screenshots/Logs:**
Attach any relevant screenshots or logs

**Additional Context:**
Any other relevant information
```

### Priority Levels

- **P0 - Critical:** App crashes, data loss, completely unusable
- **P1 - High:** Major feature broken, significant usability issue
- **P2 - Medium:** Minor feature issue, workaround available
- **P3 - Low:** Cosmetic issue, enhancement request

---

## Feedback Form

Please fill out this form after testing: [Link to Google Form / Survey]

### Key Questions

1. **Overall Experience** (1-5 stars)
   - How would you rate your overall experience?

2. **Transcription Accuracy** (1-5 stars)
   - How accurate were the transcriptions?

3. **Performance** (1-5 stars)
   - How was the app's performance (speed, responsiveness)?

4. **UI/UX** (1-5 stars)
   - How intuitive and easy to use is the interface?

5. **Most Useful Feature**
   - What feature did you find most useful?

6. **Missing Features**
   - What features would you like to see added?

7. **Bugs Encountered**
   - List any bugs you encountered

8. **Use Cases**
   - How do you plan to use MacTalk?
   - What apps would you use it with?

9. **Comparison to Alternatives**
   - Have you used similar tools? How does MacTalk compare?

10. **Overall Feedback**
    - Any additional comments or suggestions?

---

## Known Limitations

Please be aware of these known limitations in the alpha:

### Performance

- Large models (medium, large-v3-turbo) may be slow on M1
- First transcription may take longer (model loading)
- GPU usage can be high during active transcription

### Features

- No model auto-download (manual download required)
- No speaker diarization (can't distinguish speakers)
- No export to SRT/VTT (coming in v1.2)
- No transcript history (coming in v1.1)

### Compatibility

- Requires macOS 14.0+ (Sonoma)
- Intel Macs not optimized (may work but slower)
- Some apps may not work with Mode B (security restrictions)

### UI

- HUD position resets on quit (not yet persisted)
- No dark mode specific styling
- Settings window tabs not keyboard navigable (yet)

---

## Testing Tips

### Best Practices

1. **Start Simple**
   - Begin with short utterances
   - Use Mode A (mic-only) first
   - Try Mode B after basics work

2. **Test Incrementally**
   - One feature at a time
   - Note what works before moving on

3. **Document Everything**
   - Take screenshots of issues
   - Note exact steps to reproduce
   - Check Console.app for error logs

4. **Vary Conditions**
   - Test in quiet and noisy environments
   - Try different accents/speech patterns
   - Test with different apps for Mode B

5. **Performance Monitoring**
   - Open Activity Monitor to check CPU/Memory
   - Note any fan noise or heat
   - Test on battery vs. plugged in

### Getting Logs

If you encounter issues, logs are helpful:

```bash
# View MacTalk logs in Console.app
# 1. Open Console.app
# 2. Search for "MacTalk"
# 3. Filter by "Performance" category for performance logs

# Or via command line:
log show --predicate 'subsystem == "com.mactalk.app"' --last 1h
```

---

## Frequently Asked Questions

### Q: Which model should I use for testing?

**A:** Start with `ggml-small-q5_0.gguf` - it's a good balance of speed and accuracy. Try `tiny` or `base` if it's too slow, or `medium` if you need better accuracy.

### Q: The app says "Model not found" - what do I do?

**A:** Download the model manually from Hugging Face and place it in `~/Library/Application Support/MacTalk/Models/`. The app shows the exact path in the error message.

### Q: Can I use MacTalk with Zoom/Teams/FaceTime?

**A:** Yes! Use Mode B (Mic + App Audio) and select the app from the picker. Note: You'll need to grant Screen Recording permission.

### Q: Why is transcription slow?

**A:** Large models are slower. Try a smaller model. Also, first transcription loads the model into memory, which takes a few seconds.

### Q: Does MacTalk send my audio to the cloud?

**A:** No! All processing happens locally on your Mac. Zero network calls during transcription. You can verify this with Little Snitch or similar tools.

### Q: The auto-paste feature doesn't work - why?

**A:** You need to grant Accessibility permission. Go to System Settings → Privacy & Security → Accessibility → Enable MacTalk.

---

## Thank You!

Your testing and feedback are invaluable. Thank you for helping make MacTalk better!

**Questions?** Contact: alpha-testing@mactalk.app

**Updates:** Check back for new alpha builds and release notes

---

**Alpha Testing Program**
- Start Date: [TBD]
- Expected Duration: 2-3 weeks
- Target: 5-10 testers
- Goal: Validate core functionality, identify critical bugs, gather UX feedback

---

**Version History:**
- v1.0-alpha.1 (2025-10-22): Initial alpha release
