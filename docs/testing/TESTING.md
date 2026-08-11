# Testing policy and commands

**Evidence baseline:** [docs/STATUS.md](../STATUS.md), dated 2026-07-18.
This page defines lanes; it does not invent a coverage target or test count.

## Deterministic unit lane

The blocking lane is:

```sh
scripts/test-lanes.sh unit
```

`test-lanes.sh` creates an isolated HOME, runs the generated `MacTalk` scheme
with code signing disabled, and applies the explicit selection from
`scripts/deterministic-test-selection.sh`. Tests use injected capture sessions,
ASR engines, clocks, schedulers, downloaders, and network traps. The lane does
not use TCC, audio hardware, provider networks, or a real model.

The explicit selection includes pipeline observability suites
(`AudioHardwareValidationRecorderTests`, `PipelineObservabilityTests`, and
`ScreenAudioCaptureTests`) alongside bounded transport,
provenance/integrity, Parakeet source preparation/materialization/snapshot,
verified byte loading, bootstrap generation ownership, source-only
availability, and legacy compiled cleanup suites. These observability tests
use injected drivers and sinks; they do not access TCC, windows, hardware,
models, or the network. `scripts/ci-security-checks.sh` also runs offline
provenance negative fixtures and `scripts/tests/test_model_security_source_guard.sh`,
which mutates a temporary source copy to prove that path-loading, unverified
loading, and unbounded production-transport regressions are rejected.

The 2026-07-18 run executed **203 tests, 0 failures, 0 skips**. At model-security
closure checkout `72762ed` on 2026-07-26, the expanded selection executed
**470 tests, 0 failures, 0 skips**; the repeat lane completed three relaunch
iterations of that selection without failure. These numbers are command results
from their named checkouts, not a permanent contract; rerun the command and read
the XCTest summary for a new result.

Useful deterministic variants:

```sh
scripts/test-lanes.sh repeat       # three relaunch iterations
scripts/test-lanes.sh appkit       # HUD/settings/status controllers, no TCC
scripts/test-lanes.sh real-model   # explicit path required; never downloads
```

The `real-model` lane must be opted into with
`MACTALK_EXISTING_MODEL_PATH` pointing to one existing catalog artifact. It
validates the catalog identity and SHA-256. It must not be run against a path
that is also being changed by another process.

## Coverage lane

```sh
scripts/coverage.sh
```

The result is `build/coverage/MacTalk.xcresult`; the per-file report is
`build/coverage/coverage-by-file.txt`. On 2026-07-18, the command executed 203
tests with 0 failures. `xccov` reported app target line coverage of
**39.19% (4320/11022)** and test-bundle coverage of **88.20% (5896/6685)** in
that artifact. These figures include the instrumented target exactly as
reported by `xccov`; they are not claims of branch coverage, UI coverage, or
coverage for unexecuted external packages. No minimum percentage is asserted
here.

When reporting a new number, include the exact command, checkout, date, and
`.xcresult` or text artifact. Do not copy percentages from
`docs/testing/TEST_COVERAGE.md` without regenerating the artifact; that file is
historical until refreshed.

## TSan lane

```sh
scripts/test-lanes.sh tsan
```

This lane runs `scripts/tsan-smoke.sh` first, checks the generated
`MacTalk-TSan` scheme/configuration and test executable runtime link, and only
then runs `ConcurrencyStressTests` and `AudioMixerTests` three times in fresh
test processes before running the complete macOS 15-supported deterministic
subset. Hosted run `31272883974` supplied the compatibility boundary: it
completed every earlier deterministic class but `ParakeetStoreFileLockTests`
subprocesses exited with status 15, CoreML rejected the version-10 fixture in
`VerifiedCoreMLByteAssetTests`, and `VerifiedParakeetModelLoaderTests` stalled.
Only those three classes are omitted from TSan; the ordinary macOS 26 unit lane
continues to run them. The three pipeline observability classes are included in
both deterministic and hosted Thread Sanitizer arrays. Hosted TSan has no flaky
absolute performance threshold: it checks race safety and deterministic test
behavior, while performance figures require Instruments.

On the baseline host, the standalone clang ThreadSanitizer binary segfaulted
(signal 11), so the lane stopped with `TSAN/UNAVAILABLE` before XCTest. No local
TSan pass is claimed. The blocker is the Apple/host sanitizer runtime, not
evidence that the tests pass or fail under TSan; hosted CI uses the compatible
`macos-15` runtime with the same pinned Xcode 26.0.1 toolchain.

## Pipeline diagnostics and hardware validation

Pipeline reports are bounded metadata-only JSONL records. They contain no
transcript text, audio samples, target application identity, or raw errors.
Hardware validation is opt-in, bounded asynchronous hardware validation and
never writes audio samples. The report can be copied only through the explicit
status-bar **Copy Performance Report** action.

## Build and signing lanes

```sh
xcodegen generate
git diff --exit-code -- MacTalk.xcodeproj
./build.sh build
```

The build is a signed Release build and therefore needs the configured
Developer ID identity/private key. CI uses its documented unsigned XCTest
commands; signing and notarization are separate release gates. The baseline
`./build.sh build` passed with Xcode 26.0.1 / Build 17A400. The baseline does
not claim a notarized artifact.

## Manual hardware/TCC lane

```sh
MACTALK_HARDWARE_VALIDATION_ACK=I_HAVE_AUTHORIZED_CAPTURE \
  scripts/test-lanes.sh hardware
```

This builds/launches the app and requires a supported microphone and app/system
audio source. Manually approve Microphone and, for app audio, Screen
Recording. Accessibility is separately required for auto-paste. The lane does
not download models. It was not run for the baseline; acoustic/timestamp,
stream-loss fallback, menu lifecycle, and permission reset behavior remain
manual validation gaps.

## TDD and evidence rules

For implementation changes, add a focused XCTest, observe the expected red
result, implement the smallest change, and rerun it green. Shell verifier
changes likewise need passing and negative-fixture tests. A test count,
coverage percentage, “supported macOS” statement, signing result, or model
accuracy number is valid only when its command and artifact are named.

No lane may claim a real transcription model unless its path and catalog hash
are stated. No lane may claim network isolation merely because the source has
no provider calls: model downloaders use URLSession by design. No lane may
claim TCC behavior from a unit test.
