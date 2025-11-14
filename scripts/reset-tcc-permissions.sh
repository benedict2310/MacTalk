#!/bin/bash
# Reset TCC (Transparency, Consent, and Control) permissions for MacTalk
# Use this during development when rebuilding with different code signatures

set -e

BUNDLE_ID="com.mactalk.app"
APP_NAME="MacTalk"

echo "🔐 TCC Permission Reset Utility for ${APP_NAME}"
echo "=========================================="
echo ""

# Function to check if app is running
check_if_running() {
    if pgrep -x "${APP_NAME}" > /dev/null; then
        echo "⚠️  ${APP_NAME} is currently running"
        echo "   Killing all instances..."
        killall "${APP_NAME}" 2>/dev/null || true
        sleep 2
        echo "   ✅ Stopped ${APP_NAME}"
    fi
}

# Function to reset a specific TCC service
reset_tcc_service() {
    local service=$1
    local service_name=$2

    echo "🔄 Resetting ${service_name} permission..."

    # Try to reset using tccutil
    if tccutil reset "${service}" "${BUNDLE_ID}" 2>/dev/null; then
        echo "   ✅ ${service_name} permission reset"
    else
        echo "   ⚠️  Could not reset ${service_name} (may require sudo or not previously granted)"
    fi
}

# Main script
echo "This script will reset TCC permissions for ${APP_NAME}."
echo "You will need to re-grant permissions after the next app launch."
echo ""

# Check if app is running and stop it
check_if_running

echo ""
echo "Resetting permissions..."
echo ""

# Reset Screen Recording permission
reset_tcc_service "ScreenCapture" "Screen Recording"

# Reset Accessibility permission
reset_tcc_service "Accessibility" "Accessibility"

# Reset Microphone permission
reset_tcc_service "Microphone" "Microphone"

echo ""
echo "=========================================="
echo "✅ TCC permissions reset complete!"
echo ""
echo "Next steps:"
echo "1. Rebuild and launch ${APP_NAME}"
echo "2. Grant permissions when prompted"
echo "3. The app should remember permissions between builds now"
echo ""
echo "💡 Tip: If you're still having issues, you may need to:"
echo "   - Manually remove ${APP_NAME} from System Settings > Privacy & Security"
echo "   - Re-add the DEBUG build (not the Release build) to permissions"
echo "   - Ensure code signing is using 'Apple Development' certificate"
echo ""
