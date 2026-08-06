#!/usr/bin/env bash
# Verify the XCTest executable itself links the Apple ThreadSanitizer runtime.
set -euo pipefail
executable="${1:?usage: verify-tsan-runtime.sh path-to-test-executable}"
[ -x "$executable" ] || { echo "TSAN/FAIL: test executable is missing or not executable: $executable" >&2; exit 1; }
linkage="$(otool -L "$executable")"
printf '%s\n' "$linkage"
if ! grep -Eq 'libclang_rt\.tsan.*\.dylib' <<< "$linkage"; then
    echo "TSAN/FAIL: XCTest executable has no ThreadSanitizer runtime link: $executable" >&2
    exit 1
fi
echo "XCTest ThreadSanitizer runtime link verified: $executable"
