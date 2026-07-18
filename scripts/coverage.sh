#!/bin/bash
# Produce an xcresult bundle and per-file xccov reports without model/network use.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OUT="${MACTALK_COVERAGE_DIR:-$ROOT/build/coverage}"
rm -rf "$OUT"
mkdir -p "$OUT"
RESULT="$OUT/MacTalk.xcresult"
MACTALK_TEST_LANE=unit xcodebuild test -project MacTalk.xcodeproj -scheme MacTalk \
  -destination 'platform=macOS' -resultBundlePath "$RESULT" \
  -skip-testing:MacTalkTests/RealModelLaneTests -enableCodeCoverage YES \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
xcrun xccov view --report --json "$RESULT" > "$OUT/coverage.json"
xcrun xccov view --report "$RESULT" > "$OUT/coverage-by-file.txt"
echo "Coverage bundle: $RESULT"
echo "Per-file report: $OUT/coverage-by-file.txt"
