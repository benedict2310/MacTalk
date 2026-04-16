#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/../.."

bin_dir="$(mktemp -d)"
trap 'rm -rf "$bin_dir"' EXIT

swiftc \
  MacTalk/MacTalk/Utilities/PermissionFlowGate.swift \
  scripts/tests/permission_flow_gate_tests.swift \
  -o "$bin_dir/permission-flow-gate-tests"

"$bin_dir/permission-flow-gate-tests"
