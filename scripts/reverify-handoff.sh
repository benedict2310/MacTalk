#!/bin/bash
# Reverify an authenticated release handoff on a consumer runner. This phase
# is deliberately public-input-only: it never imports a certificate, reads a
# private signing identity, or runs Gatekeeper before notarization.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/release-common.sh"
HANDOFF_PATH=''
HANDOFF_SHA256_PATH=''
RECEIVED_DIR=''
PHASE='verified'
while [[ $# -gt 0 ]]; do
    case "$1" in
        --handoff) [[ $# -ge 2 ]] || { echo '--handoff requires a path' >&2; exit 64; }; HANDOFF_PATH="$2"; shift 2 ;;
        --handoff-sha256|--sidecar) [[ $# -ge 2 ]] || { echo "$1 requires a path" >&2; exit 64; }; HANDOFF_SHA256_PATH="$2"; shift 2 ;;
        --received-dir) [[ $# -ge 2 ]] || { echo '--received-dir requires a path' >&2; exit 64; }; RECEIVED_DIR="$2"; shift 2 ;;
        --phase) [[ $# -ge 2 ]] || { echo '--phase requires a value' >&2; exit 64; }; PHASE="$2"; shift 2 ;;
        --team-id) [[ $# -ge 2 ]] || { echo '--team-id requires a value' >&2; exit 64; }; MACTALK_DEVELOPMENT_TEAM="$2"; export MACTALK_DEVELOPMENT_TEAM; shift 2 ;;
        *) echo "usage: $0 --handoff ZIP --handoff-sha256 SIDECAR --received-dir DIR [--phase verified] [--team-id TEAM]" >&2; exit 64 ;;
    esac
done
[[ -n "$HANDOFF_PATH" && -n "$HANDOFF_SHA256_PATH" && -n "$RECEIVED_DIR" ]] || {
    echo 'handoff, sidecar, and received directory are required' >&2; exit 64;
}
[[ "$PHASE" == verified ]] || { echo 'only phase=verified is accepted by the handoff consumer' >&2; exit 64; }
release_verify_verified_handoff "$HANDOFF_PATH" "$HANDOFF_SHA256_PATH" "$RECEIVED_DIR" "$PHASE"
echo "verified handoff received in $RECEIVED_DIR"
