#!/bin/bash
# Package, notarize, staple, Gatekeeper-check, and checksum a release DMG.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/release-common.sh"
OUTPUT_DIR="$ROOT_DIR/release"
HANDOFF_PATH=''
HANDOFF_SHA256_PATH=''
while [[ $# -gt 0 ]]; do
    case "$1" in
        --output-dir) [[ $# -ge 2 ]] || { echo '--output-dir requires a path' >&2; exit 64; }; OUTPUT_DIR="$2"; shift 2 ;;
        --handoff) [[ $# -ge 2 ]] || { echo '--handoff requires a path' >&2; exit 64; }; HANDOFF_PATH="$2"; shift 2 ;;
        --handoff-sha256|--sidecar) [[ $# -ge 2 ]] || { echo "$1 requires a path" >&2; exit 64; }; HANDOFF_SHA256_PATH="$2"; shift 2 ;;
        *) echo "usage: $0 [--output-dir PATH] [--handoff ZIP --handoff-sha256 SIDECAR]" >&2; exit 64 ;;
    esac
done
if [[ -n "$HANDOFF_PATH" || -n "$HANDOFF_SHA256_PATH" ]]; then
    [[ -n "$HANDOFF_PATH" && -n "$HANDOFF_SHA256_PATH" ]] || { echo '--handoff and --handoff-sha256 must be supplied together' >&2; exit 64; }
    # The original producer container is retained by the workflow and passed
    # here explicitly. Reverify without a private identity before credentials
    # are read; this also prevents a stale received directory being trusted.
    release_verify_handoff "$HANDOFF_PATH" "$HANDOFF_SHA256_PATH"
    release_verify_verified_handoff_output "$OUTPUT_DIR" verified
else
    # Backwards-compatible local invocation for a producer checkout. Consumer
    # jobs must use --handoff so they do not depend on producer state markers.
    release_verify_source_identity "$OUTPUT_DIR" verified
    release_verify_state "$OUTPUT_DIR" verified
    release_verify_handoff "$OUTPUT_DIR/MacTalk-release-handoff.zip" "$OUTPUT_DIR/MacTalk-release-handoff.zip.sha256"
fi
# No Apple credential is read until the detached/tagged source and verified
# provenance handoff have passed.
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
release_verify_bundle_identity "$APP_PATH"

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
release_verify_metadata "$OUTPUT_DIR" notarized
release_verify_artifact_digests "$OUTPUT_DIR" "$ARCHIVE_PATH" "$APP_PATH" "$DMG_PATH"
release_write_state "$OUTPUT_DIR" notarized "$DMG_PATH"

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
release_write_metadata "$OUTPUT_DIR" complete "$ARCHIVE_PATH" "$APP_PATH" "$DMG_PATH"
release_verify_metadata "$OUTPUT_DIR" complete
release_verify_artifact_digests "$OUTPUT_DIR" "$ARCHIVE_PATH" "$APP_PATH" "$DMG_PATH"
release_write_state "$OUTPUT_DIR" complete "$MANIFEST_PATH"
# Publish receives one metadata-bearing ditto archive, never a directory tree.
release_create_publish_handoff() {
    local output_dir="$1" archive hash stage item source
    archive="$output_dir/MacTalk-publish-handoff.zip"
    hash="$archive.sha256"
    require_release_command ditto
    rm -f "$archive" "$hash"
    stage="$(mktemp -d "${TMPDIR:-/tmp}/mactalk-publish.XXXXXX")"
    trap 'rm -rf "$stage"' RETURN
    for source in "$output_dir"/MacTalk.xcarchive "$output_dir"/MacTalk-*.dmg "$output_dir"/MacTalk-*-manifest.txt "$output_dir"/release-provenance.env "$output_dir"/release-provenance.env.sha256 "$output_dir"/.release-state-complete; do
        [[ -e "$source" ]] || { echo "publish handoff input is missing: $source" >&2; return 65; }
        item="${source##*/}"
        ditto "$source" "$stage/$item"
    done
    ditto -c -k --sequesterRsrc "$stage/." "$archive"
    printf '%s  %s\n' "$(release_sha256 "$archive")" "$(basename "$archive")" > "$hash"
}
release_create_publish_handoff "$OUTPUT_DIR"
echo "release complete: $DMG_PATH"
echo "manifest: $MANIFEST_PATH"
