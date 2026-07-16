#!/bin/bash
# Package, notarize, staple, Gatekeeper-check, and checksum a release DMG.
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
# No Apple credential is read until the detached/tagged source and verified
# provenance handoff have passed.
release_verify_source_identity "$OUTPUT_DIR"
require_release_env MACTALK_CODE_SIGN_IDENTITY MACTALK_DEVELOPMENT_TEAM
if [[ -n "${MACTALK_NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
    NOTARY_ARGS=(--keychain-profile "$MACTALK_NOTARY_KEYCHAIN_PROFILE")
elif [[ -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" ]]; then
    # Keep credentials in an argv array and never interpolate them into logs.
    NOTARY_ARGS=(--apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD")
else
    echo 'notarization credentials are missing: set MACTALK_NOTARY_KEYCHAIN_PROFILE or APPLE_ID, APPLE_TEAM_ID, and APPLE_APP_SPECIFIC_PASSWORD' >&2
    exit 64
fi
require_release_command hdiutil codesign xcrun spctl
phase='preflight'
on_error() {
    local status=$?
    echo "release failed during $phase (artifacts retained in $OUTPUT_DIR); rerun the failed phase after correcting the external error" >&2
    exit "$status"
}
trap on_error ERR
ARCHIVE_PATH="$OUTPUT_DIR/MacTalk.xcarchive"
APP_PATH="$ARCHIVE_PATH/Products/Applications/MacTalk.app"
[[ -f "$(release_state "$OUTPUT_DIR" verified)" && -d "$APP_PATH" ]] || {
    echo "archive verification has not completed; run verify-release.sh before packaging" >&2
    exit 1
}
release_verify_artifact_digests "$OUTPUT_DIR" "$ARCHIVE_PATH" "$APP_PATH"

phase='DMG creation'
DMG_PATH="$OUTPUT_DIR/MacTalk-$MACTALK_MARKETING_VERSION.dmg"
hdiutil create -volname MacTalk -srcfolder "$APP_PATH" -ov -format UDZO "$DMG_PATH"
[[ -f "$DMG_PATH" ]] || { echo 'hdiutil did not create the release DMG' >&2; exit 1; }
codesign --force --timestamp --sign "$MACTALK_CODE_SIGN_IDENTITY" "$DMG_PATH"
release_require_timestamp "$DMG_PATH"

phase='notarization submit/wait'
xcrun notarytool submit "$DMG_PATH" "${NOTARY_ARGS[@]}" --wait
phase='notarization stapling'
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"

phase='Gatekeeper assessment'
spctl --assess --type install --verbose=4 "$DMG_PATH"
spctl --assess --type execute --verbose=4 "$APP_PATH"

phase='provenance metadata'
release_write_metadata "$OUTPUT_DIR" notarized "$ARCHIVE_PATH" "$APP_PATH" "$DMG_PATH"
release_verify_metadata "$OUTPUT_DIR"
release_verify_artifact_digests "$OUTPUT_DIR" "$ARCHIVE_PATH" "$APP_PATH" "$DMG_PATH"

phase='SHA-256 manifest'
MANIFEST_PATH="$OUTPUT_DIR/MacTalk-$MACTALK_MARKETING_VERSION-manifest.txt"
DMG_SHA256="$(release_sha256 "$DMG_PATH")"
CAPTURED_COMMIT="$(awk -F= '$1 == "source_commit" { print $2 }' "$(release_metadata_path "$OUTPUT_DIR")")"
[[ -n "$CAPTURED_COMMIT" && "$DMG_SHA256" == "$(awk -F= '$1 == "dmg_sha256" { print $2 }' "$(release_metadata_path "$OUTPUT_DIR")")" ]] || {
    echo 'final DMG digest does not match provenance metadata' >&2
    exit 65
}
cat > "$MANIFEST_PATH" <<EOF_MANIFEST
artifact=MacTalk-$MACTALK_MARKETING_VERSION.dmg
version=$MACTALK_MARKETING_VERSION
build=$MACTALK_BUILD_NUMBER
commit=$CAPTURED_COMMIT
sha256=$DMG_SHA256
EOF_MANIFEST
printf '%s\n' "$MANIFEST_PATH" > "$(release_state "$OUTPUT_DIR" complete)"
echo "release complete: $DMG_PATH"
echo "manifest: $MANIFEST_PATH"
