#!/bin/bash
# Produce an xcresult bundle and per-file xccov reports for deterministic tests.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source "$ROOT/scripts/deterministic-test-selection.sh"
OUT="${MACTALK_COVERAGE_DIR:-$ROOT/build/coverage}"
rm -rf "$OUT"
mkdir -p "$OUT"
RESULT="$OUT/MacTalk.xcresult"
TEST_HOME="$(mktemp -d "${TMPDIR:-/tmp}/mactalk-coverage-home.XXXXXX")"
trap 'rm -rf "$TEST_HOME"' EXIT
export HOME="$TEST_HOME"
export CFFIXED_USER_HOME="$TEST_HOME"
export OS_ACTIVITY_MODE=disable
ARGS=()
while IFS= read -r argument; do ARGS+=("$argument"); done < <(append_deterministic_test_selection)
MACTALK_TEST_LANE=unit xcodebuild test -project MacTalk.xcodeproj -scheme MacTalk \
  -destination 'platform=macOS' -resultBundlePath "$RESULT" \
  -enableCodeCoverage YES "${ARGS[@]}" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO ENABLE_THREAD_SANITIZER=NO
xcrun xccov view --report --json "$RESULT" > "$OUT/coverage.json"
xcrun xccov view --report "$RESULT" > "$OUT/coverage-by-file.txt"
echo "Coverage bundle: $RESULT"
echo "Per-file report: $OUT/coverage-by-file.txt"
