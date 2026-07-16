#!/bin/bash
# Verify the signed archive before it can be packaged or notarized.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/release-common.sh"
OUTPUT_DIR="$ROOT_DIR/release"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --output-dir) [[ $# -ge 2 ]] || { echo '--output-dir requires a path' >&2; exit 64; }; OUTPUT_DIR="$2"; shift 2 ;;
        *) echo "usage: $0 [--output-dir PATH]" >&2; exit 64 ;;
    esac
done
require_release_env MACTALK_CODE_SIGN_IDENTITY MACTALK_DEVELOPMENT_TEAM
require_release_command codesign security spctl python3
ARCHIVE_PATH="$OUTPUT_DIR/MacTalk.xcarchive"
APP_PATH="$ARCHIVE_PATH/Products/Applications/MacTalk.app"
[[ -f "$(release_state "$OUTPUT_DIR" archive)" && -d "$APP_PATH" ]] || {
    echo "archive phase has not completed; run archive-release.sh first" >&2
    exit 1
}
phase='archive verification'
on_error() {
    local status=$?
    echo "verification failed during $phase (archive retained in $OUTPUT_DIR); correct the signing/version issue and rerun verify-release.sh" >&2
    exit "$status"
}
trap on_error ERR

# The existing verifier remains authoritative for nested libraries, hardened
# runtime, entitlements, and strict codesign. Gatekeeper is intentionally held
# until after notarization/stapling, when the final artifact is assessed.
VERIFY_SIGNING_SKIP_GATEKEEPER=1 \
SIGNING_IDENTITY="$MACTALK_CODE_SIGN_IDENTITY" \
SIGNING_TEAM_ID="$MACTALK_DEVELOPMENT_TEAM" \
    "$ROOT_DIR/scripts/verify-signing.sh" "$APP_PATH"

python3 - "$APP_PATH/Contents/Info.plist" "$MACTALK_MARKETING_VERSION" "$MACTALK_BUILD_NUMBER" <<'PY'
import plistlib
import sys
plist = plistlib.load(open(sys.argv[1], 'rb'))
if plist.get('CFBundleShortVersionString') != sys.argv[2]:
    raise SystemExit('archive marketing version does not match release-version.env')
if plist.get('CFBundleVersion') != sys.argv[3]:
    raise SystemExit('archive build number does not match release-version.env')
PY
printf '%s\n' "$APP_PATH" > "$(release_state "$OUTPUT_DIR" verified)"
echo "archive verification complete"
