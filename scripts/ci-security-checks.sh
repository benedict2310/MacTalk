#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Fail closed for likely credentials in tracked production/config files. Test
# fixtures may contain intentionally fake values but production Swift may not.
if grep -RInE --exclude-dir=.git --exclude-dir=build --include='*.swift' --include='*.yml' --include='*.yaml' --include='*.sh' \
    '(password|api[_-]?key|secret)[[:space:]]*=[[:space:]]*"' MacTalk .github scripts; then
    echo 'Potential hard-coded credential assignment found' >&2
    exit 1
fi

# Provider/model downloads must remain behind explicit lane seams, not in CI.
if grep -RInE --include='*.yml' --include='*.yaml' 'MACTALK_EXISTING_MODEL_PATH|MACTALK_HARDWARE_VALIDATION_ACK' .github/workflows | grep -v 'test-lanes.sh'; then
    echo 'CI workflow references opt-in model/hardware state outside the lane entry point' >&2
    exit 1
fi

python3 scripts/generate-model-provenance.py --check
bash scripts/tests/test_model_provenance_generation.sh
bash scripts/tests/test_model_downloader_no_legacy.sh

echo 'blocking security checks passed'
