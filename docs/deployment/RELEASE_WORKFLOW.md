# MacTalk reproducible release workflow

The release version and build number live only in
[`scripts/release-version.env`](../../scripts/release-version.env). The archive
passes those values to Xcode as `MARKETING_VERSION` and
`CURRENT_PROJECT_VERSION`; the archive verifier rejects a bundle with any
other values.

## Trust and release preflight policy

Releases are made only from a clean, detached checkout whose `HEAD` equals
an explicitly supplied immutable tag. The tag must be exactly `vX.Y.Z` and
must equal `MACTALK_MARKETING_VERSION`; versions also use exactly `X.Y.Z`.
`v1.1.3` is permanently reserved and must never be moved. Bump
`scripts/release-version.env`, commit it, and create a new tag before starting
the workflow. The repository must protect release tags (no force-push/delete)
and require release environment reviewers; the tag policy is the trust root,
not a mutable branch ref.

A secret-free preflight runs before certificate or notarization credentials are
read. It records the source commit, whisper.cpp submodule commit, exact fresh
build recipe, UTC timestamp, and archive/app/DMG digests in chained provenance
metadata. Every later phase verifies the metadata digest and its input digest.
Signing uses secure Apple timestamps and verification rejects signatures without
one. No phase downloads a model or retries notarization automatically.

## Prerequisites

- macOS with Xcode, XcodeGen 2.44.1, CMake, `codesign`, `hdiutil`, `spctl`,
  `xcrun`, and `gh`.
- The whisper.cpp submodule. `archive-release.sh` builds its libraries with
  Metal when `Vendor/whisper.cpp/build` is absent. It never downloads a
  transcription model.
- A Developer ID Application certificate **and private key** in the login
  keychain.
- Notarization credentials, either a `notarytool` keychain profile in
  `MACTALK_NOTARY_KEYCHAIN_PROFILE`, or the three environment variables
  `APPLE_ID`, `APPLE_TEAM_ID`, and `APPLE_APP_SPECIFIC_PASSWORD`.
- `MACTALK_CODE_SIGN_IDENTITY` and `MACTALK_DEVELOPMENT_TEAM` for the signing
  certificate and Apple team.

Never put passwords, private keys, or API credentials in the repository or in
command output. The scripts do not enable shell tracing and pass credentials
only to the tool that consumes them.

## Local release candidate

Run from the repository root. This creates artifacts under `release/` (or the
specified output directory), but does not create a tag or GitHub release:

```bash
# Use a newly created immutable tag; never reuse v1.1.3.
git fetch --tags origin
git checkout --detach vX.Y.Z
export RELEASE_TAG='vX.Y.Z'
export MACTALK_CODE_SIGN_IDENTITY='Developer ID Application: Name (TEAM_ID)'
export MACTALK_DEVELOPMENT_TEAM='TEAM_ID'
export MACTALK_NOTARY_KEYCHAIN_PROFILE='MacTalk-Notary'
bash scripts/archive-release.sh --output-dir release
bash scripts/verify-release.sh --output-dir release
bash scripts/notarize-release.sh --output-dir release
```

The scripts enforce archive, signing verification, DMG creation, notarization
submit/wait, stapling, post-staple Gatekeeper assessment, and finally the
SHA-256 manifest. The build-to-notarize and notarize-to-publish handoffs are
single non-hidden `ditto -c -k --sequesterRsrc` archives with SHA-256 sidecars;
receivers verify the digest, extract with `ditto`, and repeat signature, team,
entitlement, secure-timestamp, and launchability checks. State markers bind
phase, provenance digest, and source commit and prevent a later phase from
running early. If a phase fails, its artifacts remain in the output directory;
correct the
external failure and rerun that phase rather than deleting the archive.

The generated manifest records the app version, build number, source commit,
and DMG SHA-256. Inspect it without exposing credentials:

```bash
cat release/MacTalk-*-manifest.txt
```

## GitHub Actions

Every signing, notarization, and publish job is bound to the GitHub Environment
named exactly `release`. Repository administrators must create that environment,
configure required reviewers, and configure protected-tag rules that forbid
force-pushes and deletion for `v*.*.*`. Until those settings exist GitHub will
fail the workflow (or hold it awaiting reviewer approval); a green job without
those controls is not an authorized release. The workflow carries the
secret-free preflight's exact peeled commit through every checkout and compares
it again before publish.

`.github/workflows/release.yml` runs for a `v*.*.*` tag or manual dispatch of
a newly created immutable tag. Checkout uses the explicit tag with
`persist-credentials: false`; all actions are pinned to commit SHAs. The
workflow is serialized per tag. Build/verify jobs have `contents: read`, and
only signing/notarization steps receive Apple inputs. Certificates and
P12/keychains are deleted in unconditional cleanup steps. The final publish
job alone has `contents: write`: it creates a draft, uploads the DMG and
manifest, verifies the uploaded SHA-256 digest, then publishes the draft.
Configure repository variables
`MACTALK_CODE_SIGN_IDENTITY` and `MACTALK_DEVELOPMENT_TEAM`, and secrets
`MACTALK_CERTIFICATE_P12_BASE64`, `MACTALK_CERTIFICATE_PASSWORD`,
`MACTALK_KEYCHAIN_PASSWORD`, `MACTALK_NOTARY_KEYCHAIN_PROFILE` (or
`MACTALK_APPLE_ID`, `MACTALK_APPLE_TEAM_ID`, and
`MACTALK_APPLE_APP_SPECIFIC_PASSWORD`). Local runs must not create or push
tags/releases. Apple membership,
signing certificates, notarization credentials, and protected-tag/environment
configuration remain external prerequisites; never source real credentials in
hermetic tests.
