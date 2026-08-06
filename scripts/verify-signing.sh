#!/bin/bash
# Verify a MacTalk app bundle for Developer ID distribution signing.
#
# Exit status:
#   0  signature, runtime, entitlements, and Gatekeeper checks passed
#   2  signing credentials are unavailable (the bundle is signed, but the
#      requested identity is not present in the keychain)
#   3  unsigned or invalid signature/policy
#   4  signature is valid but Gatekeeper rejected it as Unnotarized Developer ID
#  64  usage or missing input
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${1:-}"
if [[ -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
    echo "usage: $0 /path/to/MacTalk.app" >&2
    exit 64
fi
if [[ "$(basename "$APP_PATH")" != *.app ]]; then
    echo "not an app bundle: $APP_PATH" >&2
    exit 64
fi

SIGNING_IDENTITY="${SIGNING_IDENTITY:-${MACTALK_CODE_SIGN_IDENTITY:-}}"
EXPECTED_TEAM="${SIGNING_TEAM_ID:-${MACTALK_DEVELOPMENT_TEAM:-}}"

fail_signature() {
    echo "❌ signing verification failed: $*" >&2
    exit 3
}

# codesign writes display information to stderr. A missing TeamIdentifier is a
# useful, deterministic unsigned-bundle check before querying credentials.
details_for() {
    local path="$1"
    if ! codesign -dvvv "$path" 2>&1; then
        echo "codesign metadata query failed for $path" >&2
    fi
}
APP_DETAILS="$(details_for "$APP_PATH")"
if ! grep -q '^TeamIdentifier=' <<< "$APP_DETAILS" || grep -qiE 'not signed|code object is not signed' <<< "$APP_DETAILS"; then
    fail_signature "bundle is unsigned"
fi

# Consumer reverification intentionally has no private-key/keychain identity.
# The producer path retains the stronger identity-installed check.
if [[ "${VERIFY_SIGNING_OFFLINE:-0}" == 1 ]]; then
    [[ -n "$EXPECTED_TEAM" ]] || fail_signature "expected Team ID is unavailable for offline verification"
else
    IDENTITIES_OUTPUT=""
    if ! IDENTITIES_OUTPUT="$(security find-identity -v -p codesigning 2>&1)"; then
        echo "⚠️  signing credentials unavailable: security could not inspect the keychain" >&2
        exit 2
    fi
    if [[ -z "$SIGNING_IDENTITY" ]]; then
        SIGNING_IDENTITY="$(sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' <<< "$IDENTITIES_OUTPUT" | head -1)"
    fi
    if [[ -z "$SIGNING_IDENTITY" || "$SIGNING_IDENTITY" == "-" ]]; then
        echo "⚠️  signing credentials unavailable: no Developer ID Application identity" >&2
        exit 2
    fi
    if ! grep -Fq "\"$SIGNING_IDENTITY\"" <<< "$IDENTITIES_OUTPUT"; then
        echo "⚠️  signing credentials unavailable: identity is not installed: $SIGNING_IDENTITY" >&2
        exit 2
    fi
    if [[ -z "$EXPECTED_TEAM" ]]; then
        EXPECTED_TEAM="$(sed -n 's/.*(\([^()]\+\))[^()]*$/\1/p' <<< "$SIGNING_IDENTITY" | tail -1)"
    fi
    [[ -n "$EXPECTED_TEAM" ]] || fail_signature "expected Team ID is unavailable"
fi

APP_TEAM="$(sed -n 's/^TeamIdentifier=//p' <<< "$APP_DETAILS" | head -1)"
[[ "$APP_TEAM" == "$EXPECTED_TEAM" ]] || fail_signature "app Team ID $APP_TEAM does not match expected $EXPECTED_TEAM"
if ! grep -Fq "Authority=Developer ID Application:" <<< "$APP_DETAILS"; then
    fail_signature "bundle is not signed with a Developer ID Application certificate"
fi
if [[ "${VERIFY_SIGNING_OFFLINE:-0}" != 1 ]] && ! grep -Fq "Authority=$SIGNING_IDENTITY" <<< "$APP_DETAILS"; then
    fail_signature "bundle identity does not match $SIGNING_IDENTITY"
fi
if ! grep -qE 'flags=.*runtime' <<< "$APP_DETAILS"; then
    fail_signature "hardened runtime flag is missing"
fi

# Strict verification is deliberately separate from --deep display checks so
# a failure in either the app or a nested code object is visible.
if ! codesign --verify --deep --strict --verbose=2 "$APP_PATH"; then
    fail_signature "codesign --verify --deep --strict rejected the app"
fi

frameworks="$APP_PATH/Contents/Frameworks"
found_nested=false
if [[ -d "$frameworks" ]]; then
    while IFS= read -r -d '' nested; do
        found_nested=true
        nested_details="$(details_for "$nested")"
        if ! grep -q '^TeamIdentifier=' <<< "$nested_details" || grep -qiE 'not signed|code object is not signed' <<< "$nested_details"; then
            fail_signature "nested code is unsigned: $nested"
        fi
        nested_team="$(sed -n 's/^TeamIdentifier=//p' <<< "$nested_details" | head -1)"
        [[ "$nested_team" == "$EXPECTED_TEAM" ]] || fail_signature "nested Team ID $nested_team does not match $EXPECTED_TEAM: $nested"
        grep -Fq "Authority=Developer ID Application:" <<< "$nested_details" || fail_signature "nested code is not Developer ID signed: $nested"
        grep -qE 'flags=.*runtime' <<< "$nested_details" || fail_signature "nested hardened runtime flag is missing: $nested"
        codesign --verify --strict --verbose=2 "$nested" || fail_signature "strict verification rejected nested code: $nested"
    done < <(find "$frameworks" -type f -name '*.dylib' -print0)
fi
[[ "$found_nested" == true ]] || fail_signature "no nested dylibs found in Contents/Frameworks"

entitlements_file="$(mktemp "${TMPDIR:-/tmp}/mactalk-entitlements.XXXXXX")"
trap 'rm -f "$entitlements_file"' EXIT
if ! codesign -d --entitlements :- "$APP_PATH" >"$entitlements_file" 2>&1; then
    fail_signature "could not read app entitlements"
fi
python3 - "$entitlements_file" "$ROOT_DIR/MacTalk/MacTalk/MacTalk.entitlements" <<'PY' || fail_signature "entitlements do not match the release policy"
import plistlib
import sys

actual_text = open(sys.argv[1], encoding='utf-8').read()
start = actual_text.find('<?xml')
if start < 0:
    start = actual_text.find('<plist')
if start < 0:
    raise SystemExit('codesign did not return a plist')
actual = plistlib.loads(actual_text[start:].encode())
source = plistlib.load(open(sys.argv[2], 'rb'))
approved = {
    'com.apple.security.device.audio-input': True,
    'com.apple.security.automation.apple-events': True,
}
if source != approved:
    raise SystemExit(f'source entitlements are not the exact approved allowlist: {source!r}')
if actual != approved:
    raise SystemExit(f'signed entitlements are not the exact approved allowlist: {actual!r}')
PY

if [[ "${VERIFY_SIGNING_SKIP_GATEKEEPER:-0}" == 1 ]]; then
    echo "⏭️  Gatekeeper assessment deferred until notarization and stapling"
elif spctl_output="$(spctl --assess --type execute --verbose=4 "$APP_PATH" 2>&1)"; then
    :
elif grep -qi 'Unnotarized Developer ID' <<< "$spctl_output"; then
    echo "⚠️  Gatekeeper rejected this valid Developer ID app as Unnotarized Developer ID; notarize and staple it before distribution." >&2
    exit 4
else
    fail_signature "Gatekeeper rejected the signed app: $spctl_output"
fi

echo "✅ signing verified: Developer ID, Team ID $EXPECTED_TEAM, hardened runtime, nested dylibs, entitlements, strict codesign"
