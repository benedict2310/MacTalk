# MacTalk Stabilization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `subagent-driven-development` (recommended) or `executing-plans` to implement this plan task-by-task. Every production behavior follows red/green/refactor: add one focused XCTest, run it to observe the expected failure, add the smallest implementation, and rerun the focused test before moving on.

**Goal:** Make MacTalk’s audio, privacy, concurrency, settings, model delivery, build, test, signing, release, and documentation behavior deterministic and verifiable before any feature expansion.

**Architecture:** Stabilize the real-time audio contract first (conversion, callback ownership, source composition), then establish deterministic seams around the controller. Move runtime decisions into typed settings and small coordinators only after behavior is characterized. Make build/release work reproducible in source configuration, but treat Apple signing/notarization and GitHub secrets as external gates rather than pretending they can be automated locally.

**Tech Stack:** Swift 6/XCTest/TSan, AVFoundation/ScreenCaptureKit, XcodeGen (`project.yml`), GitHub Actions, Swift Package Manager, macOS codesign/notarytool.

---

## Program rules

1. Work only on `feat/stabilize-mactalk`; never `main`.
2. Claim a TODO before its task; close only after tests and two reviews. Keep credential-gated work open and document the blocker.
3. The local standard `xcodebuild test` baseline is blocked by the unavailable Mac Development certificate for Team `9SXL4GJ4TZ`. Use the unsigned CI-equivalent command for automated red/green checks:
   ```bash
   xcodebuild test -project MacTalk.xcodeproj -scheme MacTalk -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
   ```
4. `project.yml` is authoritative. Regenerate `MacTalk.xcodeproj` after any change to it.
5. Each task is: implementation worker → specification review → code-quality review → TODO evidence update.
6. Unit and CI tests never download transcription models or access model-provider networks. Use fake engines/stores by default; a separately opt-in integration smoke test may reuse exactly one pre-provisioned local model and must skip with a prerequisite message when it is unavailable.

## Dependency order

```
privacy logging ────────────┐
callback races ─────────────┼─> mic+app composition ─> deterministic harness ─> cleanup / CI / StatusBar refactor
AudioMixer semantics ───────┘
model integrity ───────────────────────────────────────────────────────────────────────────────────────────┐
authoritative settings ─────────────────────────────────────────────────────────────────────────────────────┼─> StatusBar refactor
UserNotifications ──────────────────────────────────────────────────────────────────────────────────────────┘
FluidAudio/project reproducibility ─> CI
hardened runtime/signing ─> archive/notarization/release
Docs baseline follows verified evidence from all previous work.
```

## Phase 1 — independent, source-only stabilization

### Task 1: P0 Stop logging transcript content in Release builds (`TODO-560fdcc9`)

**Files:** `MacTalk/MacTalk/DebugLogger.swift`, `Whisper/NativeWhisperEngine.swift`, `StatusBarController.swift`, `MacTalkTests/PrivacyLoggingTests.swift`.

- [ ] Write an XCTest that sends a unique transcript and clipboard sentinel to an injectable log sink and asserts no log record contains either value.
- [ ] Run the unsigned focused test; it must fail because `NativeWhisperEngine` currently prints transcript text.
- [ ] Add a release-safe logging boundary. It may record event type, duration, count, and normalized error category only; file logging is debug/explicit-opt-in, app-controlled, and never `/tmp`.
- [ ] Route transcript-related `print`/`NSLog` through the boundary and redact errors that contain transcript content.
- [ ] Add failing/passing regression coverage for a transcript-bearing error description.
- [ ] Run `rg -n 'print\(|NSLog\(|/tmp' MacTalk/MacTalk` and the complete unsigned suite.
- [ ] Commit `fix: prevent transcript logging in release`.

### Task 2: P0 Correct AudioMixer resampling and buffer-drain semantics (`TODO-4742e893`)

**Files:** `MacTalk/MacTalk/Audio/AudioMixer.swift`, `MacTalkTests/AudioMixerTests.swift`.

