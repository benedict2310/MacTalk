#!/bin/bash
# Secret-free release source gate. This is intentionally a separate phase so
# CI can prove the source before importing a certificate or reading a notary
# credential.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/release-common.sh"
release_preflight
