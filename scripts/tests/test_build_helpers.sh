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

fake_app="$tmpdir/Fake.app"
mkdir -p "$fake_app/Contents/MacOS"
cat >"$fake_app/Contents/MacOS/MacTalk" <<'SH'
#!/bin/bash
exit 99
SH
chmod +x "$fake_app/Contents/MacOS/MacTalk"

mkdir -p "$tmpdir/fakebin"
cat >"$tmpdir/fakebin/open" <<'SH'
#!/bin/bash
exit 1
SH
chmod +x "$tmpdir/fakebin/open"

if PATH="$tmpdir/fakebin:$PATH" launch_mactalk_app "$fake_app" >/tmp/build-helper-launch-out.txt 2>/tmp/build-helper-launch-err.txt; then
  echo "expected launch helper to fail when open fails" >&2
  exit 1
fi

if ! grep -q 'refusing to launch the inner binary directly' /tmp/build-helper-launch-err.txt; then
  echo "expected launch helper to explain why direct binary launch is refused" >&2
  exit 1
fi

echo "build helper tests passed"
