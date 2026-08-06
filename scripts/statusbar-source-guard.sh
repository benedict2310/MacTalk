#!/bin/bash
# Coordinator source guard: production globals belong in StatusBarSystemClients
# or the AppKit composition root, never in extracted business coordinators.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COORDINATOR_DIR="$ROOT/MacTalk/MacTalk/StatusBar"
forbidden=(
  'AppSettings.shared'
  'Permissions\.'
  'ModelManager.shared'
  'ParakeetBootstrap.shared'
  'ClipboardManager'
  'AutoInsertManager'
  'NSWorkspace.shared'
  'SCShareableContent'
)
files=("$COORDINATOR_DIR"/*Coordinator.swift)
for pattern in "${forbidden[@]}"; do
  if grep -nE "$pattern" "${files[@]}"; then
    echo "STATUSBAR SOURCE GUARD FAILED: $pattern is used by a coordinator" >&2
    exit 1
  fi
done
CONTROLLER="$ROOT/MacTalk/MacTalk/StatusBarController.swift"
line_count=$(wc -l < "$CONTROLLER" | tr -d ' ')
if [ "$line_count" -gt 350 ]; then
  echo "STATUSBAR SOURCE GUARD FAILED: controller is $line_count lines (maximum 350)" >&2
  exit 1
fi
for legacy in 'isRecording' 'isStartInFlight' 'startGeneration' 'pendingSettingsLatch' 'transcriber' 'parakeetEngine' 'progressItem'; do
  if grep -n "$legacy" "$CONTROLLER"; then
    echo "STATUSBAR SOURCE GUARD FAILED: legacy controller state $legacy remains" >&2
    exit 1
  fi
done
echo "STATUSBAR SOURCE GUARD PASSED"
