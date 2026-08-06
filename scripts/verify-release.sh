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
# Re-check source and the tamper-evident handoff before using signing tools.
release_verify_source_identity "$OUTPUT_DIR" archive
release_verify_state "$OUTPUT_DIR" archive
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

release_verify_artifact_digests "$OUTPUT_DIR" "$ARCHIVE_PATH" "$APP_PATH"
release_require_timestamp "$APP_PATH"
while IFS= read -r library; do
    release_require_timestamp "$library"
done < <(find "$APP_PATH/Contents/Frameworks" -type f -name '*.dylib' -print)

release_verify_bundle_identity "$APP_PATH"
release_write_metadata "$OUTPUT_DIR" verified "$ARCHIVE_PATH" "$APP_PATH"
release_write_state "$OUTPUT_DIR" verified "$APP_PATH"
release_create_handoff "$OUTPUT_DIR"
echo "archive verification complete"
