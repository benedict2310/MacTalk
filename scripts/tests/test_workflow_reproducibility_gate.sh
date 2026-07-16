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
destructive = workflow.index("run: rm -rf MacTalk.xcodeproj")
generate = workflow.index("run: xcodegen generate")
if gate > destructive:
    raise SystemExit("reproducibility gate must run before destructive project deletion")
if gate > generate:
    raise SystemExit("reproducibility gate must run before project regeneration")

print("workflow reproducibility gate is present before deletion and regeneration")
PY
