#!/usr/bin/env bash
# Emit deterministic test counts and production-only coverage to stdout and,
# when requested, the GitHub Job Summary. Missing result data is reported as an
# external/reporting failure; it never converts a failed test into a pass.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RESULT="${1:-$ROOT/build/coverage/MacTalk.xcresult}"
OUT="$(dirname "$RESULT")"
SUMMARY_FILE="${MACTALK_COVERAGE_SUMMARY_FILE:-}"
mkdir -p "$OUT"

status='unavailable'
executed='unavailable'
failed='unavailable'
skipped='unavailable'
summary_status=0
if [ -d "$RESULT" ]; then
    test_summary="$OUT/test-results-summary.json"
    parsed_summary="$OUT/test-results-summary.parsed"
    if ! xcrun xcresulttool get test-results summary --path "$RESULT" --compact > "$test_summary"; then
        echo 'Coverage summary unavailable: xcresult test summary could not be read' >&2
        summary_status=1
    elif ! python3 "$ROOT/scripts/coverage-summary-parser.py" "$test_summary" > "$parsed_summary"; then
        summary_status=1
    else
        IFS=$'\t' read -r status executed failed skipped < "$parsed_summary"
    fi
else
    echo "Coverage summary unavailable: result bundle does not exist: $RESULT" >&2
    summary_status=1
fi

production='unavailable'
if [ -f "$OUT/coverage.json" ]; then
    production="$(python3 - "$OUT/coverage.json" <<'PY'
import json
import sys
payload = json.load(open(sys.argv[1]))
targets = payload.get('targets', [])
selected = [target for target in targets if target.get('name') in ('MacTalk', 'MacTalk.app')]
files = [file for target in selected for file in target.get('files', [])]
executable = sum(int(file.get('executableLines', 0)) for file in files)
covered = sum(int(file.get('coveredLines', 0)) for file in files)
if executable == 0:
    print('unavailable')
else:
    print(f'{covered}/{executable} ({covered / executable * 100:.2f}%)')
PY
)"
fi

lines=(
  '## MacTalk deterministic coverage'
  ''
  "- Test result: $status"
  "- Executed: $executed"
  "- Failed: $failed"
  "- Skipped: $skipped"
  "- Production line coverage (MacTalk target): $production"
  "- Deterministic test allowlist: scripts/deterministic-test-selection.sh"
)
printf '%s\n' "${lines[@]}"
if [ -n "$SUMMARY_FILE" ]; then
    printf '%s\n' "${lines[@]}" >> "$SUMMARY_FILE"
fi
exit "$summary_status"
