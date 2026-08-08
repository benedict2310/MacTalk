# MacTalk verified status baseline

**Baseline date:** 2026-07-18
**Branch:** `feat/stabilize-mactalk`
**Source:** the checkout on this branch at collection time; run
`git rev-parse HEAD` and use the commit recorded by release preflight for any
new release claim.

This is an evidence record, not a product roadmap. A result is valid only for
the command, checkout, and host stated here. No transcription model was
downloaded or used while collecting this baseline.

## Machine-readable baseline

<!-- STATUS-DATA-BEGIN
{"date":"2026-07-18","release_version":"1.1.3","build_number":"4","deployment_target":"26.0","swift_version":"6.0","xcodegen_version":"2.44.1","fluidaudio_version":"0.15.5","unit_tests":{"command":"scripts/test-lanes.sh unit","result":"passed","executed":203,"failures":0,"skips":0},"coverage":{"command":"scripts/coverage.sh","result":"passed","artifact":"build/coverage/MacTalk.xcresult","report":"build/coverage/coverage-by-file.txt","mactalk_app_line_coverage":"39.19% (4320/11022)","test_bundle_line_coverage":"88.20% (5896/6685)"},"build":{"command":"./build.sh build","result":"passed","configuration":"Release","signing":"Developer ID Application: Benedict Evert (9SXL4GJ4TZ)"},"tsan":{"command":"scripts/test-lanes.sh tsan","result":"blocked","blocker":"standalone clang ThreadSanitizer runtime segfaulted (TSAN/UNAVAILABLE) before XCTest"},"hardware_tcc":{"result":"not_run","reason":"requires supported microphone/app-audio hardware and manual microphone, Screen Recording, and Accessibility/TCC approval"},"real_model":{"result":"not_run","reason":"one pre-provisioned local model is required; no model download or provider network is permitted in deterministic lanes"},"release":{"result":"blocked","blockers":["Apple Developer membership","Developer ID Application certificate and private key","notarization credentials","GitHub release environment/reviewers/secrets/contents:write"]}}
STATUS-DATA-END -->

## Reproducible commands and observed results

| Lane | Exact command | Observed result | Artifact or blocker |
| --- | --- | --- | --- |
| Toolchain | `xcodebuild -version` | Xcode 26.0.1, Build 17A400 | Host toolchain |
| Project generator | `xcodegen --version` | Version 2.44.1 | Host tool |
| Release build | `./build.sh build` | Passed (`** BUILD SUCCEEDED **`) | Signed Release app in Xcode DerivedData; no model |
| Deterministic unit | `scripts/test-lanes.sh unit` | 203 executed, 0 failures, 0 skips | XCTest result path is printed by `xcodebuild`; fakes and isolated HOME |
| Coverage | `scripts/coverage.sh` | 203 executed, 0 failures; app line coverage 39.19% (4320/11022) | `build/coverage/MacTalk.xcresult`, `build/coverage/coverage-by-file.txt` |
| TSan | `scripts/test-lanes.sh tsan` | Blocked before XCTest | `scripts/tsan-smoke.sh` reported `TSAN/UNAVAILABLE: standalone clang ThreadSanitizer runtime failed to launch` after SIGSEGV 11 |

Coverage is the `xccov` result for the app target and test bundle in the named
artifact; it is not a claim that every source file or UI path is covered.
There is no target percentage goal in this baseline.

## Model-security closure evidence — 2026-07-26

At checkout `72762ed`, `scripts/test-lanes.sh unit` executed **470 tests with
0 failures and 0 skips**. `scripts/test-lanes.sh repeat` completed three relaunch
iterations of the same 470-test selection with no failures. The complete
unsigned `MacTalk` XCTest scheme executed **495 tests with 0 failures and
1 skipped external-prerequisite test**. All **25** `scripts/tests/test_*.sh`
files passed, followed by the blocking static, security, and documentation
checks. `xcodegen generate` produced no project drift and `git diff --check`
passed. These results used fakes, an isolated deterministic-lane HOME, and no
provider network, TCC, capture hardware, or real transcription model.

A signed `./build.sh run` also built and relaunched the Release app on this host.
That result is local signing/build evidence only; it is not notarization,
hardware/TCC validation, real-model inference, or release publication evidence.

## Manual and external gaps

- **Hardware/TCC:** mic-only and Mic + App Audio need manual validation on a
  supported Mac. The checks require microphone permission; app/system audio
  additionally requires Screen Recording; auto-paste requires Accessibility.
  `scripts/test-lanes.sh hardware` intentionally requires
  `MACTALK_HARDWARE_VALIDATION_ACK=I_HAVE_AUTHORIZED_CAPTURE` and does not
  download a model. These manual checks were not run for this baseline.
- **Models:** deterministic tests use fake engines/downloaders. A real-model
  check may use exactly one already provisioned catalog model via
  `MACTALK_EXISTING_MODEL_PATH`; it must pass catalog filename and SHA-256
  validation and never repair or download the artifact. Provider downloads are
  an explicit release/user operation, not unit-test evidence.
- **Signing/release:** local archive/notarization requires Apple membership, a
  Developer ID certificate **and private key**, notarization credentials, and
  the protected GitHub `release` environment with reviewers, variables,
  secrets, and release write permission. Those are external blockers; this
  document does not claim notarization or publication.

## Repository metadata facts

The root `LICENSE` uses **Benedict Bleimschein, 2025**: the repository history
contains Benedict Bleimschein's 2025 project commits and `project.yml` carries
`NSHumanReadableCopyright` as `Copyright © 2025 MacTalk Development Team`.
The license holder name is therefore recorded from repository ownership/history;
the project metadata supplies the year.

## Current source facts

`project.yml` sets macOS deployment target `26.0`, Swift `6.0`, strict
concurrency `complete`, and FluidAudio exact version `0.15.5`. The committed
SwiftPM resolution pins revision
`19600a485baa4998812e4654b70d2bab8f2c9949`. Release metadata in
`scripts/release-version.env` is marketing version `1.1.5`, build `6`.

The app has Whisper and Parakeet providers. Captured audio is processed locally
by the selected engine after models are present, but model download code has
network URLs; therefore “offline” means after provisioning, not “no network
code exists.”

At model-security cutover commit
`d6eab1041efc024976502099c157907274ff3154`, production Parakeet composition
uses the canonical source store, a descriptor-backed verified snapshot, and
retained in-memory CoreML assets. Production source contains no compiled/path
loading fallback. Legacy compiled storage is retired only after successful
source publication through validated, quarantined, retryable cleanup. The
canonical provenance lock SHA-256 at that commit is
`9707fb09598e23902d5a3847e84acae468ca85b357d6c100b199f35a7312e3b2`.
During Task 12, the sole maintainer declared approval and risk acceptance for
that lock and cutover under the documented solo-maintainer governance policy.
This repository record is not represented as a cryptographically authenticated,
independent, or branch-protection-backed approval.
