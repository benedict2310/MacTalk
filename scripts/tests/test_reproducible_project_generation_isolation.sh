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

# Regression: every tracked shared scheme must be compared. Inject a drift into
# the non-TSan scheme after generation and require the verifier to reject it.
REAL_XCODEGEN="$(command -v xcodegen)"
FAKE_BIN="$(mktemp -d "${TMPDIR:-/tmp}/mactalk-xcodegen.XXXXXX")"
trap 'rm -rf "$FAKE_BIN"; if [ -d "$FIXTURE" ]; then git -C "$ROOT" worktree remove --force "$FIXTURE" >/dev/null 2>&1 || rm -rf "$FIXTURE"; fi' EXIT
cat > "$FAKE_BIN/xcodegen" <<EOF
#!/bin/bash
set -euo pipefail
"$REAL_XCODEGEN" "\$@"
printf '\\n# intentional MacTalk scheme drift\\n' >> MacTalk.xcodeproj/xcshareddata/xcschemes/MacTalk.xcscheme
EOF
chmod +x "$FAKE_BIN/xcodegen"
if (cd "$ROOT" && PATH="$FAKE_BIN:$PATH" bash scripts/tests/test_reproducible_project_generation.sh >/dev/null 2>&1); then
  echo "verifier failed to detect MacTalk.xcscheme drift" >&2
  exit 1
fi

echo "reproducible project generation isolation and scheme drift detection verified"
