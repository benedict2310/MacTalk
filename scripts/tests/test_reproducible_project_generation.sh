#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

EXPECTED_FLUIDAUDIO_REVISION="19600a485baa4998812e4654b70d2bab8f2c9949"
EXPECTED_FLUIDAUDIO_VERSION="0.15.5"
LOCKFILE="MacTalk.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

python3 - "$EXPECTED_FLUIDAUDIO_REVISION" "$EXPECTED_FLUIDAUDIO_VERSION" "$LOCKFILE" <<'PY'
import json
import pathlib
import re
import sys

revision, version, lockfile_name = sys.argv[1:]
project = pathlib.Path("project.yml").read_text()
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

before_project="$(mktemp)"
before_lock="$(mktemp)"
trap 'rm -f "$before_project" "$before_lock"' EXIT
shasum MacTalk.xcodeproj/project.pbxproj MacTalk.xcodeproj/xcshareddata/xcschemes/MacTalk-TSan.xcscheme > "$before_project"
shasum "$LOCKFILE" > "$before_lock"
xcodegen generate >/dev/null
shasum -c "$before_project" >/dev/null
shasum -c "$before_lock" >/dev/null

if ! xcodebuild -list -project MacTalk.xcodeproj 2>/dev/null | grep -Fx '        MacTalk-TSan'; then
    echo "MacTalk-TSan scheme is not discoverable" >&2
    exit 1
fi

echo "reproducible project generation verified"
