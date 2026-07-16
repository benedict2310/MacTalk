#!/bin/bash
# Generate a signed, reproducible MacTalk.xcarchive.
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
# Source provenance is checked before importing or consuming any Apple secret.
phase='preflight'
release_preflight >/dev/null
require_release_env MACTALK_CODE_SIGN_IDENTITY MACTALK_DEVELOPMENT_TEAM
require_release_command xcodebuild
mkdir -p "$OUTPUT_DIR"
on_error() {
    local status=$?
    echo "archive failed during $phase (artifacts retained in $OUTPUT_DIR); rerun archive-release.sh after correcting the external error" >&2
    exit "$status"
}
trap on_error ERR

# Always build from fresh native inputs. Reusing a pre-existing build can
# silently package libraries from a different whisper.cpp checkout. This
# workflow never downloads a transcription model.
WHISPER_ROOT="$ROOT_DIR/Vendor/whisper.cpp"
WHISPER_LIB="$WHISPER_ROOT/build/src/libwhisper.1.dylib"
phase='whisper.cpp build'
require_release_command cmake
rm -rf "$WHISPER_ROOT/build"
mkdir -p "$WHISPER_ROOT/build"
(
    cd "$WHISPER_ROOT/build"
    cmake .. -DCMAKE_BUILD_TYPE=Release -DGGML_METAL=ON
    cmake --build . --config Release -j "$(sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN)"
)
[[ -f "$WHISPER_LIB" ]] || { echo "whisper.cpp did not produce $WHISPER_LIB" >&2; exit 1; }

ARCHIVE_PATH="$OUTPUT_DIR/MacTalk.xcarchive"
phase='xcodebuild archive'
# Keep the archive path and all version inputs deterministic. xcodegen is a
# separate workflow phase and must precede this script.
xcodebuild archive \
    -project "$ROOT_DIR/MacTalk.xcodeproj" \
    -scheme MacTalk \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE_PATH" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$MACTALK_CODE_SIGN_IDENTITY" \
    DEVELOPMENT_TEAM="$MACTALK_DEVELOPMENT_TEAM" \
    MARKETING_VERSION="$MACTALK_MARKETING_VERSION" \
    CURRENT_PROJECT_VERSION="$MACTALK_BUILD_NUMBER" \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=YES

APP_PATH="$ARCHIVE_PATH/Products/Applications/MacTalk.app"
[[ -d "$APP_PATH" ]] || { echo "archive did not contain MacTalk.app: $APP_PATH" >&2; exit 1; }
release_write_metadata "$OUTPUT_DIR" archive "$ARCHIVE_PATH" "$APP_PATH"
printf '%s\n' "$APP_PATH" > "$(release_state "$OUTPUT_DIR" archive)"
printf 'archive=%s\nversion=%s\nbuild=%s\n' "$ARCHIVE_PATH" "$MACTALK_MARKETING_VERSION" "$MACTALK_BUILD_NUMBER" > "$(release_state "$OUTPUT_DIR" archive-metadata)"
echo "archive complete: $ARCHIVE_PATH"
