#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/../.."

python3 - <<'PY'
import plistlib
from pathlib import Path
project = Path('project.yml').read_text()
entitlements_path = Path('MacTalk/MacTalk/MacTalk.entitlements')
entitlements = plistlib.load(entitlements_path.open('rb'))

required_project_refs = [
    'CODE_SIGN_ENTITLEMENTS: MacTalk/MacTalk/MacTalk.entitlements',
    '--preserve-metadata=entitlements',
]
missing_project = [item for item in required_project_refs if item not in project]
if missing_project:
    raise SystemExit('missing signing config: ' + ', '.join(missing_project))

expected_entitlements = {
    'com.apple.security.device.audio-input': True,
    'com.apple.security.automation.apple-events': True,
}
if entitlements != expected_entitlements:
    raise SystemExit(f'unexpected release entitlements: {entitlements!r}')

print('release signing inputs test passed')
PY
