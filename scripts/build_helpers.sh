#!/bin/bash

resolve_latest_mactalk_app_path() {
  local derived_data_root="${1:-$HOME/Library/Developer/Xcode/DerivedData}"
  local configuration="${2:-Release}"

  python3 - "$derived_data_root" "$configuration" <<'PY'
import glob
import os
import sys

root, configuration = sys.argv[1:3]
pattern = os.path.join(root, 'MacTalk-*', 'Build', 'Products', configuration, 'MacTalk.app')
paths = []
for path in glob.glob(pattern):
    binary = os.path.join(path, 'Contents', 'MacOS', 'MacTalk')
    stat_path = binary if os.path.exists(binary) else path
    try:
        mtime = os.stat(stat_path).st_mtime
    except FileNotFoundError:
        continue
    paths.append((mtime, path))

if not paths:
    sys.exit(1)

paths.sort(key=lambda item: item[0], reverse=True)
print(paths[0][1])
PY
}

launch_mactalk_app() {
  local app_path="$1"
  local log_path="${2:-/tmp/mactalk-launch.log}"

  if open -na "$app_path"; then
    return 0
  fi

  echo "open failed for app bundle: $app_path" >&2
  echo "refusing to launch the inner binary directly because that bypasses normal app-bundle behavior (icons, LaunchServices, TCC registration). See $log_path for caller logs." >&2
  return 1
}
