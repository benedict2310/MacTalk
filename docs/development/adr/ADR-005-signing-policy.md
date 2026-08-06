# ADR-005: Signing and release policy

- **Status:** Accepted
- **Date:** 2026-07-18

## Decision

Local Release builds use the explicit Developer ID identity/team supplied to
`build.sh`; nested whisper/ggml dylibs are copied, install names are rewritten,
and re-signed with the same identity. Release archives are allowed only from a
clean detached immutable `vX.Y.Z` tag matching `scripts/release-version.env`.
Verification requires hardened runtime, secure Apple timestamp, matching team,
valid entitlements, launchability, and archive/app/DMG digests.

Notarization and publication are credential-gated external operations. The
GitHub workflow limits release write permission to the final publish job and
requires the protected `release` environment, reviewers, Apple certificate and
private key, and notarization inputs. No docs, local test, or signed build is a
notarization claim.

## Consequences

- Unsigned CI tests use `CODE_SIGNING_ALLOWED=NO` and do not validate release
  signing.
- A local signed build can validate signing mechanics but not Apple notarization
  or GitHub environment controls.
- Credentials never belong in the repository or shell tracing output.

Evidence: `build.sh`, `project.yml`, `scripts/archive-release.sh`,
`scripts/verify-release.sh`, `scripts/notarize-release.sh`, and
`.github/workflows/release.yml`.
