# MacTalk - AI Agent & Developer Context

> **Note:** This file consolidates project context, workflows, and architectural details. It serves as the primary source of truth for AI agents and developers working on this repository.

---

## Repository Guidelines

**YOU MUST READ ~/Projects/agent-scripts/AGENTS.MD BEFORE ANYTHING (skip if file missing).**

### Project Structure & Modules
- `MacTalk/MacTalk`: Main macOS app source (Audio, Whisper, UI, Utilities). Keep changes small and reuse existing helpers.
- `MacTalk/MacTalkTests`: XCTest coverage for audio, transcription, UI components; mirror new logic with focused tests.
- `scripts/`: Build/sign helpers (`build.sh`, signing scripts).
- `docs/`: Documentation (architecture, stories, design). Root-level generated artifacts—avoid editing except during releases.
- `Vendor/whisper.cpp`: C++ inference engine submodule.
- `project.yml`: XcodeGen configuration (generates `.xcodeproj`).

### Build, Test, Run

**Build script commands:**
| Command | When to Use |
|:--|:--|
| `./build.sh` | Build only, don't launch |
| `./build.sh run` | Build and launch (kills old instance first) |
| `./build.sh clean` | Fresh start (removes DerivedData) |
| `./build.sh reset-perms` | Reset TCC Accessibility permission (when auto-paste breaks) |

**Common workflows:**

```bash
# Normal development
./build.sh run

# Auto-paste stopped working (permission prompt keeps appearing)
./build.sh reset-perms
./build.sh run
# Grant Accessibility permission when prompted

# Fresh start (new clone, weird build issues)
./build.sh clean
./build.sh reset-perms
./build.sh run
```

**Why `reset-perms`?** macOS TCC tracks Accessibility permissions by bundle ID + CDHash. Every rebuild changes the CDHash, so old permission grants don't apply. `reset-perms` clears stale entries so the next grant applies to the current build.

**Other commands:**
- **Run tests:** `xcodebuild test -project MacTalk.xcodeproj -scheme MacTalk` or `Cmd+U` in Xcode.
- **Restart app manually:** `killall MacTalk 2>/dev/null || true; open -n build/Build/Products/Release/MacTalk.app`.

### Coding Style & Naming
- Favor small, typed structs/enums; maintain existing `MARK` organization.
- Use descriptive symbols; match current commit tone.
- 4-space indent; explicit `self` is intentional—do not remove.
- Keep bridging code (Objective-C++) minimal and well-documented.

### Testing Guidelines
- Add/extend XCTest cases under `MacTalk/MacTalkTests/*Tests.swift` (`FeatureNameTests` with `test_caseDescription` methods).
- Always run tests before handoff; add fixtures for new parsing/formatting scenarios.
- After any code change, rebuild and test before declaring completion.
- **Thread Sanitizer:** Use the `MacTalk-TSan` scheme to run tests with Thread Sanitizer enabled:
  ```bash
  xcodebuild test -project MacTalk.xcodeproj -scheme MacTalk-TSan
  ```
  TSan suppressions are in `tsan_suppressions.txt` for known-safe external library races.

### Commit & PR Guidelines
- Commit messages: short imperative clauses (e.g., "Improve audio capture", "Fix HUD positioning"); keep commits scoped.
- PRs/patches should list summary, commands run, screenshots/GIFs for UI changes, and linked issue/reference when relevant.

### Agent Notes
- Use the provided scripts and XcodeGen; avoid adding dependencies or tooling without confirmation.
- Validate behavior against the freshly built bundle; restart via `./build.sh run` to avoid running stale binaries.
- After any code change that affects the app, always rebuild with `./build.sh` and restart the app before validating behavior.
- If you edited code, run `./build.sh run` before handoff; it kills old instances, builds, and relaunches.
- Per user request: after every edit (code or docs), rebuild and restart so the running app reflects the latest changes.
- Keep engine data siloed: when rendering transcription info for an engine (Whisper vs Parakeet), never mix configuration or state from different engines.

### Project Index (Repo Mapping)
- Generate a grep-friendly, machine-readable codebase index: `python3 agent-tools/project-index/index_project.py`
- Outputs (written to `agent-tools/project-index/`):
  - `PROJECT_MAP.md` (human-friendly overview)
  - `project_map.yaml` (machine-readable summary)
  - `project_index.jsonl` (one JSON object per file; best for `rg`)
  - `project_index.tsv` (tab-separated summary; good for `awk/sort`)
- The indexer skips hidden folders and build output (e.g. `build/`, `DerivedData/`, `Vendor/whisper.cpp/build`).

---

## 1. Project Overview

