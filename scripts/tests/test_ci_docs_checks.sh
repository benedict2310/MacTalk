#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK="$ROOT/scripts/ci-docs-checks.sh"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/mactalk-docs-fixture.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT

# Keep the fixture hermetic and test the checker through its supported root
# override rather than mutating the working checkout.
tar -C "$ROOT" --exclude=.git --exclude=build -cf - . | tar -C "$fixture" -xf -
MACTALK_DOCS_ROOT="$fixture" "$CHECK" >/dev/null

# The dated STATUS baseline is historical evidence. Release-candidate metadata
# must not rewrite the version/build associated with its recorded test counts.
if ! grep -Fq '"release_version":"1.1.3","build_number":"4"' "$fixture/docs/STATUS.md"; then
    echo "STATUS historical baseline was rewritten with current release metadata" >&2
    exit 1
fi

# Operators must see every immutable reserved tag before starting preflight.
for reserved_tag in v1.1.3 v1.1.4; do
    if [[ $(grep -Fc "$reserved_tag" "$fixture/docs/deployment/RELEASE_WORKFLOW.md") -lt 2 ]]; then
        echo "release runbook does not name reserved tag $reserved_tag in policy and command guidance" >&2
        exit 1
    fi
done

# Repeating a reserved tag in policy must not compensate for omitting it from
# the operator command guidance.
python3 - "$fixture/docs/deployment/RELEASE_WORKFLOW.md" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
text = text.replace(
    "`v1.1.3` and `v1.1.4` are permanently reserved",
    "`v1.1.3` and `v1.1.4` (including `v1.1.4`) are permanently reserved",
    1,
)
text = text.replace(
    "# Use a newly created immutable tag; never reuse reserved v1.1.3 or v1.1.4.",
    "# Use a newly created immutable tag; never reuse reserved v1.1.3.",
    1,
)
path.write_text(text)
PY
if MACTALK_DOCS_ROOT="$fixture" "$CHECK" >/dev/null 2>&1; then
    echo "docs checker accepted reserved tags only in policy, not command guidance" >&2
    exit 1
fi
cp "$ROOT/docs/deployment/RELEASE_WORKFLOW.md" "$fixture/docs/deployment/RELEASE_WORKFLOW.md"

# Current-source prose is separate from the historical baseline and must track
# release-version.env independently.
python3 - "$fixture/docs/STATUS.md" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text().replace(
    "is marketing version `1.1.5`, build `6`.",
    "is marketing version `1.1.4`, build `5`.",
    1,
)
path.write_text(text)
PY
if MACTALK_DOCS_ROOT="$fixture" "$CHECK" >/dev/null 2>&1; then
    echo "docs checker accepted stale current-source release metadata" >&2
    exit 1
fi
cp "$ROOT/docs/STATUS.md" "$fixture/docs/STATUS.md"

# The current provenance document must describe the active verified-source
# loader. Reintroducing the retired inactive/future-loader claim must fail.
printf '\nThe Parakeet source loader is inactive and reserved for a future loader.\n' >> "$fixture/docs/security/MODEL_PROVENANCE.md"
if MACTALK_DOCS_ROOT="$fixture" "$CHECK" >/dev/null 2>&1; then
    echo "docs checker accepted retired Parakeet loader documentation" >&2
    exit 1
fi
cp "$ROOT/docs/security/MODEL_PROVENANCE.md" "$fixture/docs/security/MODEL_PROVENANCE.md"

rm "$fixture/LICENSE"
if MACTALK_DOCS_ROOT="$fixture" "$CHECK" >/dev/null 2>&1; then
    echo "docs checker accepted a missing LICENSE" >&2
    exit 1
fi
cp "$ROOT/LICENSE" "$fixture/LICENSE"

# Lifecycle work requires a durable workflow contract rather than relying on
# an agent transcript or a broad historical plan.
rm -f "$fixture/docs/development/AGENT_WORKFLOW.md"
if MACTALK_DOCS_ROOT="$fixture" "$CHECK" >/dev/null 2>&1; then
    echo "docs checker accepted a missing agent workflow contract" >&2
    exit 1
fi
cp "$ROOT/docs/development/AGENT_WORKFLOW.md" "$fixture/docs/development/AGENT_WORKFLOW.md"

