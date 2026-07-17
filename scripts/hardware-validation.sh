#!/bin/bash
# Opt-in signed hardware validation launcher.
# This script never downloads a model and never reports a hardware pass.
set -euo pipefail

if [[ "${MACTALK_HARDWARE_VALIDATION_ACK:-}" != "I_HAVE_AUTHORIZED_CAPTURE" ]]; then
  echo "Refusing to start capture validation without explicit authorization." >&2
  echo "Set MACTALK_HARDWARE_VALIDATION_ACK=I_HAVE_AUTHORIZED_CAPTURE after reviewing docs/testing/HARDWARE_AUDIO_VALIDATION.md." >&2
  exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
LOG_PATH="${MACTALK_AUDIO_HARDWARE_VALIDATION_LOG:-$ROOT/build/hardware-validation/audio.csv}"
mkdir -p "$(dirname "$LOG_PATH")"

# build.sh's Release path is signed and fails closed if no identity is present.
./build.sh build
APP_PATH="$(find "$HOME/Library/Developer/Xcode/DerivedData" -path '*/Build/Products/Release/MacTalk.app' -print | head -n 1)"
if [[ -z "$APP_PATH" ]]; then
  echo "No signed Release MacTalk.app found." >&2
  exit 1
fi
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
IDENTITY="$(codesign -dv --verbose=4 "$APP_PATH" 2>&1 | sed -n 's/^Authority=//p' | head -n 1)"
if [[ -z "$IDENTITY" || "$IDENTITY" == "-" ]]; then
  echo "Validation requires a signed app with a real identity; found: ${IDENTITY:-none}" >&2
  exit 1
fi

echo "Launching signed app with capture metadata logging: $LOG_PATH"
echo "Start a mic+app recording manually, exercise app-audio loss, then stop MacTalk."
echo "No validation result is inferred by this harness."
MACTALK_AUDIO_HARDWARE_VALIDATION_LOG="$LOG_PATH" \
  "$APP_PATH/Contents/MacOS/MacTalk"
