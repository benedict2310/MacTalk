# Dead API cleanup inventory

Tracking evidence for `TODO-6fc5c73f` on `feat/stabilize-mactalk`.

## Baseline evidence (2026-07-18)

- `rg` over `MacTalk/MacTalk` and `MacTalk/MacTalkTests` was used for every candidate.
- `xcodebuild ... -scheme MacTalk ... build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO` succeeded.
- Focused characterization run (ring-buffer, status-bar, engine, screen-audio, recording-session, and transcription tests) executed 63 tests with 0 failures.
- No model download or network operation was used. The TSan lane is unavailable for this cleanup run.
- The Swift compiler emitted no errors or unused-member diagnostics for these declarations; call-site inventory is therefore the stronger evidence for members (Swift does not diagnose unused internal members generally).

## Candidate inventory and decisions

| Candidate | Production call sites | Test-only references | Decision | Evidence / rationale |
| --- | ---: | ---: | --- | --- |
| `RingBuffer` and `RingBufferTests.swift` | 0 | 0 live tests (the test file was already a removal note) | Remove | `rg -n '\\bRingBuffer\\b' MacTalk/MacTalk MacTalk/MacTalkTests` found only the unused implementation and removal note. Production audio handoff is `OwnedAudioRing` in `AudioCapture`; timestamped composition is `AudioTimelineComposer`. |
| `ASREngine.setPartialHandler` | 0 | 7 conformance stubs | Remove | `rg` found only the protocol requirement, two engine implementations, and test doubles. `TranscriptionController` consumes the value returned by `process`; no caller registers this callback. Remove the stored handlers and stubs, retaining `ASRPartial` and returned partial behavior. |
| `ClipboardManager.getClipboard` | 0 | 0 | Remove | No call sites. Production output writes through `SystemClipboardWriter` to `setClipboard`. |
| `ClipboardManager.pasteIfAllowed` / private `sendCommandV` | 0 | 0 | Remove | No call sites. Auto-paste is owned by `AutoInsertManager`, which performs AX insertion then one Cmd-V fallback. |
| `ClipboardManager.pasteViaAppleScript` | 0 | 0 | Remove | No call sites and not part of the production output path. |
| `ClipboardManager.canPasteInFrontmostApp` | 0 | 0 | Remove | No call sites; target safety is owned by `OutputCoordinator`. |
| `ClipboardManager` history (`addToHistory`, `getHistory`, `clearHistory`) | 0 | 0 | Remove | No call sites; the comment identified this as a future enhancement, not behavior. |
| `AutoInsertManager.insertText` / `insertTextWithPermissionRequest` and fallback clipboard-write branch | 0 | 0 | Remove | Only `insertClipboardText` is used by `SystemTextInserter`. Removing the legacy entry points and boolean branch leaves one production Cmd-V implementation without a second clipboard side effect. |
| `ScreenAudioCapture.selectFirstWindow` | 0 | 0 | Remove | App audio production uses `selectApp` / `selectDisplay` through `AppAudioSourceCoordinator`; no test or production caller names this convenience API. |
| `TranscriptionController.autoPasteEnabled` | 0 | 0 | Remove | No reads or writes. Auto-paste preference is captured in `SettingsSnapshot` and handled by `OutputCoordinator`. |
| `StatusBarDependencies.clock` | 0 | 0 | Remove | Stored and initialized but never read. Permission/output coordinators own their injected clocks; no status-bar compatibility caller supplies this value. |
| `EngineLifecycleCoordinator.isCurrent` / `isCurrentRequest` | 0 | 0 | Remove | These compatibility helpers were not in `EngineLifecycleCoordinating` and had no caller; current request validation remains private in `validated(...)`. |

## Retained symbols / explicit non-removals

- `ClipboardManager.setClipboard` remains the single production clipboard writer used by `SystemClipboardWriter`.
- `AutoInsertManager.insertClipboardText` and its AX/Cmd-V fallback remain the single production insertion implementation.
- `StatusBarController` Objective-C selector methods remain because `StatusMenuPresenter` binds menu actions to them.
- `WhisperBridge.h/.mm` public C bridge declarations and implementations remain unchanged; this cleanup has no proof of dead external symbols.
- `AudioHostTimestamp`'s `ScreenCaptureKit` initializer remains because `ScreenAudioCapture` uses it in the production callback path.

## Verification after cleanup

Each logical removal group was validated before its scoped commit:

1. **Ring buffer removal** (`5055fa1`): full XCTest suite, 230 tests / 1 opt-in local-model skip / 0 failures; `./build.sh run` succeeded and launched the signed app.
2. **ASR partial-handler removal** (`c9efea1`): full XCTest suite, 230 tests / 1 skip / 0 failures; `./build.sh run` succeeded and launched the signed app.
3. **Clipboard/Cmd-V, ScreenAudio, controller, and status dependency cleanup** (`97173be`): full XCTest suite, 230 tests / 1 skip / 0 failures; `./build.sh run` succeeded and launched the signed app.
4. **Obsolete engine status helpers** (`5bb1eef`): full XCTest suite, 230 tests / 1 skip / 0 failures; `./build.sh run` succeeded and launched the signed app.

The final compiler/build evidence is a successful signed Release build from `./build.sh run`; the compiler emitted no errors. Final `rg` over Swift sources reports no removed candidate symbols, and the generated Xcode project has no stale RingBuffer references. The Objective-C bridge symbols were scanned and retained unchanged. The TSan scheme was not run because the requested TSan lane is unavailable for this cleanup environment; no TSan result is claimed. No model download or network operation was used.
