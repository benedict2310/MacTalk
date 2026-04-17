#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/../.."

python3 - <<'PY'
from pathlib import Path
import platform
import re
import sys

text = Path('project.yml').read_text()
match_option = re.search(r'deploymentTarget:\s*\n\s*macOS:\s*"([0-9.]+)"', text)
match_setting = re.search(r'MACOSX_DEPLOYMENT_TARGET:\s*"([0-9.]+)"', text)
if not match_option or not match_setting:
    raise SystemExit('missing deployment target settings in project.yml')

option_target = tuple(int(p) for p in match_option.group(1).split('.'))
setting_target = tuple(int(p) for p in match_setting.group(1).split('.'))
if option_target != setting_target:
    raise SystemExit(f'deployment target mismatch: option={match_option.group(1)} setting={match_setting.group(1)}')

os_version = tuple(int(p) for p in platform.mac_ver()[0].split('.'))
if option_target > os_version:
    raise SystemExit(
        f'deployment target {match_option.group(1)} exceeds current macOS {platform.mac_ver()[0]} '
        'and will prevent normal app-bundle launching on this machine'
    )

print(f'release launchability test passed: deployment target {match_option.group(1)} <= macOS {platform.mac_ver()[0]}')
PY
