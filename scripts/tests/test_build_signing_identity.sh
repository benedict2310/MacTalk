#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/../.."

python3 - <<'PY'
from pathlib import Path

script = Path("build.sh").read_text()
required = [
    'MACTALK_CODE_SIGN_IDENTITY',
    'CODE_SIGN_STYLE=Manual',
    'CODE_SIGN_IDENTITY="$CODE_SIGN_IDENTITY"',
    'DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM"',
]
missing = [value for value in required if value not in script]
if missing:
    raise SystemExit("build.sh does not pass explicit signing settings: " + ", ".join(missing))

print("build signing identity test passed")
PY
