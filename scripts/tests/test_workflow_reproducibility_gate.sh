#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/tests.yml"

python3 - "$WORKFLOW" <<'PY'
from pathlib import Path
import sys

workflow = Path(sys.argv[1]).read_text()
required = "run: bash scripts/tests/test_reproducible_project_generation.sh"
if workflow.count(required) != 1:
    raise SystemExit(f"expected exactly one reproducibility gate, found {workflow.count(required)}")

gate = workflow.index(required)
if "rm -rf MacTalk.xcodeproj" in workflow:
    raise SystemExit("CI must not delete the tracked project before regeneration")
generate = workflow.index("xcodegen generate")
if gate > generate:
    raise SystemExit("reproducibility gate must run before project regeneration")

print("workflow reproducibility gate is present before regeneration")
PY