# A source/config mismatch must fail even when STATUS still contains the old
# value; this guards against a verifier that only searches for text.
sed -i.bak 's/macOS: "26.0"/macOS: "14.0"/' "$fixture/project.yml"
rm -f "$fixture/project.yml.bak"
if MACTALK_DOCS_ROOT="$fixture" "$CHECK" >/dev/null 2>&1; then
    echo "docs checker accepted a deployment-target mismatch" >&2
    exit 1
fi
cp "$ROOT/project.yml" "$fixture/project.yml"

# Unsupported README claims must remain rejected even if the rest of the
# repository is internally consistent.
printf '\n- Parakeet provides ultra-fast real-time streaming\n' >> "$fixture/README.md"
if MACTALK_DOCS_ROOT="$fixture" "$CHECK" >/dev/null 2>&1; then
    echo "docs checker accepted an unsupported Parakeet streaming claim" >&2
    exit 1
fi
cp "$ROOT/README.md" "$fixture/README.md"
sed -i.bak 's/Once a model is downloaded and verified, the transcription path can run without a network connection\./MacTalk works completely offline./' "$fixture/README.md"
rm -f "$fixture/README.md.bak"
if MACTALK_DOCS_ROOT="$fixture" "$CHECK" >/dev/null 2>&1; then
    echo "docs checker accepted an unqualified offline claim" >&2
    exit 1
fi
cp "$ROOT/README.md" "$fixture/README.md"

# Historical documents must not be presented as current guidance by the hub.
sed -i.bak 's/- Historical: \*\*\[PROGRESS.md\](planning\/PROGRESS.md)\*\* - Historical development status and progress tracking/- **[PROGRESS.md](planning\/PROGRESS.md)** - Current status/' "$fixture/docs/README.md"
rm -f "$fixture/docs/README.md.bak"
if MACTALK_DOCS_ROOT="$fixture" "$CHECK" >/dev/null 2>&1; then
    echo "docs checker accepted a current PROGRESS label" >&2
    exit 1
fi
cp "$ROOT/docs/README.md" "$fixture/docs/README.md"
sed -i.bak 's/Historical: \[XCODE_BUILD.md\]/[XCODE_BUILD.md]/' "$fixture/docs/README.md"
rm -f "$fixture/docs/README.md.bak"
if MACTALK_DOCS_ROOT="$fixture" "$CHECK" >/dev/null 2>&1; then
    echo "docs checker accepted a current XCODE_BUILD label" >&2
    exit 1
fi
cp "$ROOT/docs/README.md" "$fixture/docs/README.md"
sed -i.bak 's/Historical: \*\*\[TEST_COVERAGE.md\]/[TEST_COVERAGE.md]/' "$fixture/docs/README.md"
rm -f "$fixture/docs/README.md.bak"
if MACTALK_DOCS_ROOT="$fixture" "$CHECK" >/dev/null 2>&1; then
    echo "docs checker accepted a current TEST_COVERAGE label" >&2
    exit 1
fi

observability_contracts=(
    '~/Library/Logs/MacTalk/pipeline-metrics.jsonl'
    'Copy Performance Report'
    'no transcript text, audio samples, target application identity, or raw errors'
    'monotonic'
    'real-time factor'
    'com.mactalk.app'
    'pipeline'
    'bounded asynchronous hardware validation'
    'hosted Thread Sanitizer'
    'no flaky absolute hosted performance threshold'
)
for contract in "${observability_contracts[@]}"; do
    cp "$ROOT/docs/troubleshooting/PROFILING.md" "$fixture/docs/troubleshooting/PROFILING.md"
    cp "$ROOT/docs/development/ARCHITECTURE.md" "$fixture/docs/development/ARCHITECTURE.md"
    cp "$ROOT/docs/testing/TESTING.md" "$fixture/docs/testing/TESTING.md"
    cp "$ROOT/docs/testing/CI.md" "$fixture/docs/testing/CI.md"
    python3 - "$fixture" "$contract" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
contract = sys.argv[2]
paths = [
    root / "docs/troubleshooting/PROFILING.md",
    root / "docs/development/ARCHITECTURE.md",
    root / "docs/testing/TESTING.md",
    root / "docs/testing/CI.md",
]
for path in paths:
    text = path.read_text()
    if contract in text:
        path.write_text(text.replace(contract, "", 1))
        break
else:
    raise SystemExit(f"fixture contract was not present: {contract}")
PY
    if MACTALK_DOCS_ROOT="$fixture" "$CHECK" >/dev/null 2>&1; then
        echo "docs checker accepted missing observability contract: $contract" >&2
        exit 1
    fi
done

echo "ci-docs-checks negative fixtures passed"
