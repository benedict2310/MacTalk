#!/bin/bash
# Deterministic test-lane entry point. No lane below unit may download models.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
PROJECT="MacTalk.xcodeproj"
SCHEME="MacTalk"
DESTINATION="platform=macOS"

run_xctest() {
  MACTALK_TEST_LANE="$1" xcodebuild test -project "$PROJECT" -scheme "$SCHEME" \
    -destination "$DESTINATION" -skip-testing:MacTalkTests/RealModelLaneTests \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO "${@:2}"
}

case "${1:-unit}" in
unit)
  # The lane contains no XCTest skips: the opt-in model class is excluded.
  run_xctest unit
  ;;
repeat)
  # XCTest randomizes execution order; repeat also catches leaked session state.
  run_xctest unit -test-iterations 3 -test-repetition-relaunch-enabled YES
  ;;
appkit|window)
  run_xctest appkit \
    -only-testing:MacTalkTests/HUDWindowControllerTests \
    -only-testing:MacTalkTests/SettingsWindowControllerTests \
    -only-testing:MacTalkTests/StatusBarControllerTests
  ;;
hardware|tcc)
  : "${MACTALK_HARDWARE_VALIDATION_ACK:?Set MACTALK_HARDWARE_VALIDATION_ACK=I_HAVE_AUTHORIZED_CAPTURE explicitly}"
  exec "$ROOT/scripts/hardware-validation.sh"
  ;;
real-model)
  : "${MACTALK_EXISTING_MODEL_PATH:?Set MACTALK_EXISTING_MODEL_PATH to an existing catalog model; no download is attempted}"
  MACTALK_TEST_LANE=real-model xcodebuild test -project "$PROJECT" -scheme "$SCHEME" \
    -destination "$DESTINATION" -only-testing:MacTalkTests/RealModelLaneTests \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
  ;;
all)
  run_xctest unit
  ;;
*)
  echo "usage: $0 {unit|repeat|appkit|hardware|real-model|all}" >&2
  exit 64
  ;;
esac
