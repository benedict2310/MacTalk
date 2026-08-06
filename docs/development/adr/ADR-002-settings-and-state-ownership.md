# ADR-002: Settings and recording state ownership

- **Status:** Accepted
- **Date:** 2026-07-18

## Decision

`AppSettings` is the authoritative synchronized store for persisted settings.
It exposes an immutable `SettingsSnapshot`; `snapshotAtRecordingStart()` is
latched for the lifetime of a recording. `StatusBarController` remains the
AppKit composition root, while `EngineLifecycleCoordinator` owns loaded engine
identity and `TranscriptionController` owns capture/inference session state.

Settings notifications may prewarm an idle engine, but a provider/model edit
cannot replace an engine or snapshot owned by an active recording. A pending
selection is applied after recording becomes idle. Coordinator dependencies are
injected at the composition root so deterministic tests do not use production
singletons.

## Consequences

- `UserDefaults` persistence and migration have one owner.
- UI reads and edits snapshots rather than mutable engine state.
- A retry uses the same recording snapshot and cannot accidentally pick up a
  mid-session settings edit.
- Tests can use isolated defaults and fake capture/engine seams.

Evidence: `Utilities/AppSettings.swift`, `StatusBarController.swift`,
`StatusBar/EngineLifecycleCoordinator.swift`, and
`MacTalkTests/AppSettingsTests.swift` / `EngineLifecycleCoordinatorTests.swift`.
