#!/bin/bash
# Fixture, schema, and local xcresult integration tests for coverage-summary.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PARSER="$ROOT/scripts/coverage-summary-parser.py"
FIXTURES="$ROOT/scripts/tests/fixtures"

expected=$'Passed\t147\t0\t0'
actual="$(python3 "$PARSER" "$FIXTURES/xcresult-summary-xcode26.json")"
[[ "$actual" == "$expected" ]] || { echo "unexpected Xcode 26 schema: $actual" >&2; exit 1; }

expected=$'Failed\t6\t1\t2'
actual="$(python3 "$PARSER" "$FIXTURES/xcresult-summary-nested.json")"
[[ "$actual" == "$expected" ]] || { echo "unexpected nested schema: $actual" >&2; exit 1; }

expected=$'Failed\t7\t1\t1'
actual="$(python3 "$PARSER" "$FIXTURES/xcresult-summary-multiple-configurations.json")"
[[ "$actual" == "$expected" ]] || { echo "unexpected multi-configuration schema: $actual" >&2; exit 1; }

if python3 "$PARSER" "$FIXTURES/xcresult-summary-missing-count.json" >/dev/null 2>&1; then
  echo 'parser accepted unavailable test counts' >&2
  exit 1
fi

for fixture in \
  xcresult-summary-unrelated-nested-counts.json \
  xcresult-summary-mixed-configurations.json \
  xcresult-summary-empty-configurations.json \
  xcresult-summary-malformed-configurations.json \
  xcresult-summary-non-numeric-configurations.json \
  xcresult-summary-partial-configuration.json; do
  if python3 "$PARSER" "$FIXTURES/$fixture" >/dev/null 2>&1; then
    echo "parser accepted malformed coverage schema: $fixture" >&2
    exit 1
  fi
done

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "$tmpdir/Result.xcresult" "$tmpdir/bin"
cat > "$tmpdir/bin/xcrun" <<SH
#!/bin/bash
set -euo pipefail
case " \$* " in
  *' --format '* ) echo 'unsupported --format' >&2; exit 2 ;;
esac
[[ " \$* " == *' --path '* && " \$* " == *' --compact '* ]] || { echo 'missing supported xcresulttool arguments' >&2; exit 2; }
cat "$FIXTURES/xcresult-summary-xcode26.json"
SH
chmod +x "$tmpdir/bin/xcrun"
summary_output="$(PATH="$tmpdir/bin:$PATH" bash "$ROOT/scripts/coverage-summary.sh" "$tmpdir/Result.xcresult")"
grep -F -- '- Executed: 147' <<<"$summary_output"
grep -F -- '- Failed: 0' <<<"$summary_output"
grep -F -- '- Skipped: 0' <<<"$summary_output"

cat > "$tmpdir/bin/xcrun" <<SH
#!/bin/bash
cat "$FIXTURES/xcresult-summary-missing-count.json"
SH
chmod +x "$tmpdir/bin/xcrun"
if PATH="$tmpdir/bin:$PATH" bash "$ROOT/scripts/coverage-summary.sh" "$tmpdir/Result.xcresult" >"$tmpdir/unavailable.out" 2>"$tmpdir/unavailable.err"; then
  echo 'coverage summary succeeded with unavailable counts' >&2
  exit 1
fi
grep -F -- '- Executed: unavailable' "$tmpdir/unavailable.out"

genuine="$ROOT/build/coverage/MacTalk.xcresult"
if [[ -d "$genuine" ]] && command -v xcrun >/dev/null 2>&1; then
  IFS=$'\t' read -r result executed failed skipped < <(xcrun xcresulttool get test-results summary --path "$genuine" --compact | python3 "$PARSER" /dev/stdin)
  [[ "$executed" =~ ^[1-9][0-9]*$ ]] || { echo "real xcresult executed count is not positive: $executed" >&2; exit 1; }
  [[ "$failed" =~ ^[0-9]+$ && "$skipped" =~ ^[0-9]+$ ]] || { echo 'real xcresult counts are not numeric' >&2; exit 1; }
  if [[ "$executed" == 147 ]]; then
    [[ "$failed" == 0 && "$skipped" == 0 ]] || { echo 'expected current 147-test result to have no failures/skips' >&2; exit 1; }
  fi
  echo "real xcresult integration passed: $executed/$failed/$skipped"
else
  echo 'real xcresult integration skipped (build/coverage/MacTalk.xcresult unavailable)'
fi

echo 'coverage summary schema tests passed'
