# Test lane policy

MacTalk's default validation is the deterministic `unit` lane. It uses only
in-process fakes and isolated defaults; it never accesses TCC, a hardware
capture device, a model store, or the network. The opt-in real-model test is
excluded explicitly, so a passing unit lane has zero XCTest skips.

```sh
scripts/test-lanes.sh unit       # full deterministic suite
scripts/test-lanes.sh repeat     # three relaunch iterations
scripts/test-lanes.sh appkit     # window/controller tests, no TCC prompts
scripts/coverage.sh              # xcresult + JSON/per-file xccov reports
```

CI uses the same explicit allowlist and never auto-selects `appkit`, `hardware`,
`tcc`, or `real-model`. AppKit/window validation is a separate manual lane;
hardware/TCC requires `MACTALK_HARDWARE_VALIDATION_ACK`, and real-model requires
`MACTALK_EXISTING_MODEL_PATH`. See `docs/testing/CI.md` for the scheduled TSan
runtime policy.

The `hardware` lane is intentionally interactive and requires
`MACTALK_HARDWARE_VALIDATION_ACK=I_HAVE_AUTHORIZED_CAPTURE`; it builds and
launches the signed app and may request microphone, screen-recording, or
accessibility permission. It does not download a model.

The `real-model` lane requires `MACTALK_EXISTING_MODEL_PATH` pointing to an
existing catalog model. Integrity validation and preparation run offline; a
missing path, unknown filename, or invalid artifact is reported as a clear
skip, never repaired or downloaded. Unit and coverage lanes always exclude
this test.

`DeterministicHarness.swift` provides `DeterministicASREngine`,
`DeterministicCaptureSession`, `DeterministicManualClock`,
`DeterministicManualScheduler`, `DeterministicAudioFixtures`,
`DeterministicModelDownloader`, `DeterministicNetworkTrap`,
`DeterministicASRBarrier`, and `makeIsolatedTestDefaults`. The ASR barrier
drives adversarial partial/final ordering tests. Production seams remain
injectable capture/settings/engine boundaries; no fake is installed in the
application process.
