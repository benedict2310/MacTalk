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
cp "$ROOT/project.yml" "$fixture/project.yml"

# Unsupported README claims must remain rejected even if the rest of the
# repository is internally consistent.
printf '\n- Parakeet provides ultra-fast real-time streaming\n' >> "$fixture/README.md"
if MACTALK_DOCS_ROOT="$fixture" "$CHECK" >/dev/null 2>&1; then
    echo "docs checker accepted an unsupported Parakeet streaming claim" >&2
    exit 1
fi
cp "$ROOT/README.md" "$fixture/README.md"
sed -i.bak 's/Once a model is downloaded and verified, the transcription path can run without a network connection\./MacTalk works completely offline./' "$fixture/README.md"
rm -f "$fixture/README.md.bak"
if MACTALK_DOCS_ROOT="$fixture" "$CHECK" >/dev/null 2>&1; then
    echo "docs checker accepted an unqualified offline claim" >&2
    exit 1
fi
cp "$ROOT/README.md" "$fixture/README.md"

# Historical documents must not be presented as current guidance by the hub.
sed -i.bak 's/- Historical: \*\*\[PROGRESS.md\](planning\/PROGRESS.md)\*\* - Historical development status and progress tracking/- **[PROGRESS.md](planning\/PROGRESS.md)** - Current status/' "$fixture/docs/README.md"
rm -f "$fixture/docs/README.md.bak"
if MACTALK_DOCS_ROOT="$fixture" "$CHECK" >/dev/null 2>&1; then
    echo "docs checker accepted a current PROGRESS label" >&2
    exit 1
fi
cp "$ROOT/docs/README.md" "$fixture/docs/README.md"
sed -i.bak 's/Historical: \[XCODE_BUILD.md\]/[XCODE_BUILD.md]/' "$fixture/docs/README.md"
rm -f "$fixture/docs/README.md.bak"
if MACTALK_DOCS_ROOT="$fixture" "$CHECK" >/dev/null 2>&1; then
    echo "docs checker accepted a current XCODE_BUILD label" >&2
    exit 1
fi
cp "$ROOT/docs/README.md" "$fixture/docs/README.md"
sed -i.bak 's/Historical: \*\*\[TEST_COVERAGE.md\]/[TEST_COVERAGE.md]/' "$fixture/docs/README.md"
rm -f "$fixture/docs/README.md.bak"
if MACTALK_DOCS_ROOT="$fixture" "$CHECK" >/dev/null 2>&1; then
    echo "docs checker accepted a current TEST_COVERAGE label" >&2
    exit 1
fi

echo "ci-docs-checks negative fixtures passed"