- [ ] Activate/write tests for empty input, 48 kHz mono 100 ms → 1600 ±1 frames, 48 kHz stereo downmix, 44.1 kHz duration, tiny buffers, and sequential tone continuity.
- [ ] Run `xcodebuild test ... -only-testing:MacTalkTests/AudioMixerTests` unsigned; observe the existing 1360/1480 frame failures.
- [ ] Implement a documented converter contract: source-specific serialized converter state, exact capacity calculation, input feed until exhausted, and output draining. Do not share a converter across mic/app callbacks.
- [ ] Replace unsafe `CMSampleBuffer` copying with format/layout-aware PCM conversion.
- [ ] Run focused tests repeatedly and under `MacTalk-TSan`; then the unsigned suite.
- [ ] Commit `fix: preserve audio frames during conversion`.

### Task 3: P0 Fix TSan-confirmed capture callback races (`TODO-90df0983`)

**Files:** `Audio/AudioCapture.swift`, `Audio/ScreenAudioCapture.swift`, `TranscriptionController.swift`, `MacTalkTests/ConcurrencyStressTests.swift`.

- [ ] Write a stress test that replaces/clears callbacks concurrently with a real callback-delivery seam; invalidated callbacks must not execute.
- [ ] Run it under `MacTalk-TSan`; observe the race/nondeterministic delivery.
- [ ] Add a lock-protected callback + generation storage per capture class. Read a callback under lock, invoke after releasing it, and reject late session deliveries in the controller.
- [ ] Add replacement, stop-before-delivery, and concurrent mic/screen tests.
- [ ] Run focused TSan three times and the complete TSan scheme; do not add suppressions for new races.
- [ ] Commit `fix: synchronize capture callbacks`.

### Task 4: P1 Pin FluidAudio and reproduce project generation (`TODO-9c0fe703`)

**Files:** `project.yml`, generated `MacTalk.xcodeproj`, resolved package lockfile if supported, `scripts/verify-project-generation.sh`, CI workflow.

- [x] Write a shell test which copies the repo, regenerates with XcodeGen, and fails if tracked generated output differs or FluidAudio is a version range.
- [x] Run it red; current `from: 0.7.11` had no exact lock.
- [x] Pin FluidAudio to the API-compatible exact release `0.15.5`, track the canonical resolution artifact, and regenerate the project.
- [x] Run the generation verifier, signed Release build/run, and focused tests.
- [x] Commit `build: pin FluidAudio and verify generated project` (`88d975c`, `b64acb5`).

### Task 5: P1 Make settings authoritative (`TODO-9ead3f5f`)

**Files:** `Utilities/AppSettings.swift`, `SettingsWindowController.swift`, `StatusBarController.swift`, `TranscriptionController.swift`, `AppSettingsTests.swift`, `SettingsIntegrationTests.swift`.

- [ ] Add isolated-default tests for explicit defaults, legacy key migration, invalid values, provider/model compatibility, and “apply at next recording” behavior.
- [ ] Run tests red; model/language/mode are currently UI-only and notification defaults disagree.
- [ ] Define typed `RecordingSettings`, model selection by stable ID, capture mode, output settings, and provider-specific compatibility in one store.
- [ ] Migrate raw indices once, route both Settings and menu auto-paste changes through the store, and snapshot settings at session start.
- [ ] Test Whisper-to-Parakeet switching cannot leak model state.
- [ ] Run focused/full unsigned suites and commit `fix: centralize recording settings`.

## Phase 2 — audio and test foundation

### Task 6: P0 Compose microphone and app audio correctly (`TODO-1bc7e020`)

**Depends on:** Tasks 2–3.

**Files:** `AudioMixer.swift`, `TranscriptionController.swift`, `AudioMixerTests.swift`, `TranscriptionControllerTests.swift`.

