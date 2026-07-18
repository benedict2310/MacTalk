#!/usr/bin/env bash
# Blocking, dependency-free static checks for CI configuration and shell glue.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

find scripts -type f -name '*.sh' -print0 | while IFS= read -r -d '' script; do
    bash -n "$script"
done
# The semantic test is the authoritative YAML parser check; this command also
# makes the check visible in the lint lane.
bash scripts/tests/test_ci_workflow_semantics.sh

if grep -RInE --include='*.swift' '(password|api[_-]?key|secret)[[:space:]]*=[[:space:]]*"' MacTalk/MacTalk; then
    echo 'Potential hard-coded secret found in production Swift source' >&2
    exit 1
fi

echo 'blocking shell/static/security checks passed'
