# MacTalk Project Map

- generated_at: `2025-12-23T14:56:27+01:00`
- repo_root: `/Users/bene/Dev-Source-NoBackup/MacTalk`
- git.branch: `feat/swift-6-migration`
- git.commit: `ef132410e6d236f7173a99315d0ec97300b4a4e5`
- git.dirty: `True`

## Structure
- MacTalk/MacTalk: Main macOS app source (Swift/AppKit)
- MacTalk/MacTalkTests: XCTest test target
- Vendor/whisper.cpp: C++ inference engine submodule
- scripts: Build/sign helpers
- docs: Architecture + planning docs

## Key Paths
- AGENTS.md
- README.md
- build.sh
- project.yml
- MacTalk/MacTalk/main.swift
- MacTalk/MacTalk/TranscriptionController.swift
- MacTalk/MacTalk/Audio/AudioCapture.swift
- MacTalk/MacTalk/Audio/ScreenAudioCapture.swift
- MacTalk/MacTalk/Audio/AudioMixer.swift
- MacTalk/MacTalk/Audio/RingBuffer.swift
- MacTalk/MacTalk/Whisper/ModelManager.swift
- MacTalk/MacTalk/Whisper/WhisperBridge.h
- MacTalk/MacTalk/Whisper/WhisperBridge.mm
- docs/development/ARCHITECTURE.md
- docs/development/SETUP.md
- docs/testing/TESTING.md
- scripts/post-build-sign.sh

## Stats
- file_count: `1286`
- truncated_file_count: `18`
- languages: `{"C": 24, "C++": 128, "C++ Header": 37, "C/C++ Header": 101, "JSON": 13, "Markdown": 99, "Objective-C": 9, "Objective-C++": 2, "PropertyList": 4, "Shell": 33, "Swift": 62, "Text": 56, "Unknown": 713, "XcodeProject": 3, "YAML": 2}`
- categories: `{"AppSource": 37, "Docs": 60, "Other": 13, "Scripts": 3, "Tests": 21, "Vendor": 1150, "Xcode": 2}`

## Hotspots (Top Swift Files by LOC)
- MacTalk/MacTalk/StatusBarController.swift: 1197
- MacTalk/MacTalkTests/TranscriptionControllerTests.swift: 868
- MacTalk/MacTalk/SettingsWindowController.swift: 852
- MacTalk/MacTalkTests/HUDWindowControllerTests.swift: 564
- MacTalk/MacTalk/TranscriptionController.swift: 552
- MacTalk/MacTalkTests/NativeWhisperEngineTests.swift: 549
- MacTalk/MacTalkTests/AudioMixerTests.swift: 524
- MacTalk/MacTalkTests/ConcurrencyStressTests.swift: 496
- MacTalk/MacTalkTests/Phase4IntegrationTests.swift: 473
- MacTalk/MacTalkTests/HotkeyManagerTests.swift: 463
- MacTalk/MacTalkTests/AppPickerIntegrationTests.swift: 436
- MacTalk/MacTalkTests/SettingsWindowControllerTests.swift: 421
- MacTalk/MacTalkTests/ScreenAudioCaptureTests.swift: 389
- MacTalk/MacTalk/HUDWindowController.swift: 370
- MacTalk/MacTalkTests/AudioLevelMonitorTests.swift: 336
- MacTalk/MacTalkTests/AudioCaptureIntegrationTests.swift: 333
- MacTalk/MacTalk/UI/ShortcutRecorderView.swift: 328
- MacTalk/MacTalkTests/ModelManagerTests.swift: 295
- MacTalk/MacTalk/Utilities/PerformanceMonitor.swift: 286
- MacTalk/MacTalk/UI/AudioLevelMeterView.swift: 282
- MacTalk/MacTalk/UI/AppPickerWindowController.swift: 279
- MacTalk/MacTalkTests/RingBufferTests.swift: 261
- MacTalk/MacTalk/Whisper/ParakeetModelDownloader.swift: 258
- MacTalk/MacTalkTests/TestHelpers.swift: 251
- MacTalk/MacTalkTests/PermissionsTests.swift: 238

## Commands
- dev_loop: `./build.sh run`
- build_only: `./build.sh`
- clean: `./build.sh clean`
- tests: `xcodebuild test -project MacTalk.xcodeproj -scheme MacTalk`
- xcodegen: `xcodegen generate`

## Outputs (This Directory)
- `project_index.jsonl` (grep-friendly, one JSON per file)
- `project_index.tsv` (path/category/language/size/line_count/imports/symbols)
- `project_map.yaml` (machine-readable summary)

## Grep Examples
- Find all Swift files importing ScreenCaptureKit:
  - `rg '"imports": \[.*ScreenCaptureKit' agent-tools/project-index/project_index.jsonl`
- Find TranscriptionController-related symbols:
  - `rg 'TranscriptionController' agent-tools/project-index/project_index.tsv`

