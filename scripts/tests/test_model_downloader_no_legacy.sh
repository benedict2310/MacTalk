#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SOURCES=(
  "$ROOT/MacTalk/MacTalk/Whisper/ModelDownloader.swift"
  "$ROOT/MacTalk/MacTalk/Whisper/ParakeetModelDownloader.swift"
)
for SOURCE in "${SOURCES[@]}"; do
for forbidden in 'WhisperDownloadDelegate' 'URLSessionDownloadTask' 'download(for:' 'downloadTask(' 'resumeData' 'ResumableDownloadTaskFactory' 'DownloadTaskFactory' 'taskFactory' 'ResumeEnvelope'; do
    if grep -Fq "$forbidden" "$SOURCE"; then
        echo "legacy ModelDownloader API remains: $forbidden" >&2
        exit 1
    fi
done
if grep -Fq 'URLSession' "$SOURCE"; then
    echo "$SOURCE must not own URLSession transport" >&2
    exit 1
fi
done
echo 'ModelDownloader legacy API regression passed'
