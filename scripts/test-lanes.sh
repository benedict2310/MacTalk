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
  MACTALK_TEST_LANE=tsan xcodebuild test -project "$PROJECT" -scheme MacTalk-TSan \
    -destination "$DESTINATION" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO "$@"
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
  # A TSan result is valid only if the generated scheme enables instrumentation
  # and its standalone smoke test actually launches under the Apple runtime.
  SCHEME_FILE="$PROJECT/xcshareddata/xcschemes/MacTalk-TSan.xcscheme"
  grep -q 'buildConfiguration = "DebugTSan"' "$SCHEME_FILE" && \
    grep -q 'ENABLE_THREAD_SANITIZER = YES;' "$PROJECT/project.pbxproj" || {
    echo "TSAN/UNAVAILABLE: generated MacTalk-TSan scheme/configuration is not instrumented" >&2
    exit 78
  }
  SMOKE_LOG="$(mktemp "${TMPDIR:-/tmp}/mactalk-tsan-smoke.XXXXXX")"
  set +e
  run_tsan_command -only-testing:MacTalkTests/TSanSmokeTests 2>&1 | tee "$SMOKE_LOG"
  smoke_status=${PIPESTATUS[0]}
  set -e
  if [ "$smoke_status" -ne 0 ]; then
    if grep -Eiq 'ThreadSanitizer: (CHECK FAILED|unexpected memory mapping|failed to|FATAL)|EXC_CRASH|SIGABRT|signal (segv|bus)|Early unexpected exit|before establishing connection|dyld: Library not loaded' "$SMOKE_LOG"; then
      echo "TSAN/UNAVAILABLE: Apple Thread Sanitizer runtime crashed during standalone smoke; no instrumented pass claimed"
      rm -f "$SMOKE_LOG"
      exit 0
    fi
    echo "TSAN/FAIL: standalone instrumented smoke failed to compile or run" >&2
    rm -f "$SMOKE_LOG"
    exit "$smoke_status"
  fi
  rm -f "$SMOKE_LOG"
  run_tsan_command "${DETERMINISTIC_ARGS[@]}"
  ;;
all)
  run_xctest unit
  ;;
*)
  echo "usage: $0 {unit|repeat|appkit|hardware|real-model|tsan|all}" >&2
  exit 64
  ;;
esac
