#!/usr/bin/env bash
# Standalone compiler/runtime smoke. This must run before XCTest so an Apple
# runtime failure cannot be mistaken for an uninstrumented test pass.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/mactalk-tsan-standalone.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

command -v clang >/dev/null || { echo 'TSAN/UNAVAILABLE: clang is not installed' >&2; exit 1; }
clang -fsanitize=thread -O0 -g "$ROOT/scripts/tsan-smoke.c" -o "$WORK/tsan-smoke"
if ! "$WORK/tsan-smoke"; then
    echo 'TSAN/UNAVAILABLE: standalone clang ThreadSanitizer runtime failed to launch' >&2
    exit 1
fi
if ! otool -L "$WORK/tsan-smoke" | grep -Eq 'libclang_rt\.tsan.*\.dylib'; then
    echo 'TSAN/FAIL: standalone smoke is not linked to the ThreadSanitizer runtime' >&2
    exit 1
fi
echo 'standalone clang ThreadSanitizer smoke passed with runtime link'