- [ ] Write deterministic impulse tests: simultaneous mic/app impulses are mixed at the same timeline point; offset/missing input preserves timing with documented zero-fill behavior.
- [ ] Observe red failure: the controller concatenates sources by callback order.
- [ ] Add a timestamped source-composition API with bounded skew buffering, explicit gain/clamp policy, and reset semantics; submit sources separately before chunking.
- [ ] Test equal timestamps, source skew, source absence, clipping, stop/reset, and repeated sessions.
- [ ] Run audio/controller suites, full unsigned suite, then a manually permitted `./build.sh run` mic+app check.
- [ ] Commit `fix: mix microphone and app audio on one timeline`.

### Task 7: P1 Build a deterministic transcription-pipeline harness (`TODO-3b54902b`)

**Depends on:** Tasks 2–3.

**Files:** new `MacTalkTests/Support/DeterministicASREngine.swift`, `AudioFixtureBuilder.swift`; `TestHelpers.swift`, `TranscriptionControllerTests.swift`, controller dependency seams.

- [ ] Write a test feeding fixed audio/timestamps to a fake engine with exact ordered partial/final assertions and no TCC, hardware, model, or sleep dependency.
- [ ] Observe red failure due to concrete controller dependencies.
- [ ] Add small capture/engine/clock factories at the controller boundary; production adapters preserve current behavior.
- [ ] Add deterministic silence, impulse, sine-wave fixtures and coverage for start/stop, final flush, cancellation/restart, late audio, language, and composition handoff.
- [ ] Run controller/mixer/concurrency suites and commit `test: add deterministic transcription pipeline harness`.

## Phase 3 — integrity, notifications, and signing

### Task 8: P1 Enforce model integrity (`TODO-2e9af4b0`)

**Files:** `Whisper/ModelCatalog.swift`, `ModelManager.swift`, `ParakeetModelDownloader.swift`, `SHA256Streamer.swift`, model downloader tests.

- [ ] Write tests for valid hash, corrupt byte, absent hash, partial resume, corrupt cache, Parakeet path traversal, and staged failure cleanup.
- [ ] Observe red failure: Whisper checksums are empty and caches/downloads are existence-only.
- [ ] Require trusted 64-character SHA-256 + immutable source/version metadata before atomic promotion; validate cache before use.
- [ ] Pin/allowlist Parakeet paths/revision/artifacts and validate size/digest in staging before activation.
- [ ] Run focused/full suites and commit `feat: verify downloaded model integrity`.

**External evidence blocker:** Commit only hashes approved from an immutable upstream release manifest; never derive/guess a “trusted” hash from a one-off mirror download.

### Task 9: P2 Replace deprecated notifications (`TODO-be7593e3`)

**Files:** new `Utilities/NotificationManager.swift`, current notification callers, `NotificationManagerTests.swift`.

- [ ] Write a test against an injected `UNUserNotificationCenter` boundary: enabled event submits redacted request; disabled event submits none.
- [ ] Observe red failure because `NSUserNotificationCenter` is used directly.
- [ ] Implement local UserNotifications authorization only from a user action, preference gating, duplicate request policy, and non-transcript copy.
- [ ] Test denied/granted authorization, enabled/disabled delivery, and identifiers.
- [ ] Run suites and commit `fix: use UserNotifications for local alerts`.

### Task 10: P1 Harden runtime/signing (`TODO-e06b62f7`)

**Files:** `MacTalk.entitlements`, `project.yml`, `scripts/verify-signing.sh`, signing docs/tests.

- [ ] Write a fixture/script test that fails when hardened runtime is disabled or required entitlements/signature checks are absent.
- [ ] Enable hardened runtime, minimize/document every exception, make required signing verification failures visible, and regenerate Xcode project.
- [ ] Implement `verify-signing.sh` for strict bundle/nested dylib signatures, Team ID, runtime options, and entitlements; distinguish missing credentials from a failing signature.
- [ ] Run fixture/unsigned build tests and commit `build: enable hardened runtime`.

**External validation blocker:** a Developer ID/Mac Development certificate with private key is required; this machine currently lacks it.

## Phase 4 — CI, refactoring, cleanup, release, docs

### Task 11: P2 Remove dead and duplicated APIs (`TODO-6fc5c73f`)

**Depends on:** Task 7.

