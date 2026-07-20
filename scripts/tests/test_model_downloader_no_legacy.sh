#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SOURCE="$ROOT/MacTalk/MacTalk/Whisper/ModelDownloader.swift"
for forbidden in 'WhisperDownloadDelegate' 'URLSessionDownloadTask' 'download(for:' 'downloadTask(' 'resumeData' 'ResumableDownloadTaskFactory' 'DownloadTaskFactory' 'taskFactory' 'ResumeEnvelope'; do
    if grep -Fq "$forbidden" "$SOURCE"; then
        echo "legacy ModelDownloader API remains: $forbidden" >&2
        exit 1
    fi
done
if grep -Fq 'URLSession' "$SOURCE"; then
    echo 'ModelDownloader must not own URLSession transport' >&2
    exit 1
fi
echo 'ModelDownloader legacy API regression passed'
