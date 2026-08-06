# CI validation policy

The Xcode-dependent pull-request and manual lanes (`unit`, `coverage`, `tsan`,
and `appkit`) run on the GitHub-hosted Apple-Silicon `macos-26` image. They
select the concrete `/Applications/Xcode_26.0.1.app/Contents/Developer`
toolchain through `DEVELOPER_DIR`; each lane fails closed when it is absent and
verifies `xcodebuild -version` against `MACTALK_XCODE_VERSION` (`26.0`).
XcodeGen 2.44.1 (archive SHA-256 is verified by
`scripts/install_xcodegen.sh`). Unit and coverage regenerate the project and
require no generated diff. SwiftPM resolution is `MacTalk.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
The lint, security, and documentation checks remain on `macos-15` because they
do not invoke Xcode.

## Blocking lanes

* **unit** runs `scripts/test-lanes.sh unit`, whose explicit allowlist excludes
  AppKit/window, TCC, capture hardware, providers, network, and real models.
* **coverage** reruns that same allowlist, writes an xcresult and JSON/per-file
  `xccov` reports, and publishes executed/failed/skipped counts plus production
  target coverage. The test exit status remains blocking; reports and logs are
  uploaded with `if: always()`.
* **lint**, **security**, and **documentation** are blocking checks. Their
  scripts fail on violations; they do not warn-and-pass.

AppKit/window checks are a separate manual `appkit` lane. Hardware/TCC and
real-model checks are explicit local lanes requiring their documented
acknowledgement/path and are never selected by CI automatically.

## TSan

The scheduled/manual TSan job uses the hosted `macos-26` image and requires
the concrete pinned Xcode 26.0.1 toolchain
(`/Applications/Xcode_26.0.1.app/Contents/Developer`). If that image does not
provide the toolchain or Apple ThreadSanitizer runtime, the job fails with an
explicit `TSAN/UNAVAILABLE` blocker. It first runs
`scripts/tsan-smoke.sh` (`clang -fsanitize=thread`) and then builds the
instrumented XCTest bundle, verifies its `libclang_rt.tsan` link, and runs
`ConcurrencyStressTests` and `AudioMixerTests` with explicit
`-enableThreadSanitizer YES`. An XCTest pass is never reported without those
runtime checks.
