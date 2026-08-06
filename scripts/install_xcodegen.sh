#!/usr/bin/env bash
# Install the exact XcodeGen release used by MacTalk CI.
set -euo pipefail

readonly XCODEGEN_VERSION="2.44.1"
readonly XCODEGEN_ARCHIVE_SHA256="a2e905fb68446e9bb4008cdfe2e13e3f176d0cbcca828b71770f8e53fca91b73"
readonly XCODEGEN_ARCHIVE_URL="https://github.com/yonaskolb/XcodeGen/releases/download/${XCODEGEN_VERSION}/xcodegen.zip"

install_root="${XCODEGEN_INSTALL_DIR:-${RUNNER_TOOL_CACHE:-${TMPDIR:-/tmp}}/xcodegen/${XCODEGEN_VERSION}}"
archive="$(mktemp "${TMPDIR:-/tmp}/xcodegen.XXXXXX.zip")"
staging="$(mktemp -d "${TMPDIR:-/tmp}/xcodegen.XXXXXX")"
cleanup() {
    rm -f "$archive"
    rm -rf "$staging"
}
trap cleanup EXIT

curl --fail --location --silent --show-error --retry 3 \
    "$XCODEGEN_ARCHIVE_URL" --output "$archive"
actual_sha256="$(shasum -a 256 "$archive" | awk '{print $1}')"
if [[ "$actual_sha256" != "$XCODEGEN_ARCHIVE_SHA256" ]]; then
    echo "XcodeGen archive checksum mismatch" >&2
    echo "expected: $XCODEGEN_ARCHIVE_SHA256" >&2
    echo "actual:   $actual_sha256" >&2
    exit 1
fi

unzip -q "$archive" -d "$staging"
executable="$staging/xcodegen/bin/xcodegen"
if [[ ! -x "$executable" ]]; then
    echo "XcodeGen archive did not contain xcodegen/bin/xcodegen" >&2
    exit 1
fi
reported_version="$("$executable" --version | awk 'NR == 1 {print $NF}')"
if [[ "$reported_version" != "$XCODEGEN_VERSION" ]]; then
    echo "XcodeGen version mismatch: expected $XCODEGEN_VERSION, got $reported_version" >&2
    exit 1
fi

rm -rf "$install_root"
mkdir -p "$(dirname "$install_root")"
mv "$staging/xcodegen" "$install_root"
chmod 755 "$install_root/bin/xcodegen"

printf '%s\n' "$install_root/bin"
