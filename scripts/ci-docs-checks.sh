#!/usr/bin/env bash
set -euo pipefail
ROOT="${MACTALK_DOCS_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
export ROOT

python3 - <<'PY'
import json
import os
import re
from pathlib import Path

root = Path(os.environ["ROOT"])
def fail(message):
    raise SystemExit(f"documentation check failed: {message}")
def read(rel):
    path = root / rel
    if not path.is_file():
        fail(f"missing required path: {rel}")
    return path.read_text(encoding="utf-8")
def exact(pattern, text, label):
    match = re.search(pattern, text, re.MULTILINE)
    if not match:
        fail(f"{label} is missing or does not match source")
    return match.group(1)

required = [
    "LICENSE", "README.md", "project.yml", "scripts/release-version.env",
    "MacTalk.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
    "docs/STATUS.md", "docs/development/ARCHITECTURE.md",
    "docs/development/SETUP.md", "docs/development/adr/ADR-001-timestamp-aligned-audio-composition.md",
    "docs/development/adr/ADR-002-settings-and-state-ownership.md",
    "docs/development/adr/ADR-003-privacy-logging.md",
    "docs/development/adr/ADR-004-dependency-pinning.md",
    "docs/development/adr/ADR-005-signing-policy.md",
    "docs/testing/TESTING.md", "docs/testing/TEST_LANES.md", "scripts/test-lanes.sh",
    "scripts/coverage.sh", "scripts/tsan-smoke.sh", "MacTalk/MacTalk/Audio/ASREngine.swift",
    "MacTalk/MacTalk/Utilities/AppSettings.swift",
]
for item in required:
    read(item)

project = read("project.yml")
platform = exact(r"^    macOS:\s*\"([^\"]+)\"", project, "deployment target")
swift = exact(r'^  SWIFT_VERSION:\s*"([^"]+)"', project, "Swift version")
fluid = exact(r'^    exactVersion:\s*([^\s]+)', project, "FluidAudio exact version")
if platform != "26.0": fail(f"project deployment target is {platform}, expected 26.0")
if swift != "6.0": fail(f"project Swift version is {swift}, expected 6.0")
if fluid != "0.15.5": fail(f"project FluidAudio pin is {fluid}, expected 0.15.5")

release = read("scripts/release-version.env")
version = exact(r'^MACTALK_MARKETING_VERSION=([^\s]+)', release, "release marketing version")
build = exact(r'^MACTALK_BUILD_NUMBER=([^\s]+)', release, "release build number")
if not re.fullmatch(r"\d+\.\d+\.\d+", version): fail(f"invalid release version {version}")
if not build.isdigit(): fail(f"invalid build number {build}")

resolved = json.loads(read("MacTalk.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"))
pins = resolved.get("pins", [])
fluid_pin = next((p for p in pins if p.get("identity") == "fluidaudio"), None)
if not fluid_pin: fail("Package.resolved has no FluidAudio pin")
state = fluid_pin.get("state", {})
if state.get("version") != fluid: fail("Package.resolved version disagrees with project.yml")
expected_revision = "19600a485baa4998812e4654b70d2bab8f2c9949"
if state.get("revision") != expected_revision: fail("Package.resolved revision disagrees with verified pin")

status = read("docs/STATUS.md")
marker = re.search(r"STATUS-DATA-BEGIN\s*\n(.*?)\nSTATUS-DATA-END", status, re.S)
if not marker: fail("STATUS machine-readable block is missing")
try:
    data = json.loads(marker.group(1))
except json.JSONDecodeError as exc:
    fail(f"STATUS machine-readable block is invalid JSON: {exc}")
for key, value in {
    "date": "2026-07-18", "release_version": version, "build_number": build,
    "deployment_target": platform, "swift_version": swift,
    "xcodegen_version": "2.44.1", "fluidaudio_version": fluid,
}.items():
    if data.get(key) != value:
        fail(f"STATUS {key} does not match source ({data.get(key)!r} != {value!r})")
for section, command in {
    "unit_tests": "scripts/test-lanes.sh unit",
    "coverage": "scripts/coverage.sh",
    "build": "./build.sh build",
    "tsan": "scripts/test-lanes.sh tsan",
}.items():
    if data.get(section, {}).get("command") != command:
        fail(f"STATUS {section}.command is not the exact documented command")
if data.get("coverage", {}).get("artifact") != "build/coverage/MacTalk.xcresult":
    fail("STATUS coverage artifact is not the current coverage artifact")
if data.get("tsan", {}).get("result") != "blocked":
    fail("STATUS must record the standalone TSan runtime blocker")
if not data.get("hardware_tcc", {}).get("reason") or not data.get("release", {}).get("blockers"):
    fail("STATUS must record manual TCC and release blockers")

readme = read("README.md")
if not re.search(r"\[[^\]]*License[^\]]*\]\(\.?/?LICENSE\)", readme, re.I):
    fail("README does not link the root LICENSE")
if not re.search(r"after an? (?:model|artifact) is (?:explicitly )?provisioned,? transcription runs locally", readme, re.I):
    fail("README does not qualify local inference as post-provisioning")
if not re.search(r"model (?:downloaders|provisioning).*network", readme, re.I):
    fail("README does not disclose the network requirement for model provisioning")
unsupported_readme = (
    r"completely offline|zero network calls|no telemetry or network calls|"
    r"Parakeet[^\n]*(?:streaming|instant|ultra-fast)|"
    r"(?:streaming|instant|ultra-fast)[^\n]*Parakeet"
)
if re.search(unsupported_readme, readme, re.I):
    fail("README contains an unsupported offline or Parakeet performance/streaming claim")
if re.search(r"100%\s+(local|local processing)|macOS 14\.0|Xcode 15", readme, re.I):
    fail("README contains a stale platform/privacy claim")
for rel in ("docs/development/ARCHITECTURE.md", "docs/development/SETUP.md", "docs/testing/TESTING.md"):
    text = read(rel)
    if re.search(r"macOS 14\.0|Xcode 15\.0|RingBufferTests|WhisperEngineTests|85\.2%|100% coverage", text, re.I):
        fail(f"{rel} contains a historical API/version/coverage claim")

docs_hub = read("docs/README.md")
for filename in ("development/SETUP.md", "development/ARCHITECTURE.md", "STATUS.md"):
    if not re.search(rf"\([^)]*{re.escape(filename)}\)", docs_hub):
        fail(f"docs/README.md does not link current {filename}")
if "scripts/coverage.sh" not in docs_hub:
    fail("docs/README.md does not link the current coverage command")
for filename in ("XCODE_BUILD.md", "PROGRESS.md", "TEST_COVERAGE.md"):
    lines = [line for line in docs_hub.splitlines() if filename in line]
    if not lines:
        fail(f"docs/README.md does not link historical {filename}")
    if any(not re.search(r"historical", line.split(filename, 1)[0], re.I) for line in lines):
        fail(f"docs/README.md presents historical {filename} as current")

# Check only current entry-point docs for stale root-level links; historical
# stories/plans are deliberately excluded from this rule.
for rel in ("README.md", "docs/STATUS.md", "docs/development/ARCHITECTURE.md", "docs/development/SETUP.md", "docs/testing/TESTING.md"):
    text = read(rel)
    if re.search(r"docs/(ARCHITECTURE|TESTING|ROADMAP|PROGRESS)\.md", text):
        fail(f"{rel} contains a stale root-level documentation path")
print("blocking documentation checks passed")
PY
