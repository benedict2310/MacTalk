#!/bin/bash
# Secret-free policy tests for the release gate and workflow. This test is
# intentionally static/hermetic: it never invokes Apple tools or GitHub APIs.
set -euo pipefail
cd "$(dirname "$0")/../.."
python3 - <<'PY'
from pathlib import Path
import re
common = Path('scripts/release-common.sh').read_text()
archive = Path('scripts/archive-release.sh').read_text()
notarize = Path('scripts/notarize-release.sh').read_text()
postbuild = Path('scripts/post-build-sign.sh').read_text()
workflow = Path('.github/workflows/release.yml').read_text()
fixture = Path('scripts/tests/test_release_workflow.sh').read_text()
assert '^[0-9]+\\.[0-9]+\\.[0-9]+$' in common, 'version grammar is not exact X.Y.Z'
for needle in ('release_preflight', 'persist-credentials: false', 'fetch-depth: 0', 'rm -rf "$WHISPER_ROOT/build"', '--timestamp', 'release_verify_metadata', 'ditto -c -k --sequesterRsrc', 'release_verify_handoff', 'release_write_state', 'RELEASE_EXPECTED_COMMIT'):
    assert needle in (common + archive + notarize + postbuild + workflow), f'missing hardening gate: {needle}'
assert 'v1.1.3 is immutable' in common
assert 'permissions: {}' in workflow and 'contents: write' in workflow
assert workflow.count('environment: release') >= 4, 'privileged jobs are not bound to release environment'
assert 'needs.preflight.outputs.source_commit' in workflow, 'preflight commit is not propagated'
assert 'release_verify_remote_tag "$RELEASE_TAG" "$RELEASE_EXPECTED_COMMIT"' in workflow, 'publish does not securely verify remote tag refs'
assert 'peeled_ref="${direct_ref}^{}"' in common, 'remote tag verifier lacks peeled annotated support'
assert 'received' in workflow and 'reverify-handoff.sh' in workflow, 'consumer handoff is not isolated in received'
publish_handoff_dir = '${{ runner.temp }}/mactalk-release/received'
assert f'{publish_handoff_dir}/MacTalk-publish-handoff.zip' in workflow, 'publish handoff upload does not use the received directory'
assert f'{publish_handoff_dir}/MacTalk-publish-handoff.zip.sha256' in workflow, 'publish handoff sidecar upload does not use the received directory'
assert '${{ runner.temp }}/mactalk-release/MacTalk-publish-handoff.zip' not in workflow, 'publish handoff upload regressed to the parent directory'
assert '${{ runner.temp }}/mactalk-release/MacTalk-publish-handoff.zip.sha256' not in workflow, 'publish handoff sidecar upload regressed to the parent directory'
assert re.search(r'uses: actions/checkout@[0-9a-f]{40}', workflow)
assert not re.search(r'uses: actions/(checkout|upload-artifact|download-artifact)@v[0-9]', workflow)
assert 'concurrency:' in workflow and 'gh release create' in workflow and '--draft' in workflow
assert 'gh release upload' in workflow and 'sha256:' in workflow and '--draft=false' in workflow
for needle in ('tamper', 'dirty', 'missing', 'notarytool submit', 'cmake'):
    assert needle.lower() in fixture.lower(), f'fixture lacks scenario marker: {needle}'
print('release hardening static tests passed')
PY
