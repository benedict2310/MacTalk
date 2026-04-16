#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/../.."

python3 - <<'PY'
from pathlib import Path
import re

app_delegate = Path('MacTalk/MacTalk/AppDelegate.swift').read_text()
status_bar = Path('MacTalk/MacTalk/StatusBarController.swift').read_text()
permissions = Path('MacTalk/MacTalk/Permissions.swift').read_text()
notifications = Path('MacTalk/MacTalk/Utilities/NotificationNames.swift').read_text()

assert 'Permissions.ensureMic' not in app_delegate, 'AppDelegate should not request microphone permission on launch'

match = re.search(r'@objc private func checkPermissions\(\) \{(.*?)\n    \}', status_bar, re.S)
assert match, 'could not find checkPermissions body'
check_permissions_body = match.group(1)
assert 'Permissions.ensureMic' not in check_permissions_body, 'checkPermissions should not prompt for microphone permission'
assert 'Permissions.checkScreenRecordingPermission() ? "✅ Granted" : "❌ Denied"' in check_permissions_body, 'checkPermissions should show actual screen recording state'

get_status_match = re.search(r'static func getPermissionStatus\(completion:.*?\{(.*?)\n    \}', permissions, re.S)
assert get_status_match, 'could not find getPermissionStatus body'
assert 'ensureMic' not in get_status_match.group(1), 'Permissions.getPermissionStatus should not prompt for microphone permission'

assert 'permissionsDidChange' in notifications, 'permissionsDidChange notification should be defined centrally'
print('permission usage tests passed')
PY
