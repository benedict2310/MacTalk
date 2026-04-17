#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/../.."

python3 - <<'PY'
from pathlib import Path
project = Path('project.yml').read_text()
entitlements_path = Path('MacTalk/MacTalk/MacTalk.entitlements')
entitlements = entitlements_path.read_text()

required_project_refs = [
    'CODE_SIGN_ENTITLEMENTS: MacTalk/MacTalk/MacTalk.entitlements',
    '--preserve-metadata=entitlements',
]
missing_project = [item for item in required_project_refs if item not in project]
if missing_project:
    raise SystemExit('missing signing config: ' + ', '.join(missing_project))

required_entitlements = [
    'com.apple.security.device.audio-input',
    'com.apple.security.automation.apple-events',
    'com.apple.security.cs.disable-library-validation',
    'com.apple.security.cs.allow-jit',
    'com.apple.security.cs.allow-unsigned-executable-memory',
]
missing_entitlements = [item for item in required_entitlements if item not in entitlements]
if missing_entitlements:
    raise SystemExit('missing entitlements: ' + ', '.join(missing_entitlements))

print('release signing inputs test passed')
PY
