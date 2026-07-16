# MacTalk reproducible release workflow

The release version and build number live only in
[`scripts/release-version.env`](../../scripts/release-version.env). The archive
passes those values to Xcode as `MARKETING_VERSION` and
`CURRENT_PROJECT_VERSION`; the archive verifier rejects a bundle with any
other values.

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
export MACTALK_CODE_SIGN_IDENTITY='Developer ID Application: Name (TEAM_ID)'
export MACTALK_DEVELOPMENT_TEAM='TEAM_ID'
export MACTALK_NOTARY_KEYCHAIN_PROFILE='MacTalk-Notary'
bash scripts/archive-release.sh --output-dir release
bash scripts/verify-release.sh --output-dir release
bash scripts/notarize-release.sh --output-dir release
```

The scripts enforce archive, signing verification, DMG creation, notarization
submit/wait, stapling, post-staple Gatekeeper assessment, and finally the
SHA-256 manifest. State markers prevent a later phase from running early. If a
phase fails, its artifacts remain in the output directory; correct the
external failure and rerun that phase rather than deleting the archive.

The generated manifest records the app version, build number, source commit,
and DMG SHA-256. Inspect it without exposing credentials:

```bash
cat release/MacTalk-*-manifest.txt
```

## GitHub Actions

`.github/workflows/release.yml` runs for a `v*.*.*` tag or manual dispatch of
an existing tag. Configure repository variables
`MACTALK_CODE_SIGN_IDENTITY` and `MACTALK_DEVELOPMENT_TEAM`, and secrets
`MACTALK_CERTIFICATE_P12_BASE64`, `MACTALK_CERTIFICATE_PASSWORD`,
`MACTALK_KEYCHAIN_PASSWORD`, `MACTALK_APPLE_ID`,
`MACTALK_APPLE_TEAM_ID`, and `MACTALK_APP_SPECIFIC_PASSWORD`. It grants only
`contents: write`, and publishes only after the final Gatekeeper and checksum
steps. Local runs must not create or push tags/releases.
