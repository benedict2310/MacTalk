# CI validation policy

The Xcode-dependent pull-request, scheduled/manual, and AppKit lanes (`unit`,
`coverage`, and `appkit`) run on the GitHub-hosted Apple-Silicon `macos-26`
image. The TSan job
uses the hosted `macos-15` image because the Apple ThreadSanitizer runtime in
the current `macos-26` image crashes before XCTest. All four lanes select the
concrete `/Applications/Xcode_26.0.1.app/Contents/Developer` toolchain through
`DEVELOPER_DIR`; each lane fails closed when it is absent and verifies
`xcodebuild -version` against `MACTALK_XCODE_VERSION` (`26.0.1`).
XcodeGen 2.44.1 (archive SHA-256 is verified by
`scripts/install_xcodegen.sh`). Unit and coverage regenerate the project and
require no generated diff. SwiftPM resolution is `MacTalk.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
The lint, security, and documentation checks remain on `macos-15` because they
do not invoke Xcode.

## Pull-request and evidence lanes

* **unit** runs `scripts/test-lanes.sh unit` as the sole deterministic XCTest
  pull-request gate. Its explicit allowlist excludes AppKit/window, TCC, capture
  hardware, providers, network, and real models.
* **coverage** is scheduled/manual evidence. It reruns that allowlist, writes an
  xcresult and JSON/per-file `xccov` reports, and publishes
  executed/failed/skipped counts plus production target coverage. When invoked,
  its test exit status fails the run and reports/logs upload with `if: always()`;
  it is not a duplicate pull-request gate.
* **lint**, **security**, and **documentation** are blocking pull-request
  checks. Their scripts fail on violations; they do not warn-and-pass.

AppKit/window checks are a separate manual `appkit` lane. Hardware/TCC and
real-model checks are explicit local lanes requiring their documented
acknowledgement/path and are never selected by CI automatically.

## TSan

The scheduled/manual TSan job uses the hosted `macos-15` image and requires
the concrete pinned Xcode 26.0.1 toolchain
(`/Applications/Xcode_26.0.1.app/Contents/Developer`). A TSan-only
`MACOSX_DEPLOYMENT_TARGET=15.0` override makes the app test host runnable on
that image; release and product builds retain their macOS 26.0 deployment
target. If the hosted image does not provide the toolchain or Apple
ThreadSanitizer runtime, the job fails with an explicit `TSAN/UNAVAILABLE`
blocker. It first runs
`scripts/tsan-smoke.sh` (`clang -fsanitize=thread`) and then builds the
instrumented XCTest bundle and verifies its `libclang_rt.tsan` link. It runs
`ConcurrencyStressTests` and `AudioMixerTests` three times in fresh test
processes, followed by the complete macOS 15-supported deterministic subset,
with explicit `-enableThreadSanitizer YES`. Hosted run `31272883974` established
three narrow runtime incompatibilities: `ParakeetStoreFileLockTests` subprocess
probes terminate with status 15, macOS 15 CoreML rejects the version-10 fixture
used by `VerifiedCoreMLByteAssetTests`, and
`VerifiedParakeetModelLoaderTests` stalls at its first cancellation test. Those
classes remain blocking in the ordinary macOS 26 unit lane but are excluded
from the hosted TSan subset; every other deterministic class remains selected.
An XCTest pass is never reported without the sanitizer runtime checks.