- [ ] Inventory candidates with compiler diagnostics, call-site search, and characterization tests.
- [ ] For each candidate, first prove behavior or zero production use, then delete one API at a time.
- [ ] Run affected/full suite after each removal and commit scoped `refactor: remove unused <symbol>` commits.

### Task 12: P1 Restore blocking CI, coverage, scheduled TSan (`TODO-e6fc281b`)

**Depends on:** Tasks 4 and 7.

**Files:** `.github/workflows`, `scripts/run-ci-tests.sh`, `scripts/collect-coverage.sh`, testing docs.

- [ ] Write a workflow validation test asserting PR unsigned tests, non-optional failure behavior, xcresult upload, coverage output, and scheduled TSan.
- [ ] Observe red: current tests are disabled/non-blocking.
- [ ] Add unsigned arm64 PR test/coverage jobs with `pipefail`, artifact publishing on failure, and a nightly deterministic TSan lane with no race suppression.
- [ ] Validate YAML and run CI scripts locally; commit `ci: restore blocking tests and scheduled TSan`.

**External gate:** branch protection/required checks require GitHub repository admin access.

### Task 13: P2 Decompose StatusBarController (`TODO-1e6b370c`)

**Depends on:** Tasks 5, 7, 9.

**Files:** new `RecordingSessionCoordinator.swift`, `StatusMenuCoordinator.swift`; `StatusBarController.swift`; coordinator tests.

- [ ] Write coordinator tests for menu action→settings snapshot→recording action, menu state transitions, and delegated notifications.
- [ ] Observe red because logic is entangled with AppKit status objects.
- [ ] Extract recording lifecycle, menu state, settings observation, and notification dispatch one responsibility at a time. Keep `StatusBarController` as AppKit composition root; do not redesign UI.
- [ ] Run suites and commit `refactor: split status bar coordinators`.

### Task 14: P2 Reproducible archive/notarize/release (`TODO-ff2c0303`)

**Depends on:** Task 10.

**Files:** `scripts/archive-release.sh`, `notarize-release.sh`, `verify-release.sh`, release workflow, release docs/tests.

- [ ] Write fake-tool shell tests ensuring missing env is rejected, archive→verify→notarize→staple order is enforced, and a version/commit/SHA-256 manifest is emitted.
- [ ] Observe red because scripts/workflow do not exist.
- [ ] Implement `set -euo pipefail` scripts and tag/manual dispatch release workflow; never print secrets.
- [ ] Run fake-tool tests and shellcheck if installed; commit `ci: add signed notarized release workflow`.

**External blockers:** Apple Developer membership, Developer ID certificate/private key, notarization credentials, configured GitHub Actions secrets, and release-write permission.

### Task 15: P2 Evidence-backed documentation (`TODO-5f2e85d0`)

**Files:** `README.md`, architecture/setup/testing docs, new dated baseline document and narrow docs verifier.

- [ ] Write a docs verifier for referenced commands/files and stale version/path claims.
- [ ] Collect actual test/TSan/CI/signing evidence from Tasks 1–14.
- [ ] Replace legacy claims with dated measurements, unsigned CI commands, TCC needs, and explicit credential gates.
- [ ] Run verifier and generation verifier; commit `docs: record verified stabilization baseline`.

### Task 16: Close stabilization epic (`TODO-fdc7785c`)

- [ ] Run `xcodegen generate` and `git diff --exit-code -- MacTalk.xcodeproj`.
- [ ] Run complete unsigned normal and TSan suites.
- [ ] Run project/signing/docs/CI verification scripts.
- [ ] With valid TCC/signing, run `./build.sh run` and manually validate mic-only, mic+app, settings, model verification, notifications, and menu lifecycle.
- [ ] Record measured outputs and any external gates in the epic; close it only if all acceptance criteria are actually satisfied.

## Review gate

Every task requires an implementation worker, then independent spec compliance and code-quality reviews. Any finding must be fixed and re-reviewed before a dependent task begins. The first execution batch is Tasks 1–5, serially, beginning with Task 1.
