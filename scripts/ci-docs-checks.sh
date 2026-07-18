#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

for document in \
  README.md \
  docs/development/ARCHITECTURE.md \
  docs/development/SETUP.md \
  docs/testing/TESTING.md \
  docs/testing/TEST_LANES.md \
  docs/testing/TEST_COVERAGE.md \
  docs/testing/CI.md \
  docs/testing/HARDWARE_AUDIO_VALIDATION.md; do
    test -f "$document" || { echo "missing documentation: $document" >&2; exit 1; }
done

# Reject stale root-level paths that previously made the documentation check
# silently pass on nonexistent files.
if grep -RInE 'docs/(ARCHITECTURE|TESTING|ROADMAP|PROGRESS)[.]md' .github scripts --exclude='CI.md'; then
    echo 'stale documentation path found; use the documented subdirectories' >&2
    exit 1
fi

echo 'blocking documentation checks passed'
