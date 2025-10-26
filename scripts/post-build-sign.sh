#!/bin/bash
#
# Post-build script to re-sign all whisper.cpp dylibs and the app bundle
# This fixes the Team ID mismatch issue on macOS 26
#
# Usage: Called automatically by Xcode after build
#

set -e

echo "🔐 [Post-Build] Starting code signing..."

# Get paths from Xcode environment variables
APP_PATH="${BUILT_PRODUCTS_DIR}/${PRODUCT_NAME}.app"
FRAMEWORKS_PATH="${APP_PATH}/Contents/Frameworks"

# Check if Frameworks directory exists
if [ ! -d "$FRAMEWORKS_PATH" ]; then
    echo "⚠️  [Post-Build] Frameworks directory not found at: $FRAMEWORKS_PATH"
    exit 0
fi

# Re-sign all dylibs
echo "🔐 [Post-Build] Re-signing dylibs in Frameworks..."
cd "$FRAMEWORKS_PATH"
for lib in *.dylib; do
    if [ -f "$lib" ]; then
        echo "   → Signing: $lib"
        codesign --force --sign - "$lib" 2>&1 | grep -v "replacing existing signature" || true
    fi
done

# Re-sign the app bundle
echo "🔐 [Post-Build] Re-signing app bundle..."
cd - > /dev/null
codesign --force --deep --sign - "$APP_PATH" 2>&1 | grep -v "replacing existing signature" || true

echo "✅ [Post-Build] Code signing complete!"
