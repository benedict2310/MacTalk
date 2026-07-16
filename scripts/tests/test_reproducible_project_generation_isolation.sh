#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/mactalk-generation-fixture.XXXXXX")"
cleanup() {
  if [ -d "$FIXTURE" ]; then
    git -C "$ROOT" worktree remove --force "$FIXTURE" >/dev/null 2>&1 || rm -rf "$FIXTURE"
  fi
}
trap cleanup EXIT

git -C "$ROOT" worktree add --detach "$FIXTURE" HEAD >/dev/null
# Simulate a dirty tracked generated artifact and an ignored artifact in the caller.
printf '\n# dirty caller fixture\n' >> "$FIXTURE/MacTalk.xcodeproj/project.pbxproj"
printf 'ignored fixture\n' > "$FIXTURE/generation-ignored-artifact.tmp"
git -C "$FIXTURE" check-ignore -q generation-ignored-artifact.tmp
before="$(shasum "$FIXTURE/MacTalk.xcodeproj/project.pbxproj")"

# The verifier must use its own clean copy, so it should not rewrite the dirty
# caller. It may reject the dirty checkout, but it must leave it untouched.
if ! (cd "$FIXTURE" && bash scripts/tests/test_reproducible_project_generation.sh >/dev/null); then
  : # A dirty caller is allowed to fail; mutation is not.
fi
after="$(shasum "$FIXTURE/MacTalk.xcodeproj/project.pbxproj")"
[ "$before" = "$after" ] || {
  echo "verifier mutated the dirty caller generated project" >&2
  exit 1
}
[ -f "$FIXTURE/generation-ignored-artifact.tmp" ] || {
  echo "verifier depended on or removed caller ignored artifacts" >&2
  exit 1
}

echo "reproducible project generation isolation verified"