**MacTalk** is a native macOS application for real-time, local voice transcription powered by [Whisper](https://github.com/openai/whisper) (via [whisper.cpp](https://github.com/ggerganov/whisper.cpp)). It focuses on privacy, performance (Metal acceleration), and ease of use.

**Key Features:**
- **Local Processing:** No network calls; all inference happens on-device using Metal-accelerated `whisper.cpp`.
- **Dual Modes:**
    1.  **Mic Only:** Standard dictation.
    2.  **Mic + App Audio:** Captures system/app audio (e.g., Zoom calls) alongside microphone input using `ScreenCaptureKit`.
- **UI:** Lightweight Menu Bar extra and a floating HUD overlay for live transcription visualization.
- **Output:** Copies text to clipboard and optionally simulates `Cmd+V` (Auto-Paste) via Accessibility APIs.

**Tech Stack:**
- **Language:** Swift 6.0 with strict concurrency (AppKit)
- **Core Frameworks:** `AVFoundation`, `ScreenCaptureKit`, `Metal`, `Accelerate`
- **Inference Engine:** `whisper.cpp` (C++ submodule, bridged to Swift)
- **Project Management:** `XcodeGen` (generates `.xcodeproj` from `project.yml`)

---

## 2. Git Workflow (CRITICAL)

**Always follow this workflow. Never commit directly to `main`.**

1.  **Create a Feature Branch:**
    ```bash
    git checkout -b fix/descriptive-name     # For bug fixes
    git checkout -b feat/descriptive-name    # For new features
    ```
    *Naming conventions:* `fix/`, `feat/`, `refactor/`, `docs/`, `test/`.

2.  **Commit Changes:**
    ```bash
    git add .
    git commit -m "feat: description of change"
    ```

3.  **Push & PR:**
    Push to origin and create a Pull Request against the main branch (`claude/mac-whisper-transcription-app-...` or `main`).

4.  **Cleanup:**
    Delete the feature branch after merging.

### Git Safety Rules (MANDATORY)

**ALWAYS COMMIT, NEVER STASH:**
- **NEVER use `git stash`** to save finished or in-progress implementation work. Stashed code is invisible and easily lost.
- **ALWAYS commit your work** to a branch, even if it's incomplete. Use a WIP commit message like `wip: partial implementation of X`.
- If you need to switch contexts, commit to a feature branch first, then switch.

**DANGEROUS COMMANDS - REQUIRE EXPLICIT USER PERMISSION:**
These commands can cause data loss. **NEVER run them without the user explicitly requesting it:**
- `git stash` / `git stash drop` / `git stash clear`
- `git reset --hard`
- `git clean -fd`
- `git checkout -- <file>` (discards changes)
- `git branch -D` (force delete)
- `git push --force` / `git push -f`
- `git rebase` (can rewrite history)
- Any command with `--force` or `-f` flags

**If you find stashed or uncommitted work:**
- Alert the user immediately
- Help recover and commit it to a proper branch
- Never assume stashed code is unimportant

---

## 3. Build System & Setup

### Prerequisites
- macOS 14.0+ (Sonoma) or later
- Xcode 15.0+
- Apple Silicon (M1+) recommended

### A. Build `whisper.cpp` (Required First)
`whisper.cpp` is a submodule. It must be built with Metal support before the main app can link to it.
```bash
cd Vendor/whisper.cpp
mkdir -p build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release -DGGML_METAL=ON
cmake --build . --config Release -j $(sysctl -n hw.ncpu)
cd ../../..
```

### B. Generate Xcode Project
The project file (`.xcodeproj`) is **generated**. Do not edit it manually. Modify `project.yml` instead.
```bash
# Regenerate project
xcodegen generate

# Open project
open MacTalk.xcodeproj
```

### C. Build & Run
Use the helper script for the easiest workflow:
```bash
# Build and Run
./build.sh run

# Build only
./build.sh

# Clean
./build.sh clean
```

**Manual xcodebuild:**
```bash
xcodebuild -project MacTalk.xcodeproj -scheme MacTalk -configuration Release -arch arm64 ONLY_ACTIVE_ARCH=YES build
```
*Note: The build process includes a post-build script that automatically re-signs `whisper.cpp` dylibs to match the app's Team ID, fixing crashes on macOS 26/Xcode 26.*

---

## 4. Architecture & Components

### Core Components
*   **Audio Pipeline (`Audio/`):**
    *   `AudioCapture.swift`: Microphone input (AVAudioEngine).
    *   `ScreenAudioCapture.swift`: System/App audio (ScreenCaptureKit).
    *   `AudioMixer.swift`: Mixes sources and converts to **16kHz Mono Float32** (Whisper format).
    *   `RingBuffer.swift`: Lock-free circular buffer for thread-safe audio transfer.
*   **Inference (`Whisper/`):**
    *   `WhisperEngine.swift`: Swift wrapper for `whisper.cpp`.
    *   `ModelManager.swift`: Handles on-demand model downloading (GGUF format) and storage.
    *   `WhisperBridge.h/mm`: Objective-C++ bridge to the C++ library.
*   **Logic:**
    *   `TranscriptionController.swift`: Central state machine (Idle -> Recording -> Processing).
    *   `ClipboardManager.swift`: Handles copying and auto-paste simulation.
    *   `Permissions.swift`: Manages Mic, Screen Recording, and Accessibility checks.
*   **UI (`UI/`):**
    *   `StatusBarController.swift`: Menu bar management.
    *   `HUDWindowController.swift`: Floating live transcript overlay.
    *   `SettingsWindowController.swift`: Configuration panel.

### Key Design Patterns
*   **Threading:**
    *   **Audio I/O:** Real-time thread (High priority, no locks).
    *   **Inference:** Background serial queue (UserInitiated).
    *   **UI:** Main thread.
*   **State Management:** `TranscriptionController` orchestrates transitions.
*   **Bridging:** C++ `whisper.cpp` -> Objective-C++ Bridge -> Swift.

---

## 5. Directory Structure

```text
MacTalk/
├── MacTalk/                # Main App Source
│   ├── Audio/              # Capture, Mixing, RingBuffer
│   ├── Whisper/            # Engine, Models, Bridge
│   ├── UI/                 # HUD, Settings, Menu
│   ├── Utilities/          # Helpers
│   ├── main.swift          # Entry point (Explicit, replaces @main)
│   └── ...
├── MacTalkTests/           # Unit Tests
├── Vendor/whisper.cpp/     # Submodule
├── docs/                   # Documentation (Architecture, PRD, Testing)
├── scripts/                # Build/Sign scripts
├── project.yml             # XcodeGen configuration
└── build.sh                # Build helper script
```

---

## 6. Current Development Status & Critical Notes

**Recent Fixes (macOS 26 / Xcode 26):**
1.  **Code Signing Crash:** Fixed "Team ID mismatch" errors for dylibs. A post-build script in `project.yml` now automatically re-signs `libwhisper.dylib` and others.
2.  **App Launch Failure:** Fixed an issue where Swift code wouldn't execute.
    *   **Solution:** Removed `@main` from `AppDelegate.swift`. Created an explicit `main.swift` to handle initialization order. **Do not revert this.**

**Status:**
*   Menu bar app is functional.
*   Metal acceleration is enabled.
*   UI components (HUD, Settings) are implemented.
*   Tests are present (~60%) but need validation.

---

## 7. Development Conventions

*   **Adding Files:**
    1.  Create file in `MacTalk/MacTalk/...`
    2.  (Optional) Add to `project.yml` if not auto-globbed.
    3.  Run `xcodegen generate`.
*   **Modifying `whisper.cpp` Integration:**
    *   Edit `WhisperBridge.h/.mm` for C++ changes.
    *   Edit `WhisperEngine.swift` for Swift API changes.
    *   Rebuild `whisper.cpp` via CMake if source files change.
*   **Testing:**
    *   Run tests: `xcodebuild test -project MacTalk.xcodeproj -scheme MacTalk`
    *   Or `Cmd+U` in Xcode.

---

## 8. Troubleshooting

| Issue | Solution |
| :--- | :--- |
| **"library not found for -lwhisper"** | Build `whisper.cpp` first (See Section 3A). |
| **"Model file not found"** | Models are downloaded on demand. Check `~/Library/Application Support/MacTalk/Models/`. |
| **No Metal Acceleration** | Ensure `whisper.cpp` was built with `-DGGML_METAL=ON`. |
| **Tests Fail on CI** | Tests require a macOS environment with Xcode. |
| **Xcode Project out of sync** | Run `xcodegen generate`. |
| **Auto-paste permission prompt keeps appearing** | Run `./build.sh reset-perms` then `./build.sh run` and re-grant permission. |
| **Auto-paste doesn't work (AXIsProcessTrusted returns false)** | Same as above—TCC CDHash changed after rebuild. |

---

## 9. Documentation Index

For deeper details, refer to the `docs/` folder:
*   `docs/development/ARCHITECTURE.md`: Detailed system design.
*   `docs/planning/PRD.md`: Product requirements.
*   `docs/development/SETUP.md`: Detailed environment setup.
*   `docs/testing/TESTING.md`: Test strategy.
*   `docs/stories/`: Implementation stories (S.01.x, S.02.x, S.03.x series).
