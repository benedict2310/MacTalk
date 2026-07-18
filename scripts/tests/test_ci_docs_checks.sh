#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK="$ROOT/scripts/ci-docs-checks.sh"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/mactalk-docs-fixture.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT

# Keep the fixture hermetic and test the checker through its supported root
# override rather than mutating the working checkout.
tar -C "$ROOT" --exclude=.git --exclude=build -cf - . | tar -C "$fixture" -xf -
MACTALK_DOCS_ROOT="$fixture" "$CHECK" >/dev/null

rm "$fixture/LICENSE"
if MACTALK_DOCS_ROOT="$fixture" "$CHECK" >/dev/null 2>&1; then
    echo "docs checker accepted a missing LICENSE" >&2
    exit 1
fi
cp "$ROOT/LICENSE" "$fixture/LICENSE"

# A source/config mismatch must fail even when STATUS still contains the old
# value; this guards against a verifier that only searches for text.
sed -i.bak 's/macOS: "26.0"/macOS: "14.0"/' "$fixture/project.yml"
rm -f "$fixture/project.yml.bak"
if MACTALK_DOCS_ROOT="$fixture" "$CHECK" >/dev/null 2>&1; then
    echo "docs checker accepted a deployment-target mismatch" >&2
    exit 1
fi

echo "ci-docs-checks negative fixtures passed"
