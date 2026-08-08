#!/bin/bash
# Deterministic test-lane entry point. No lane below unit may download models,
# contact a provider, request TCC permission, or use real capture hardware.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
PROJECT="MacTalk.xcodeproj"
SCHEME="MacTalk"
DESTINATION="platform=macOS"
source "$ROOT/scripts/deterministic-test-selection.sh"

TEST_HOME="$(mktemp -d "${TMPDIR:-/tmp}/mactalk-test-home.XXXXXX")"
trap 'rm -rf "$TEST_HOME"' EXIT
export HOME="$TEST_HOME"
export CFFIXED_USER_HOME="$TEST_HOME"
export OS_ACTIVITY_MODE=disable

# Keep extracted status-bar coordinators free of production globals in every
# deterministic lane, before any XCTest work begins.
"$ROOT/scripts/statusbar-source-guard.sh"

DETERMINISTIC_ARGS=()
while IFS= read -r argument; do
  DETERMINISTIC_ARGS+=("$argument")
done < <(append_deterministic_test_selection)

run_xctest() {
  local lane="$1"
  shift
  MACTALK_TEST_LANE="$lane" xcodebuild test -project "$PROJECT" -scheme "$SCHEME" \
    -destination "$DESTINATION" "${DETERMINISTIC_ARGS[@]}" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO ENABLE_THREAD_SANITIZER=NO "$@"
}

run_tsan_command() {
  # The compatible hosted TSan runtime is macOS 15. Keep this command-line
  # override isolated to instrumented tests; release/product builds remain 26.0.
  MACTALK_TEST_LANE=tsan xcodebuild test -project "$PROJECT" -scheme MacTalk-TSan \
    -destination "$DESTINATION" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
    MACOSX_DEPLOYMENT_TARGET=15.0 \
    ENABLE_THREAD_SANITIZER=YES -enableThreadSanitizer YES "$@"
}

case "${1:-unit}" in
unit)
  run_xctest unit
  ;;
repeat)
  run_xctest unit -test-iterations 3 -test-repetition-relaunch-enabled YES
  ;;
appkit|window)
  MACTALK_TEST_LANE=appkit xcodebuild test -project "$PROJECT" -scheme "$SCHEME" \
    -destination "$DESTINATION" \
    -only-testing:MacTalkTests/HUDWindowControllerTests \
    -only-testing:MacTalkTests/SettingsWindowControllerTests \
    -only-testing:MacTalkTests/StatusBarControllerTests \
    -only-testing:MacTalkTests/StatusMenuPresenterTests \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO ENABLE_THREAD_SANITIZER=NO
  ;;
hardware|tcc)
  : "${MACTALK_HARDWARE_VALIDATION_ACK:?Set MACTALK_HARDWARE_VALIDATION_ACK=I_HAVE_AUTHORIZED_CAPTURE explicitly}"
  exec "$ROOT/scripts/hardware-validation.sh"
  ;;
real-model)
  : "${MACTALK_EXISTING_MODEL_PATH:?Set MACTALK_EXISTING_MODEL_PATH to an existing catalog model; no download is attempted}"
  MACTALK_TEST_LANE=real-model xcodebuild test -project "$PROJECT" -scheme "$SCHEME" \
    -destination "$DESTINATION" -only-testing:MacTalkTests/RealModelLaneTests \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO ENABLE_THREAD_SANITIZER=NO
  ;;
tsan)
  # Run a real compiler/runtime smoke before XCTest. A TSan result is valid
  # only when the generated scheme, test executable, and Apple runtime are all
  # instrumented; runtime crashes are external blockers, never passes.
  "$ROOT/scripts/tsan-smoke.sh"
  SCHEME_FILE="$PROJECT/xcshareddata/xcschemes/MacTalk-TSan.xcscheme"
  grep -q 'buildConfiguration = "DebugTSan"' "$SCHEME_FILE" && \
    grep -q 'ENABLE_THREAD_SANITIZER = YES;' "$PROJECT/project.pbxproj" || {
    echo "TSAN/FAIL: generated MacTalk-TSan scheme/configuration is not instrumented" >&2
    exit 1
  }
  TSAN_DERIVED_DATA="$TEST_HOME/DerivedData"
  run_tsan_command -derivedDataPath "$TSAN_DERIVED_DATA" -only-testing:MacTalkTests/TSanSmokeTests
  TSAN_EXECUTABLE="$(find "$TSAN_DERIVED_DATA" -type f -path '*MacTalkTests.xctest/Contents/MacOS/MacTalkTests' -print -quit)"
  "$ROOT/scripts/verify-tsan-runtime.sh" "$TSAN_EXECUTABLE"
  # Re-run the race-sensitive suites in fresh test processes before the full
  # deterministic lane. This makes transient callback/resampler races more
  # likely to surface while preserving the same instrumented DerivedData.
  run_tsan_command -derivedDataPath "$TSAN_DERIVED_DATA" \
    -only-testing:MacTalkTests/ConcurrencyStressTests \
    -only-testing:MacTalkTests/AudioMixerTests \
    -test-iterations 3 -test-repetition-relaunch-enabled YES
  run_tsan_command -derivedDataPath "$TSAN_DERIVED_DATA" \
    "${DETERMINISTIC_ARGS[@]}"
  ;;
all)
  run_xctest unit
  ;;
*)
  echo "usage: $0 {unit|repeat|appkit|hardware|real-model|tsan|all}" >&2
  exit 64
  ;;
esac
