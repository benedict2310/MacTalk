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

def code_without_comments_or_strings(text: str) -> str:
    output = []
    index = 0
    block_depth = 0
    line_comment = False
    while index < len(text):
        if line_comment:
            if text[index] == "\n":
                line_comment = False
                output.append("\n")
            index += 1
            continue
        if block_depth:
            if text.startswith("/*", index):
                block_depth += 1
                index += 2
            elif text.startswith("*/", index):
                block_depth -= 1
                index += 2
            else:
                index += 1
            continue
        if text.startswith("//", index):
            line_comment = True
            index += 2
            continue
        if text.startswith("/*", index):
            block_depth = 1
            index += 2
            continue

        raw_hashes = 0
        quote_index = index
        if text[index] == "#":
            while quote_index < len(text) and text[quote_index] == "#":
                raw_hashes += 1
                quote_index += 1
        if quote_index < len(text) and text[quote_index] == '"':
            quote_count = 3 if text.startswith('"""', quote_index) else 1
            delimiter = ('"' * quote_count) + ('#' * raw_hashes)
            index = quote_index + quote_count
            while index < len(text):
                if raw_hashes == 0 and text[index] == "\\":
                    index += 2
                    continue
                if text.startswith(delimiter, index):
                    index += len(delimiter)
                    break
                index += 1
            output.append('""')
            continue

        output.append(text[index])
        index += 1
    return "".join(output)

source = Path(sys.argv[1])
for path in source.rglob("*.swift"):
    code = code_without_comments_or_strings(path.read_text(encoding="utf-8"))
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
