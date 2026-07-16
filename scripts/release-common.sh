#!/bin/bash
# Shared, non-secret release inputs and deterministic artifact helpers.
set -euo pipefail

RELEASE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE_VERSION_FILE="${MACTALK_VERSION_FILE:-$RELEASE_ROOT/scripts/release-version.env}"
if [[ ! -f "$RELEASE_VERSION_FILE" ]]; then
    echo "release version file is missing: $RELEASE_VERSION_FILE" >&2
    exit 64
fi
# This file is source-controlled version metadata only; credentials are never
# read from it. Validate values after loading so malformed releases fail early.
# shellcheck disable=SC1090
source "$RELEASE_VERSION_FILE"
: "${MACTALK_MARKETING_VERSION:?MACTALK_MARKETING_VERSION is missing from $RELEASE_VERSION_FILE}"
: "${MACTALK_BUILD_NUMBER:?MACTALK_BUILD_NUMBER is missing from $RELEASE_VERSION_FILE}"
# Releases use exactly three numeric components. Do not accept a fourth
# component or prerelease/build suffixes: the tag and artifact names are the
# public version contract.
if [[ ! "$MACTALK_MARKETING_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "invalid marketing version (expected X.Y.Z) in $RELEASE_VERSION_FILE" >&2
    exit 64
fi
if [[ ! "$MACTALK_BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
    echo "invalid build number in $RELEASE_VERSION_FILE" >&2
    exit 64
fi

require_release_env() {
    local name
    for name in "$@"; do
        if [[ -z "${!name:-}" ]]; then
            echo "required release environment is missing: $name" >&2
            return 64
        fi
    done
}

require_release_command() {
    local command_name
    for command_name in "$@"; do
        command -v "$command_name" >/dev/null 2>&1 || {
            echo "required release tool is missing: $command_name" >&2
            return 69
        }
    done
}

release_commit() {
    git -C "$RELEASE_ROOT" rev-parse --verify HEAD
}

release_source_tag() {
    local tag="${RELEASE_TAG:-${GITHUB_REF_NAME:-}}"
    [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
        echo "release tag is required and must match vX.Y.Z" >&2
        return 64
    }
    printf '%s\n' "$tag"
}

# Validate the immutable source selected for a release before any signing or
# notarization secret is read. A release is always made from a detached,
# clean checkout whose HEAD is exactly the requested tag commit.
release_preflight() {
    local tag expected_commit head submodule_commit
    tag="$(release_source_tag)"
    if [[ "$tag" == v1.1.3 ]]; then
        echo "v1.1.3 is immutable; bump release-version.env and create a new tag" >&2
        return 64
    fi
    if [[ -n "$(git -C "$RELEASE_ROOT" status --porcelain --untracked-files=all)" ]]; then
        echo "release source is dirty" >&2
        return 65
    fi
    if git -C "$RELEASE_ROOT" symbolic-ref --quiet --short HEAD >/dev/null 2>&1; then
        echo "release source must be checked out detached at its tag" >&2
        return 65
    fi
    expected_commit="$(git -C "$RELEASE_ROOT" rev-parse --verify "$tag^{commit}" 2>/dev/null)" || {
        echo "release tag does not exist locally: $tag" >&2
        return 65
    }
    head="$(release_commit)"
    [[ "$head" == "$expected_commit" ]] || {
        echo "HEAD $head is not the commit for $tag ($expected_commit)" >&2
        return 65
    }
    [[ "$tag" == "v$MACTALK_MARKETING_VERSION" ]] || {
        echo "tag $tag does not match source version $MACTALK_MARKETING_VERSION" >&2
        return 64
    }
    submodule_commit="$(git -C "$RELEASE_ROOT/Vendor/whisper.cpp" rev-parse --verify HEAD 2>/dev/null)" || {
        echo 'whisper.cpp submodule is unavailable' >&2
        return 65
    }
    [[ -z "$(git -C "$RELEASE_ROOT/Vendor/whisper.cpp" status --porcelain)" ]] || {
        echo 'whisper.cpp submodule is dirty' >&2
        return 65
    }
    printf '%s\n' "$tag"
    printf 'source_commit=%s\nsubmodule_commit=%s\n' "$head" "$submodule_commit"
}

release_metadata_path() {
    printf '%s/release-provenance.env\n' "$1"
}

release_metadata_digest_path() {
    printf '%s/release-provenance.env.sha256\n' "$1"
}

release_write_metadata() {
    local output_dir="$1" phase="$2" archive_path="${3:-}" app_path="${4:-}" dmg_path="${5:-}"
    local tag commit submodule archive_sha app_sha dmg_sha timestamp
    tag="$(release_source_tag)"
    commit="$(release_commit)"
    submodule="$(git -C "$RELEASE_ROOT/Vendor/whisper.cpp" rev-parse --verify HEAD)"
    timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    archive_sha=''; app_sha=''; dmg_sha=''
    [[ -n "$archive_path" && -e "$archive_path" ]] && archive_sha="$(release_tree_sha256 "$archive_path")"
    [[ -n "$app_path" && -e "$app_path" ]] && app_sha="$(release_tree_sha256 "$app_path")"
    [[ -n "$dmg_path" && -e "$dmg_path" ]] && dmg_sha="$(release_sha256 "$dmg_path")"
    {
        printf 'phase=%s\ntimestamp_utc=%s\ntag=%s\nsource_commit=%s\nsubmodule_commit=%s\n' "$phase" "$timestamp" "$tag" "$commit" "$submodule"
        printf 'version=%s\nbuild=%s\narchive_sha256=%s\napp_sha256=%s\ndmg_sha256=%s\n' "$MACTALK_MARKETING_VERSION" "$MACTALK_BUILD_NUMBER" "$archive_sha" "$app_sha" "$dmg_sha"
        printf 'whisper_recipe=cmake:-DCMAKE_BUILD_TYPE=Release:-DGGML_METAL=ON;cmake-build:Release\n'
    } > "$(release_metadata_path "$output_dir")"
    release_sha256 "$(release_metadata_path "$output_dir")" > "$(release_metadata_digest_path "$output_dir")"
}

release_require_timestamp() {
    local signed_path="$1" details
    details="$(codesign --display --verbose=4 "$signed_path" 2>&1)" || {
        echo "unable to inspect code signature timestamp: $signed_path" >&2
        return 65
    }
    grep -Eq '(^|[[:space:]])Timestamp=' <<< "$details" || {
        echo "secure signing timestamp is missing: $signed_path" >&2
        return 65
    }
}

release_verify_source_identity() {
    # Later phases trust only the authenticated handoff produced by the
    # secret-free archive phase. The archive phase itself performs the clean,
    # detached HEAD check before any credentials are consumed.
    release_verify_metadata "$1"
}

release_verify_metadata() {
    local output_dir="$1" metadata digest expected phase
    metadata="$(release_metadata_path "$output_dir")"
    digest="$(release_metadata_digest_path "$output_dir")"
    [[ -f "$metadata" && -f "$digest" ]] || { echo 'release provenance metadata is missing' >&2; return 65; }
    expected="$(release_sha256 "$metadata")"
    [[ "$(tr -d '[:space:]' < "$digest")" == "$expected" ]] || {
        echo 'release provenance metadata digest mismatch' >&2
        return 65
    }
    phase="$(awk -F= '$1 == "phase" { print $2 }' "$metadata")"
    [[ -n "$phase" ]] || { echo 'release provenance phase is missing' >&2; return 65; }
    [[ "$(awk -F= '$1 == "tag" { print $2 }' "$metadata")" == "$(release_source_tag)" ]] || {
        echo 'release provenance tag mismatch' >&2
        return 65
    }
}

release_verify_artifact_digests() {
    local output_dir="$1" archive_path="$2" app_path="$3" dmg_path="${4:-}" metadata expected actual
    metadata="$(release_metadata_path "$output_dir")"
    expected="$(awk -F= '$1 == "archive_sha256" { print $2 }' "$metadata")"
    actual="$(release_tree_sha256 "$archive_path")"
    [[ -n "$expected" && "$expected" == "$actual" ]] || { echo 'archive digest does not match provenance' >&2; return 65; }
    expected="$(awk -F= '$1 == "app_sha256" { print $2 }' "$metadata")"
    actual="$(release_tree_sha256 "$app_path")"
    [[ -n "$expected" && "$expected" == "$actual" ]] || { echo 'app digest does not match provenance' >&2; return 65; }
    if [[ -n "$dmg_path" ]]; then
        expected="$(awk -F= '$1 == "dmg_sha256" { print $2 }' "$metadata")"
        actual="$(release_sha256 "$dmg_path")"
        [[ -n "$expected" && "$expected" == "$actual" ]] || { echo 'DMG digest does not match provenance' >&2; return 65; }
    fi
}

# Hash every file in a bundle in a stable path order. This gives later phases
# an input digest even though a directory itself has no portable SHA-256.
release_tree_sha256() {
    local root="$1"
    if command -v shasum >/dev/null 2>&1; then
        # BSD sort (the macOS runner) has no GNU sort -z. Bundle paths do
        # not contain newlines, so newline sorting remains deterministic while
        # preserving spaces via read -r.
        find "$root" -type f -print | LC_ALL=C sort | while IFS= read -r file; do
            printf '%s  %s\n' "$(shasum -a 256 "$file" | awk '{print $1}')" "${file#"$root"/}"
        done | shasum -a 256 | awk '{print $1}'
    else
        find "$root" -type f -print | LC_ALL=C sort | while IFS= read -r file; do
            printf '%s  %s\n' "$(sha256sum "$file" | awk '{print $1}')" "${file#"$root"/}"
        done | sha256sum | awk '{print $1}'
    fi
}

release_sha256() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        sha256sum "$1" | awk '{print $1}'
    fi
}

release_state() {
    printf '%s/.release-state-%s\n' "$1" "$2"
}
