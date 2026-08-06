#!/bin/bash
# Hermetic coverage for the publish remote-tag binding. No GitHub API or
# release mutation is performed; git ls-remote is a deterministic fake.
set -euo pipefail
cd "$(dirname "$0")/../.."
fixture="$(mktemp -d "${TMPDIR:-/tmp}/mactalk-tag-test.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/bin"
cat > "$fixture/bin/git" <<'TOOL'
#!/bin/bash
if [[ "${1:-}" == ls-remote ]]; then
    case "${FAKE_TAG_MODE:-annotated}" in
        annotated) printf '%s\trefs/tags/v1.1.4\n%s\trefs/tags/v1.1.4^{}\n' "$FAKE_TAG_OBJECT" "$FAKE_COMMIT" ;;
        lightweight) printf '%s\trefs/tags/v1.1.4\n' "$FAKE_COMMIT" ;;
        wrong) printf '%040d\trefs/tags/v1.1.4\n' 1 ;;
    esac
    exit 0
fi
echo "unexpected fake git call: $*" >&2
exit 1
TOOL
chmod +x "$fixture/bin/git"
export PATH="$fixture/bin:$PATH"
export RELEASE_TAG=v1.1.4
export FAKE_COMMIT=0123456789012345678901234567890123456789
export FAKE_TAG_OBJECT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
source scripts/release-common.sh
for mode in annotated lightweight; do
    export FAKE_TAG_MODE="$mode"
    test "$(release_verify_remote_tag "$RELEASE_TAG" "$FAKE_COMMIT")" = "$FAKE_COMMIT"
done
export FAKE_TAG_MODE=wrong
if release_verify_remote_tag "$RELEASE_TAG" "$FAKE_COMMIT" >/dev/null 2>&1; then
    echo 'remote tag verifier accepted a mismatched direct ref' >&2
    exit 1
fi
# Keep the publish job statically tied to the tested verifier and both ref
# forms; this prevents a future inline shortcut from bypassing the helper.
python3 - <<'PY'
from pathlib import Path
workflow = Path('.github/workflows/release.yml').read_text()
assert 'release_verify_remote_tag "$RELEASE_TAG" "$RELEASE_EXPECTED_COMMIT"' in workflow
assert 'peeled_ref="${direct_ref}^{}"' in Path('scripts/release-common.sh').read_text()
print('publish remote-tag fixture passed')
PY
