#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/tests.yml"
INSTALLER="$ROOT/scripts/install_xcodegen.sh"

python3 - "$WORKFLOW" "$INSTALLER" <<'PY'
from pathlib import Path
import re
import sys

workflow = Path(sys.argv[1]).read_text()
installer = Path(sys.argv[2]).read_text()
version = "2.44.1"
checksum = "a2e905fb68446e9bb4008cdfe2e13e3f176d0cbcca828b71770f8e53fca91b73"

if "brew install xcodegen" in workflow:
    raise SystemExit("CI must not install unpinned XcodeGen through Homebrew")
if "bash scripts/install_xcodegen.sh" not in workflow:
    raise SystemExit("CI does not invoke the pinned XcodeGen installer")
if f"XCODEGEN_INSTALL_DIR=\"$RUNNER_TOOL_CACHE/xcodegen/{version}\"" not in workflow:
    raise SystemExit("CI install path is not pinned to the expected XcodeGen version")
if f'XCODEGEN_VERSION="{version}"' not in installer:
    raise SystemExit("installer version pin is missing")
if f'XCODEGEN_ARCHIVE_SHA256="{checksum}"' not in installer:
    raise SystemExit("installer checksum pin is missing")
if not re.search(r"XCODEGEN_ARCHIVE_SHA256=\"[0-9a-f]{64}\"", installer):
    raise SystemExit("installer checksum is not a lowercase SHA-256 digest")
if f"releases/download/${{XCODEGEN_VERSION}}/xcodegen.zip" not in installer:
    raise SystemExit("installer artifact URL is not the pinned release asset")
if 'actual_sha256' not in installer or 'reported_version' not in installer:
    raise SystemExit("installer does not verify both archive integrity and executable version")

print("XcodeGen exact pin and checksum configuration verified")
PY

ruby -e 'require "yaml"; YAML.load_file(ARGV.fetch(0)); puts "GitHub Actions workflow YAML parses"' "$WORKFLOW"
