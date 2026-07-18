# CI validation policy

The pull-request blocking lanes run on the GitHub-hosted `macos-15` image with
XcodeGen 2.44.1 (archive SHA-256 is verified by
`scripts/install_xcodegen.sh`). Unit and coverage regenerate the project and
require no generated diff. SwiftPM resolution is `MacTalk.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.

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

The scheduled/manual TSan job uses the known `macos-15` image and requires the
pinned Xcode 26 toolchain (`/Applications/Xcode_26.0.app`). If that image does
not provide the toolchain or Apple ThreadSanitizer runtime, the job fails with
an explicit `TSAN/UNAVAILABLE` blocker. It first runs
`scripts/tsan-smoke.sh` (`clang -fsanitize=thread`) and then builds the
instrumented XCTest bundle, verifies its `libclang_rt.tsan` link, and runs
`ConcurrencyStressTests` and `AudioMixerTests` with explicit
`-enableThreadSanitizer YES`. An XCTest pass is never reported without those
runtime checks.
