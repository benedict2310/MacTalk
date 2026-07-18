#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EXPECTED_FLUIDAUDIO_REVISION="19600a485baa4998812e4654b70d2bab8f2c9949"
EXPECTED_FLUIDAUDIO_VERSION="0.15.5"
LOCKFILE="MacTalk.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

# Generate in a clean archive of HEAD, never in the caller checkout. This keeps
# ignored build output and dirty generated files from affecting the result or
# being rewritten by xcodegen.
GENERATE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/mactalk-project-generation.XXXXXX")"
trap 'rm -rf "$GENERATE_ROOT"' EXIT

git -C "$ROOT" archive --format=tar HEAD | tar -x -C "$GENERATE_ROOT"

python3 - "$GENERATE_ROOT/project.yml" "$GENERATE_ROOT/$LOCKFILE" "$EXPECTED_FLUIDAUDIO_REVISION" "$EXPECTED_FLUIDAUDIO_VERSION" <<'PY'
import json
import pathlib
import re
import sys

project_name, lockfile_name, revision, version = sys.argv[1:]
project = pathlib.Path(project_name).read_text()
if f"exactVersion: {version}" not in project:
    raise SystemExit("project.yml must pin FluidAudio to the reviewed exact version")
if re.search(r"^\s+from:\s+|^\s+upToNext", project, re.MULTILINE):
    raise SystemExit("project.yml must not use a FluidAudio version range")

lockfile = pathlib.Path(lockfile_name)
if not lockfile.is_file():
    raise SystemExit(f"missing canonical SwiftPM resolution: {lockfile_name}")
data = json.loads(lockfile.read_text())
fluid = next((p for p in data["pins"] if p["identity"].lower() == "fluidaudio"), None)
if fluid is None:
    raise SystemExit("Package.resolved has no FluidAudio pin")
state = fluid["state"]
if state.get("revision") != revision:
    raise SystemExit(f"FluidAudio lock revision is {state.get('revision')!r}, expected {revision!r}")
if state.get("version") != version:
    raise SystemExit(f"FluidAudio lock version is {state.get('version')!r}, expected {version!r}")
print(f"FluidAudio pinned at {version} ({revision})")
PY

# The generated files in the archive are the tracked baseline. xcodegen must
# reproduce them byte-for-byte in its private temporary copy.
XCODEPROJ="$GENERATE_ROOT/MacTalk.xcodeproj"
BEFORE_PROJECT="$(mktemp)"
BEFORE_LOCK="$(mktemp)"
BEFORE_SCHEMES="$(mktemp -d)"
BEFORE_SCHEME_LIST="$(mktemp)"
AFTER_SCHEME_LIST="$(mktemp)"
trap 'rm -f "$BEFORE_PROJECT" "$BEFORE_LOCK" "$BEFORE_SCHEME_LIST" "$AFTER_SCHEME_LIST"; rm -rf "$BEFORE_SCHEMES" "$GENERATE_ROOT"' EXIT
cp "$XCODEPROJ/project.pbxproj" "$BEFORE_PROJECT"
cp "$GENERATE_ROOT/$LOCKFILE" "$BEFORE_LOCK"
(
  cd "$GENERATE_ROOT"
  find MacTalk.xcodeproj/xcshareddata/xcschemes -type f -name '*.xcscheme' -print | sort
) > "$BEFORE_SCHEME_LIST"
while IFS= read -r scheme; do
  destination="$BEFORE_SCHEMES/$scheme"
  mkdir -p "$(dirname "$destination")"
  cp "$GENERATE_ROOT/$scheme" "$destination"
done < "$BEFORE_SCHEME_LIST"

(cd "$GENERATE_ROOT" && xcodegen generate >/dev/null)
cmp -s "$BEFORE_PROJECT" "$XCODEPROJ/project.pbxproj" || {
  echo "xcodegen output differs from tracked project.pbxproj" >&2
  exit 1
}
cmp -s "$BEFORE_LOCK" "$GENERATE_ROOT/$LOCKFILE" || {
  echo "xcodegen changed tracked Package.resolved" >&2
  exit 1
}
(
  cd "$GENERATE_ROOT"
  find MacTalk.xcodeproj/xcshareddata/xcschemes -type f -name '*.xcscheme' -print | sort
) > "$AFTER_SCHEME_LIST"
if ! cmp -s "$BEFORE_SCHEME_LIST" "$AFTER_SCHEME_LIST"; then
  echo "xcodegen added or removed a tracked shared scheme" >&2
  if ! diff -u "$BEFORE_SCHEME_LIST" "$AFTER_SCHEME_LIST" >&2; then
    echo "scheme list differs as expected" >&2
  fi
  exit 1
fi
while IFS= read -r scheme; do
  cmp -s "$BEFORE_SCHEMES/$scheme" "$GENERATE_ROOT/$scheme" || {
    echo "xcodegen output differs from tracked shared scheme: $scheme" >&2
    exit 1
  }
done < "$BEFORE_SCHEME_LIST"

if ! xcodebuild -list -project "$XCODEPROJ" 2>/dev/null | grep -Fx '        MacTalk-TSan'; then
    echo "MacTalk-TSan scheme is not discoverable" >&2
    exit 1
fi

echo "reproducible project generation verified in isolated clean copy"
