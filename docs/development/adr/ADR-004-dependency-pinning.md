# ADR-004: Dependency and model provenance pinning

- **Status:** Accepted
- **Date:** 2026-07-18

## Decision

SwiftPM pins FluidAudio with `exactVersion: 0.15.5` in `project.yml`; the
committed `Package.resolved` pins revision
`19600a485baa4998812e4654b70d2bab8f2c9949`. XcodeGen is pinned to 2.44.1 by
`scripts/install_xcodegen.sh` and CI. Project generation must produce no diff.

Whisper catalog entries carry immutable source, revision, filename, size, and
SHA-256 metadata. The first model URL is the provenance authority; fallback
URLs are byte sources only. A staged artifact is installed only after the
expected hash and metadata validate.

## Consequences

Dependency updates require changing both declarative configuration and the
resolved artifact, then rerunning generation and deterministic tests. Model
providers and network access remain outside unit-test evidence. A model path
alone is not trusted without catalog identity and hash validation.

Evidence: `project.yml`, `Package.resolved`, `scripts/install_xcodegen.sh`,
`Whisper/ModelCatalog.swift`, `Whisper/ModelIntegrityVerifier.swift`.
