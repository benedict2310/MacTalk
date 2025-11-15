# MacTalk Documentation

> **Native macOS menu bar app for local voice transcription powered by Whisper**

Welcome to the MacTalk documentation hub. All technical documentation has been organized into logical categories for easy navigation.

---

## Quick Start

- **New to MacTalk?** Start with [Planning → PRD.md](planning/PRD.md) for product overview
- **Setting up development?** See [Development → SETUP.md](development/SETUP.md)
- **Running into issues?** Check [Troubleshooting](troubleshooting/)
- **Contributing?** Review [Development → ARCHITECTURE.md](development/ARCHITECTURE.md)

---

## Documentation Structure

### 📋 [Planning](planning/)
Project requirements and progress tracking

- **[PRD.md](planning/PRD.md)** - Product Requirements Document (what we're building)
- **[PROGRESS.md](planning/PROGRESS.md)** - Current development status and progress tracking

### 🛠️ [Development](development/)
Core technical documentation for developers

- **[ARCHITECTURE.md](development/ARCHITECTURE.md)** - System architecture, components, and data flow
- **[SETUP.md](development/SETUP.md)** - Development environment setup guide
- **[XCODE_BUILD.md](development/XCODE_BUILD.md)** - Xcode project configuration and build settings

### ✨ [Features](features/)
Detailed feature implementation documentation

- **[LIQUID_GLASS_UI.md](features/LIQUID_GLASS_UI.md)** - Liquid Glass UI design system and visual guidelines
- **[ACCESSIBILITY.md](features/ACCESSIBILITY.md)** - Accessibility features and VoiceOver support
- **[LOCALIZATION.md](features/LOCALIZATION.md)** - Internationalization and localization guide
- **[SETTINGS_IMPLEMENTATION.md](features/SETTINGS_IMPLEMENTATION.md)** - Settings panel architecture

### 🔐 [Permissions](permissions/)
macOS permissions system (microphone, screen recording, accessibility)

> **Start here:** [permissions/README.md](permissions/README.md) - Overview of the permissions system

- **[PERMISSIONS_FINAL_SUMMARY.md](permissions/PERMISSIONS_FINAL_SUMMARY.md)** - High-level summary of permissions architecture
- **[PERMISSION_DETECTION_SOLUTION.md](permissions/PERMISSION_DETECTION_SOLUTION.md)** - Detection logic and implementation
- **[PERMISSION_TESTING_GUIDE.md](permissions/PERMISSION_TESTING_GUIDE.md)** - How to test permission flows
- **[SCREENCAPTUREKIT_PERMISSIONS.md](permissions/SCREENCAPTUREKIT_PERMISSIONS.md)** - ScreenCaptureKit-specific permission handling
- **[TCC_FIX_SUMMARY.md](permissions/TCC_FIX_SUMMARY.md)** - TCC database and permission persistence fixes
- **[TCC_PERMISSIONS_DEV_GUIDE.md](permissions/TCC_PERMISSIONS_DEV_GUIDE.md)** - Developer guide for TCC system

### 🧪 [Testing](testing/)
Testing strategy, coverage, and procedures

- **[TESTING.md](testing/TESTING.md)** - Testing guide and how to run tests
- **[TEST_COVERAGE.md](testing/TEST_COVERAGE.md)** - Detailed code coverage reports and metrics

### 🚀 [Deployment](deployment/)
Build, distribution, and release processes

- **[BUILD_DISTRIBUTION.md](deployment/BUILD_DISTRIBUTION.md)** - Creating release builds and distribution
- **[CI_CD_STATUS.md](deployment/CI_CD_STATUS.md)** - Continuous integration/deployment status
- **[ALPHA_TESTING.md](deployment/ALPHA_TESTING.md)** - Alpha testing program and procedures

### 🔧 [Troubleshooting](troubleshooting/)
Issue resolution, debugging, and known problems

- **[KNOWN_ISSUES.md](troubleshooting/KNOWN_ISSUES.md)** - Current known issues and workarounds
- **[DEBUG_SESSION_NOTES.md](troubleshooting/DEBUG_SESSION_NOTES.md)** - Historical debugging sessions and solutions
- **[TROUBLESHOOTING_SCREENCAPTURE.md](troubleshooting/TROUBLESHOOTING_SCREENCAPTURE.md)** - ScreenCaptureKit-specific troubleshooting
- **[PROFILING.md](troubleshooting/PROFILING.md)** - Performance profiling with Instruments

---

## Common Tasks

### For Developers

**Setting up the project:**
1. Read [SETUP.md](development/SETUP.md)
2. Follow build instructions in [XCODE_BUILD.md](development/XCODE_BUILD.md)
3. Review [ARCHITECTURE.md](development/ARCHITECTURE.md)

**Running tests:**
1. See [TESTING.md](testing/TESTING.md)
2. Check coverage in [TEST_COVERAGE.md](testing/TEST_COVERAGE.md)

**Debugging permission issues:**
1. Start with [permissions/README.md](permissions/README.md)
2. Follow [PERMISSION_TESTING_GUIDE.md](permissions/PERMISSION_TESTING_GUIDE.md)
3. If stuck, check [troubleshooting/](troubleshooting/)

### For Product/Design

**Understanding the product:**
1. [PRD.md](planning/PRD.md) - Full product requirements
2. [LIQUID_GLASS_UI.md](features/LIQUID_GLASS_UI.md) - UI design system
3. [ACCESSIBILITY.md](features/ACCESSIBILITY.md) - Accessibility standards
4. [PROGRESS.md](planning/PROGRESS.md) - Current status

### For QA/Testing

**Testing the app:**
1. [ALPHA_TESTING.md](deployment/ALPHA_TESTING.md) - Testing checklist
2. [PERMISSION_TESTING_GUIDE.md](permissions/PERMISSION_TESTING_GUIDE.md) - Permission flows
3. [KNOWN_ISSUES.md](troubleshooting/KNOWN_ISSUES.md) - What to watch for

---

## Project Status

**Current Phase:** Phase 5 Complete - Ready for Release Preparation
**Last Updated:** 2025-11-14

See [PROGRESS.md](planning/PROGRESS.md) for detailed milestone tracking.

---

## Tech Stack

- **Language:** Swift 5.9+ (macOS 14.0+)
- **Frameworks:** AppKit, AVFoundation, ScreenCaptureKit
- **Audio Engine:** whisper.cpp (Metal-accelerated)
- **Build System:** XcodeGen
- **Testing:** XCTest (85%+ coverage)

---

## Contributing

1. Read [ARCHITECTURE.md](development/ARCHITECTURE.md) to understand the codebase
2. Follow setup in [SETUP.md](development/SETUP.md)
3. Write tests (see [TESTING.md](testing/TESTING.md))
4. Check [KNOWN_ISSUES.md](troubleshooting/KNOWN_ISSUES.md) before reporting bugs

---

## Key Decisions

See **Decisions Log** in [PROGRESS.md](planning/PROGRESS.md) for architectural decisions.

Notable choices:
- whisper.cpp over CoreML (better performance, quantization support)
- Menu bar app paradigm (minimal UI, quick access)
- XcodeGen for project management (declarative configuration)
- Local-only processing (privacy-first, no cloud)

---

## Getting Help

**Build/Setup Issues:** [development/SETUP.md](development/SETUP.md), [development/XCODE_BUILD.md](development/XCODE_BUILD.md)
**Permission Problems:** [permissions/README.md](permissions/README.md)
**Performance Issues:** [troubleshooting/PROFILING.md](troubleshooting/PROFILING.md)
**Test Failures:** [testing/TESTING.md](testing/TESTING.md)

---

**Documentation Version:** 2.0 (Reorganized 2025-11-14)
**Maintained by:** MacTalk Development Team
