#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/../.."

python3 - <<'PY'
from pathlib import Path

checks = {
    'MacTalk/MacTalk/HUDWindowController.swift': 'if #available(macOS 26.4, *) {',
    'MacTalk/MacTalk/SettingsWindowController.swift': 'if #available(macOS 26.4, *) {',
    'MacTalk/MacTalk/UI/AppPickerWindowController.swift': 'if #available(macOS 26.4, *) {',
}

for path_str, needle in checks.items():
    text = Path(path_str).read_text()
    idx = text.find(needle)
    if idx == -1:
        raise SystemExit(f'missing availability gate in {path_str}')
    after = text[idx: idx + 1200]
    if '} else {' not in after:
        raise SystemExit(f'missing macOS 26.0-26.3 fallback near availability gate in {path_str}')

print('macOS 26 fallback test passed')
PY
