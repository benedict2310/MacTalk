#!/bin/bash
# Produce an xcresult bundle and per-file xccov reports for deterministic tests.
# The xcodebuild status remains authoritative even when report extraction fails.
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

set +e
MACTALK_TEST_LANE=unit xcodebuild test -project MacTalk.xcodeproj -scheme MacTalk \
  -destination 'platform=macOS' -resultBundlePath "$RESULT" \
  -enableCodeCoverage YES "${ARGS[@]}" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO ENABLE_THREAD_SANITIZER=NO 2>&1 | tee "$OUT/xcodebuild.log"
test_status=${PIPESTATUS[0]}
set -e

report_status=0
if [ -d "$RESULT" ]; then
    if ! xcrun xccov view --report --json "$RESULT" > "$OUT/coverage.json"; then
        echo 'Coverage report extraction failed' >&2
        report_status=1
    fi
    if ! xcrun xccov view --report "$RESULT" > "$OUT/coverage-by-file.txt"; then
        echo 'Per-file coverage report extraction failed' >&2
        report_status=1
    fi
else
    echo "Coverage result bundle was not produced: $RESULT" >&2
    report_status=1
fi

printf 'Coverage bundle: %s\n' "$RESULT"
printf 'Per-file report: %s\n' "$OUT/coverage-by-file.txt"
if [ "$test_status" -ne 0 ]; then
    exit "$test_status"
fi
exit "$report_status"
