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
echo "STATUSBAR SOURCE GUARD PASSED"
