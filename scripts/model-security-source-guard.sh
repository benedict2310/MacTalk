#!/usr/bin/env bash
# Fail closed when production model delivery/loading leaves the reviewed trust boundary.
set -euo pipefail
ROOT="${MACTALK_SOURCE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
SOURCE="$ROOT/MacTalk/MacTalk"
BOOTSTRAP="$SOURCE/Whisper/ParakeetBootstrap.swift"
WHISPER_DOWNLOADER="$SOURCE/Whisper/ModelDownloader.swift"
PARAKEET_DOWNLOADER="$SOURCE/Whisper/ParakeetModelDownloader.swift"

for path in "$BOOTSTRAP" "$WHISPER_DOWNLOADER" "$PARAKEET_DOWNLOADER"; do
    [[ -f "$path" ]] || { echo "model-security source guard missing $path" >&2; exit 1; }
done

python3 - "$SOURCE" <<'PY'
from pathlib import Path
import re
import sys

def without_block_comments(text: str) -> str:
    # Preserve strings, regex literals, line comments, and interpolation so the
    # guard fails closed if a forbidden API is mentioned there. Remove only
    # nested block comments, which Swift permits between lexical tokens.
    output = []
    index = 0
    depth = 0
    while index < len(text):
        if text.startswith("/*", index):
            depth += 1
            index += 2
            continue
        if depth and text.startswith("*/", index):
            depth -= 1
            index += 2
            continue
        if depth == 0:
            output.append(text[index])
        index += 1
    return "".join(output)

source = Path(sys.argv[1])
for path in source.rglob("*.swift"):
    code = without_block_comments(path.read_text(encoding="utf-8"))
    normalized = re.sub(r"\s+", "", code)
    for forbidden in (
        "AsrModels.load(from:",
        "ModelHub.loadModels",
        "MLModel(contentsOf:",
        "MLModelAsset(url:",
    ):
        if forbidden in normalized:
            raise SystemExit(f"{path}: production source contains forbidden path-based model loading: {forbidden}")
PY

if grep -REin --include='*.swift' \
    '(inactive|future|dormant|pending activation|deferred|reserved for later|disabled).*(source|loader|Parakeet)|(source|loader|Parakeet).*(inactive|future|dormant|pending activation|deferred|reserved for later|disabled)|not referenced by active composition' \
    "$SOURCE/Whisper"; then
    echo 'production source contains retired inactive/future model-loading documentation' >&2
    exit 1
fi

while IFS= read -r source; do
    if grep -Fn 'URLSession' "$source"; then
        echo "$source must not introduce transport outside BoundedModelDownloadTransport" >&2
        exit 1
    fi
done < <(find "$SOURCE" -type f -name '*.swift' ! -path "$SOURCE/Whisper/BoundedModelDownloadTransport.swift" -print)

for requirement in \
    'BoundedParakeetSourceArtifactMaterializer(' \
    'BoundedModelDownloadTransport()' \
    'GeneratedModelProvenance.parakeetSource' \
    'VerifiedParakeetSourceSnapshotProvider(store: store)' \
    'VerifiedParakeetModelLoader().load(snapshot: snapshot, policy: .production)' \
    'ParakeetLegacyCompiledCleaner(parent: parent)' \
    'try await cleaner.removeCompiledGeneration()'; do
    grep -Fq "$requirement" "$BOOTSTRAP" || {
        echo "Parakeet bootstrap is missing reviewed source boundary: $requirement" >&2
        exit 1
    }
done

for downloader in "$WHISPER_DOWNLOADER" "$PARAKEET_DOWNLOADER"; do
    grep -Fq 'BoundedModelDownloadTransport()' "$downloader" || {
        echo "$downloader is missing the bounded production transport" >&2
        exit 1
    }
    if grep -Fq 'URLSession' "$downloader"; then
        echo "$downloader must not own URLSession transport" >&2
        exit 1
    fi
done

echo 'model-security production source guard passed'
