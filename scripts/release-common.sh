#!/bin/bash
# Shared, non-secret release inputs and deterministic artifact helpers.
set -euo pipefail

RELEASE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE_VERSION_FILE="${MACTALK_VERSION_FILE:-$RELEASE_ROOT/scripts/release-version.env}"
if [[ ! -f "$RELEASE_VERSION_FILE" ]]; then
    echo "release version file is missing: $RELEASE_VERSION_FILE" >&2
    exit 64
fi
# This file is source-controlled version metadata only; credentials are never
# read from it. Validate values after loading so malformed releases fail early.
# shellcheck disable=SC1090
source "$RELEASE_VERSION_FILE"
: "${MACTALK_MARKETING_VERSION:?MACTALK_MARKETING_VERSION is missing from $RELEASE_VERSION_FILE}"
: "${MACTALK_BUILD_NUMBER:?MACTALK_BUILD_NUMBER is missing from $RELEASE_VERSION_FILE}"
if [[ ! "$MACTALK_MARKETING_VERSION" =~ ^[0-9]+(\.[0-9]+){1,3}$ ]]; then
    echo "invalid marketing version in $RELEASE_VERSION_FILE" >&2
    exit 64
fi
if [[ ! "$MACTALK_BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
    echo "invalid build number in $RELEASE_VERSION_FILE" >&2
    exit 64
fi

require_release_env() {
    local name
    for name in "$@"; do
        if [[ -z "${!name:-}" ]]; then
            echo "required release environment is missing: $name" >&2
            return 64
        fi
    done
}

require_release_command() {
    local command_name
    for command_name in "$@"; do
        command -v "$command_name" >/dev/null 2>&1 || {
            echo "required release tool is missing: $command_name" >&2
            return 69
        }
    done
}

release_commit() {
    git -C "$RELEASE_ROOT" rev-parse --verify HEAD
}

release_sha256() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        sha256sum "$1" | awk '{print $1}'
    fi
}

release_state() {
    printf '%s/.release-state-%s\n' "$1" "$2"
}
