#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/../.."
source scripts/build_helpers.sh

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

old_app="$tmpdir/DerivedData/MacTalk-old/Build/Products/Release/MacTalk.app"
new_app="$tmpdir/DerivedData/MacTalk-new/Build/Products/Release/MacTalk.app"
mkdir -p "$old_app" "$new_app"

touch -t 202604142000 "$old_app"
touch -t 202604142100 "$new_app"

resolved="$(resolve_latest_mactalk_app_path "$tmpdir/DerivedData" Release)"
if [[ "$resolved" != "$new_app" ]]; then
  echo "expected latest app path '$new_app' but got '$resolved'" >&2
  exit 1
fi

if resolve_latest_mactalk_app_path "$tmpdir/DerivedData/missing" Release >/tmp/build-helper-empty.txt 2>/dev/null; then
  echo "expected helper to fail when no app exists" >&2
  exit 1
fi

echo "build helper tests passed"
