#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/../.."

bin_dir="$(mktemp -d)"
trap 'rm -rf "$bin_dir"' EXIT

swiftc \
  MacTalk/MacTalk/Audio/ASREngine.swift \
  MacTalk/MacTalk/Utilities/RecordingStartGate.swift \
  scripts/tests/parakeet_start_gate_tests.swift \
  -o "$bin_dir/parakeet-start-gate-tests"

"$bin_dir/parakeet-start-gate-tests"
