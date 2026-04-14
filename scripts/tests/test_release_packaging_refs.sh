#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/../.."

python3 - <<'PY'
from pathlib import Path
text = Path('project.yml').read_text()
required = [
    'libwhisper.1.dylib',
    'libggml.dylib',
    'libggml-base.dylib',
    'libggml-cpu.dylib',
    'libggml-blas.dylib',
    'libggml-metal.dylib',
]
missing = [name for name in required if name not in text]
if missing:
    raise SystemExit(f"missing release packaging refs: {', '.join(missing)}")
print('release packaging refs test passed')
PY
