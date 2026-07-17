#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/../.."

script="scripts/hardware-validation.sh"
if ! grep -Fq 'source "$ROOT/scripts/build_helpers.sh"' "$script"; then
  echo "hardware validation launcher must source build_helpers.sh" >&2
  exit 1
fi
if ! grep -Fq 'resolve_latest_mactalk_app_path "$HOME/Library/Developer/Xcode/DerivedData" "$CONFIGURATION"' "$script"; then
  echo "hardware validation launcher must resolve the app after a successful build" >&2
  exit 1
fi
if grep -Fq 'find "$HOME/Library/Developer/Xcode/DerivedData"' "$script"; then
  echo "hardware validation launcher must not select an app with find" >&2
  exit 1
fi

source scripts/build_helpers.sh

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

derived_data="$tmpdir/DerivedData"
stale_app="$derived_data/MacTalk-stale/Build/Products/Release/MacTalk.app"
new_app="$derived_data/MacTalk-just-built/Build/Products/Release/MacTalk.app"
debug_app="$derived_data/MacTalk-just-built/Build/Products/Debug/MacTalk.app"
mkdir -p "$stale_app/Contents/MacOS" "$new_app/Contents/MacOS" "$debug_app/Contents/MacOS"

# A stale bundle can have a newer bundle-directory mtime, but its old binary
# must not beat the binary produced by the completed Release build.
touch "$stale_app/Contents/MacOS/MacTalk" "$new_app/Contents/MacOS/MacTalk" "$debug_app/Contents/MacOS/MacTalk"
touch -t 202604142000 "$stale_app/Contents/MacOS/MacTalk"
touch -t 202604142100 "$new_app/Contents/MacOS/MacTalk"
touch -t 202604142200 "$debug_app/Contents/MacOS/MacTalk"
touch -t 202604142300 "$stale_app"

after_build_app="$(resolve_latest_mactalk_app_path "$derived_data" Release)"
if [[ "$after_build_app" != "$new_app" ]]; then
  echo "expected newest built Release app '$new_app' but got '$after_build_app'" >&2
  exit 1
fi

if [[ "$(resolve_latest_mactalk_app_path "$derived_data" Debug)" != "$debug_app" ]]; then
  echo "expected configuration-specific Debug app" >&2
  exit 1
fi

echo "hardware validation launcher tests passed"
