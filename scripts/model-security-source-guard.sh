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

if grep -RFn --include='*.swift' -e 'AsrModels.load(from:' -e 'ModelHub.loadModels' \
    -e 'MLModel(contentsOf:' -e 'MLModelAsset(url:' "$SOURCE"; then
    echo 'production source contains forbidden path-based model loading' >&2
    exit 1
fi

if grep -REin --include='*.swift' \
    'inactive (in-memory|loader|Parakeet source|source generation)|future (Parakeet source-store|source artifact|source loader)|future loader|not referenced by active composition' \
    "$SOURCE/Whisper"; then
    echo 'production source contains retired inactive/future model-loading documentation' >&2
    exit 1
fi

while IFS= read -r source; do
    if grep -En 'URLSession\(|URLSession(Configuration|DataTask|DownloadTask|DataDelegate|TaskDelegate)' "$source"; then
        echo "$source must not introduce transport outside BoundedModelDownloadTransport" >&2
        exit 1
    fi
done < <(find "$SOURCE/Whisper" -type f -name '*.swift' ! -name 'BoundedModelDownloadTransport.swift' -print)

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
