#!/bin/bash
#
# MacTalk Build Script
# Builds and optionally launches the MacTalk app
#
# Usage:
#   ./build.sh              # Build only
#   ./build.sh run          # Build and launch
#   ./build.sh clean        # Clean build
#   ./build.sh reset-perms  # Reset TCC permissions (after rebuild)
#

set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"

source "$PROJECT_DIR/scripts/build_helpers.sh"
# Keep local builds on the same authoritative release metadata as archives.
# shellcheck disable=SC1091
source "$PROJECT_DIR/scripts/release-version.env"

CONFIGURATION="Release"
SCHEME="MacTalk"
ARCH="arm64"
# Release builds require a signing identity with a private key. Override these
# for another team/identity without editing the script.
CODE_SIGN_IDENTITY="${MACTALK_CODE_SIGN_IDENTITY:-Developer ID Application: Benedict Evert (9SXL4GJ4TZ)}"
DEVELOPMENT_TEAM="${MACTALK_DEVELOPMENT_TEAM:-9SXL4GJ4TZ}"

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${BLUE}🔨 MacTalk Build Script${NC}"
echo ""

# Handle command
case "${1:-build}" in
  clean)
    echo -e "${YELLOW}🧹 Cleaning build artifacts...${NC}"
    rm -rf ~/Library/Developer/Xcode/DerivedData/MacTalk-*
    echo -e "${GREEN}✅ Clean complete${NC}"
    exit 0
    ;;

  reset-perms)
    echo -e "${BLUE}🔐 Resetting TCC Accessibility permission for MacTalk...${NC}"
    echo -e "${YELLOW}Note: This is needed after rebuilding because TCC tracks permissions by CDHash.${NC}"
    tccutil reset Accessibility com.mactalk.app
    echo -e "${GREEN}✅ Permission reset. Re-grant Accessibility permission on next auto-paste.${NC}"
    exit 0
    ;;

  build|run)
    echo -e "${BLUE}📦 Building MacTalk (${CONFIGURATION})...${NC}"
    BUILD_LOG="$(mktemp "${TMPDIR:-/tmp}/mactalk-build.XXXXXX")"
    set +e
    xcodebuild -project MacTalk.xcodeproj \
      -scheme "$SCHEME" \
      -configuration "$CONFIGURATION" \
      -arch "$ARCH" \
      ONLY_ACTIVE_ARCH=YES \
      CODE_SIGN_STYLE=Manual \
      CODE_SIGN_IDENTITY="$CODE_SIGN_IDENTITY" \
      DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
      MARKETING_VERSION="$MACTALK_MARKETING_VERSION" \
      CURRENT_PROJECT_VERSION="$MACTALK_BUILD_NUMBER" \
      build 2>&1 | tee "$BUILD_LOG"
    BUILD_STATUS=${PIPESTATUS[0]}
    set -e

    if [ $BUILD_STATUS -ne 0 ]; then
      echo -e "${YELLOW}❌ Build failed; log: ${BUILD_LOG}${NC}" >&2
    fi

    if [ $BUILD_STATUS -eq 0 ]; then
      echo -e "${GREEN}✅ Build succeeded${NC}"

      if ! APP_PATH="$(resolve_latest_mactalk_app_path "$HOME/Library/Developer/Xcode/DerivedData" "$CONFIGURATION")"; then
        echo -e "${YELLOW}❌ Could not find a built MacTalk.app in DerivedData${NC}"
        exit 1
      fi
      echo -e "${BLUE}📍 App location: ${APP_PATH}${NC}"

      if [ "$1" = "run" ]; then
        echo -e "${BLUE}🚀 Launching MacTalk...${NC}"
        # Kill existing instance
        killall MacTalk 2>/dev/null || true
        sleep 1
        # Launch new instance
        launch_mactalk_app "$APP_PATH"
        sleep 2

        # Check if running
        if ps aux | grep -v grep | grep MacTalk > /dev/null; then
          echo -e "${GREEN}✅ MacTalk is running${NC}"
        else
          echo -e "${YELLOW}⚠️  MacTalk may not have launched${NC}"
        fi
      fi
    else
      echo -e "${YELLOW}❌ Build failed${NC}"
      exit 1
    fi
    ;;

  *)
    echo "Usage: $0 {build|run|clean|reset-perms}"
    echo ""
    echo "Commands:"
    echo "  build        Build the app (default)"
    echo "  run          Build and launch the app"
    echo "  clean        Remove build artifacts"
    echo "  reset-perms  Reset TCC Accessibility permission (use after rebuild if auto-paste stops working)"
    exit 1
    ;;
esac
