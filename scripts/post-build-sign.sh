#!/bin/bash
# Re-sign nested whisper.cpp dylibs and the app after Xcode has copied them.
# This script is also useful for validating the post-build signing contract in
# isolation; release signing failures must never be hidden.
set -euo pipefail

APP_PATH="${APP_PATH:?APP_PATH must point to the app bundle}"
FRAMEWORKS_PATH="$APP_PATH/Contents/Frameworks"
SIGNING_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:-}}"

if [[ "${CODE_SIGNING_ALLOWED:-YES}" != YES ]]; then
    echo "⏭️  [Post-Build] Code signing disabled by build settings"
    exit 0
fi
if [[ -z "$SIGNING_IDENTITY" || "$SIGNING_IDENTITY" == "-" ]]; then
    echo "❌ [Post-Build] No signing identity is available" >&2
    exit 1
fi
if [[ ! -d "$FRAMEWORKS_PATH" ]]; then
    echo "❌ [Post-Build] Frameworks directory not found: $FRAMEWORKS_PATH" >&2
    exit 1
fi

found_library=false
for lib in "$FRAMEWORKS_PATH"/*.dylib; do
    if [[ -f "$lib" ]]; then
        found_library=true
        echo "🔐 [Post-Build] Signing $(basename "$lib")"
        codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$lib"
    fi
done
if [[ "$found_library" != true ]]; then
    echo "❌ [Post-Build] No nested dylibs were found to sign" >&2
    exit 1
fi

echo "🔐 [Post-Build] Signing app bundle"
codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" \
    --preserve-metadata=entitlements,requirements,flags "$APP_PATH"
echo "✅ [Post-Build] Code signing complete with identity: $SIGNING_IDENTITY"
