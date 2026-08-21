# Development setup

**Verified baseline:** 2026-07-18. Commands below are the current commands;
configuration claims are checked by `scripts/ci-docs-checks.sh`.

## Required toolchain

- macOS with the SDK that provides the project's macOS `26.0` deployment target.
- Xcode 26.0.1 (Build 17A400) was the toolchain used for the baseline. The
  repository does not claim that older Xcode/macOS combinations work.
- XcodeGen 2.44.1. CI installs the pinned archive using
  `scripts/install_xcodegen.sh`.
- CMake and Git for the whisper.cpp submodule build.
- Apple Silicon is the maintained/performance validation lane; Intel behavior
  has not been established by this baseline.

Check the installed tools without changing the checkout:

```sh
sw_vers
xcodebuild -version
xcodegen --version
cmake --version
xcode-select -p
```

## Clone and generate

```sh
git clone https://github.com/benedict2310/MacTalk.git
cd MacTalk
git submodule update --init --recursive
xcodegen generate
```

`project.yml` is authoritative. The generated project and shared schemes are
tracked reproducibility artifacts; after generation, `git diff --exit-code --
MacTalk.xcodeproj` must be clean on a checkout whose generated files are
current. SwiftPM resolution is the committed
`MacTalk.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
FluidAudio is exact version `0.15.5` at revision
`19600a485baa4998812e4654b70d2bab8f2c9949`; do not replace it with a range.

```sh
xcodebuild -resolvePackageDependencies \
  -project MacTalk.xcodeproj -scheme MacTalk
```

## Build whisper.cpp (no model required)

The app links the dylibs produced by this submodule. Build them before the
app if `Vendor/whisper.cpp/build` is absent:

```sh
cmake -S Vendor/whisper.cpp -B Vendor/whisper.cpp/build \
  -DCMAKE_BUILD_TYPE=Release -DGGML_METAL=ON
cmake --build Vendor/whisper.cpp/build --config Release \
  -j "$(sysctl -n hw.ncpu)"
```

This builds libraries and Metal support; it does not download a transcription
model. Model downloads are a separate, user/release operation and every
catalog entry is SHA-256 checked before installation.

## Build and launch

`build.sh` sources `scripts/release-version.env` (`1.1.5`, build `6` in this
baseline), targets arm64 Release, and requires the configured Developer ID
identity for its normal signed path:

```sh
./build.sh build
./build.sh run
```

`./build.sh run` kills an existing `MacTalk` process and launches the newly
built app. A successful build does not prove microphone, Screen Recording,
Accessibility, or model behavior. To reset stale Accessibility approval after
a changed local code signature:

```sh
./build.sh reset-perms
```

Do not run that command in CI. TCC prompts and state are host-global and must be
manually authorized.

## First-run permissions and one-model policy

- Mic-only recording requires Microphone permission.
- Mic + App Audio requires Screen Recording permission and an app/display
  selection.
- Auto-paste requires Accessibility; clipboard-only output does not.
- Tests use deterministic fake engines and isolated defaults. They never
  download a model or contact a provider.
- The optional `real-model` lane may use exactly one already provisioned local
  catalog model via `MACTALK_EXISTING_MODEL_PATH`. It fails/clearly skips when
the path, catalog filename, or SHA-256 is invalid; it never repairs or downloads
  the artifact.

## Reproducible validation lanes

Run the narrowest lane that proves the change; do not run every lane serially by
default. The complete policy, worker budgets, and lifecycle review protocol are
in [AGENT_WORKFLOW.md](AGENT_WORKFLOW.md).

- **During RED/GREEN:** run the focused XCTest or semantic shell test.
- **Production change before merge:** run `scripts/test-lanes.sh unit`.
- **Concurrency, ownership, synchronization, or audio-pipeline change:** also
  run `scripts/test-lanes.sh tsan` when the runtime is available; hosted CI
  remains the authoritative compatible TSan environment.
- **AppKit change:** run `scripts/test-lanes.sh appkit` when the changed UI
  behavior needs controller/window coverage.
- **Documentation:** run `scripts/ci-docs-checks.sh`; no app restart is needed.
- **Coverage:** run `scripts/coverage.sh` for scheduled/manual evidence, not as
  a duplicate ordinary pull-request validation step.

`repeat` relaunches the deterministic unit lane three times. Coverage writes
`build/coverage/MacTalk.xcresult` and `build/coverage/coverage-by-file.txt`.
TSan first runs a compiler/runtime smoke, verifies an instrumented test binary,
then runs its focused concurrency tests; a TSan result must not be reported when
the Apple runtime is unavailable. Hardware/TCC and real-model lanes are explicit
and are not selected by ordinary pull-request validation.

For release/archive setup, use
[`docs/deployment/RELEASE_WORKFLOW.md`](../deployment/RELEASE_WORKFLOW.md).
For the observed 2026-07-18 result of each lane, use
[`docs/STATUS.md`](../STATUS.md), not an old test-count claim in a historical
story.
