#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GUARD="$ROOT/scripts/model-security-source-guard.sh"

"$GUARD"

fixture="$(mktemp -d "${TMPDIR:-/tmp}/mactalk-model-source-guard.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/MacTalk/MacTalk"
cp -R "$ROOT/MacTalk/MacTalk/Whisper" "$fixture/MacTalk/MacTalk/Whisper"

printf '\n// AsrModels.load(from: legacyURL)\n' >> "$fixture/MacTalk/MacTalk/Whisper/ParakeetBootstrap.swift"
if MACTALK_SOURCE_ROOT="$fixture" "$GUARD" >/dev/null 2>&1; then
    echo 'model-security source guard accepted path-based Parakeet loading' >&2
    exit 1
fi
cp "$ROOT/MacTalk/MacTalk/Whisper/ParakeetBootstrap.swift" "$fixture/MacTalk/MacTalk/Whisper/ParakeetBootstrap.swift"

for stale_claim in \
    'The source loader is inactive and reserved for a future loader.' \
    'The Parakeet source loader remains inactive.'; do
    printf '\n// %s\n' "$stale_claim" >> "$fixture/MacTalk/MacTalk/Whisper/ParakeetBootstrap.swift"
    if MACTALK_SOURCE_ROOT="$fixture" "$GUARD" >/dev/null 2>&1; then
        echo "model-security source guard accepted retired claim: $stale_claim" >&2
        exit 1
    fi
    cp "$ROOT/MacTalk/MacTalk/Whisper/ParakeetBootstrap.swift" "$fixture/MacTalk/MacTalk/Whisper/ParakeetBootstrap.swift"
done

for session_expression in 'URLSession(configuration: .ephemeral)' 'Foundation.URLSession.shared'; do
    cat > "$fixture/MacTalk/MacTalk/Whisper/AlternateModelTransport.swift" <<SWIFT
import Foundation
let alternateSession = $session_expression
SWIFT
    if MACTALK_SOURCE_ROOT="$fixture" "$GUARD" >/dev/null 2>&1; then
        echo "model-security source guard accepted $session_expression outside bounded transport" >&2
        exit 1
    fi
    rm "$fixture/MacTalk/MacTalk/Whisper/AlternateModelTransport.swift"
done

python3 - "$fixture/MacTalk/MacTalk/Whisper/ParakeetBootstrap.swift" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
path.write_text(text.replace("VerifiedParakeetModelLoader()", "UnverifiedParakeetModelLoader()", 1))
PY
if MACTALK_SOURCE_ROOT="$fixture" "$GUARD" >/dev/null 2>&1; then
    echo 'model-security source guard accepted removal of verified byte loading' >&2
    exit 1
fi
cp "$ROOT/MacTalk/MacTalk/Whisper/ParakeetBootstrap.swift" "$fixture/MacTalk/MacTalk/Whisper/ParakeetBootstrap.swift"

for requirement in \
    'VerifiedParakeetSourceSnapshotProvider(store: store)' \
    'GeneratedModelProvenance.parakeetSource' \
    'ParakeetLegacyCompiledCleaner(parent: parent)' \
    'try await cleaner.removeCompiledGeneration()'; do
    python3 - "$fixture/MacTalk/MacTalk/Whisper/ParakeetBootstrap.swift" "$requirement" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
requirement = sys.argv[2]
path.write_text(text.replace(requirement, "REMOVED_REVIEWED_BOUNDARY", 1))
PY
    if MACTALK_SOURCE_ROOT="$fixture" "$GUARD" >/dev/null 2>&1; then
        echo "model-security source guard accepted removal of: $requirement" >&2
        exit 1
    fi
    cp "$ROOT/MacTalk/MacTalk/Whisper/ParakeetBootstrap.swift" "$fixture/MacTalk/MacTalk/Whisper/ParakeetBootstrap.swift"
done

python3 - "$fixture/MacTalk/MacTalk/Whisper/ModelDownloader.swift" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
path.write_text(text.replace("BoundedModelDownloadTransport()", "UnboundedModelDownloadTransport()", 1))
PY
if MACTALK_SOURCE_ROOT="$fixture" "$GUARD" >/dev/null 2>&1; then
    echo 'model-security source guard accepted removal of bounded Whisper transport' >&2
    exit 1
fi
cp "$ROOT/MacTalk/MacTalk/Whisper/ModelDownloader.swift" "$fixture/MacTalk/MacTalk/Whisper/ModelDownloader.swift"

python3 - "$fixture/MacTalk/MacTalk/Whisper/ParakeetModelDownloader.swift" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
path.write_text(text.replace("BoundedModelDownloadTransport()", "UnboundedModelDownloadTransport()", 1))
PY
if MACTALK_SOURCE_ROOT="$fixture" "$GUARD" >/dev/null 2>&1; then
    echo 'model-security source guard accepted removal of bounded Parakeet transport' >&2
    exit 1
fi

echo 'model-security source guard negative fixtures passed'
