# MacTalk model provenance and loading boundary

**Implementation evidence:** `d6eab1041efc024976502099c157907274ff3154`,
2026-07-26. This document describes the active production boundary at that
commit. Later documentation-only commits do not change the canonical lock.

## Evidence and canonical lock

`Config/ModelProvenance/model-provenance.v1.json` is the canonical lock for:

- five Whisper catalog artifacts at immutable revision
  `5359861c739e955e79d9a303bcbc70fb988958b1`;
- the 21-entry legacy compiled Parakeet generation at immutable revision
  `aed02740059203c4a87495924f685de3722ae9ce`; and
- the nine active source `.mlpackage`/vocabulary entries at that same Parakeet
  revision.

Repository, immutable revision, path, byte count, and SHA-256 tuple fields are
authoritative. `docs/security/model-provenance/` contains raw Hugging Face API
captures stored byte-for-byte at collection. Captures may contain mutable scan
or message fields and are not expected to byte-match a later provider response.
`evidence-index.v1.json` locks the local evidence files' size, SHA-256, URL, and
expected response set; it is not a claim that the provider will reproduce
mutable metadata bytes.

The exact 151,122-byte vocabulary response is committed separately and checked
by SHA-256 (`7ec60e05…198735`) and Git blob ID (`c684822e…9bb0`). For eight
compiled non-LFS `metadata.json` and `model.mil` files, exact fetched bytes live
under
`parakeet-compiled-regular-files-aed02740059203c4a87495924f685de3722ae9ce/`.
The generator validates tree size, Git blob OID, and runtime SHA-256 before
deriving canonical tuples. Those eight files total 1,025,477 bytes. Model and
weight tuples are derived from captured LFS OIDs and sizes.

FluidAudio is pinned independently to version `0.15.5`, revision
`19600a485baa4998812e4654b70d2bab8f2c9949`.

## Generated production representation

Run:

```sh
python3 scripts/generate-model-provenance.py --check
bash scripts/tests/test_model_provenance_generation.sh
```

The generator rejects mutable revisions, malformed or uppercase digests,
duplicate/unknown/missing paths, mismatched evidence sizes/OIDs, vocabulary
identity drift, and canonical tuple drift. It emits
`MacTalk/MacTalk/Whisper/GeneratedModelProvenance.swift`; production code does
not maintain a second hand-authored artifact table. `ModelCatalog` consumes the
Whisper entries. Active Parakeet source preparation consumes `parakeetSource`;
`parakeetCompiled` remains only for verified migration reuse and retirement of
the legacy generation.

Both commands are offline and do not access a provider or user model store.

## Active transport, snapshot, and loading boundary

All production Whisper and Parakeet transfer composition delegates byte
transport to `BoundedModelDownloadTransport`. Production policy uses an
ephemeral session, identity encoding, HTTPS-only URLs, at most 16 unique
mirrors, and an artifact limit of 671,088,640 bytes. Loopback HTTP is injectable
for tests only. Download managers still own operation identity, cancellation,
verification, staging, and publication; they do not own a separate URLSession.

`ParakeetBootstrap` actively performs this sequence:

1. `ParakeetSourcePreparer` materializes the canonical source store from the
   generated source manifest, optionally copying independently verified legacy
   weights.
2. `VerifiedParakeetSourceSnapshotProvider` holds a shared store lease,
   validates ownership, mode, marker, identity, and exact manifest tree, then
   reads the verified artifacts through descriptors into owned bytes.
3. `VerifiedParakeetModelLoader` validates source identity and vocabulary,
   creates CoreML byte assets, and returns a load result retaining the complete
   snapshot and assets.
4. `ParakeetBootstrapLoadedManager` retains that load result for the exact
   manager generation. Stale or cancelled generations cannot publish over a
   newer generation.

The production binary does not call `AsrModels.load(from:)`,
`ModelHub.loadModels`, `MLModel(contentsOf:)`, or `MLModelAsset(url:)`.
`scripts/model-security-source-guard.sh` and its negative fixtures enforce this
source boundary. The design avoids mutable-path loading; it does not claim a
numeric peak-memory bound.

## Legacy compiled-generation retirement

Only after a verified source manager is published does
`ParakeetLegacyCompiledCleaner` attempt retirement. It acquires exclusive store
ownership, validates the exact compiled manifest, atomically moves the tree to
a fixed private quarantine with exclusive rename semantics, revalidates it,
removes entries descriptor-relatively, and synchronizes parent-directory
mutations. Interrupted valid quarantine cleanup is recoverable.

Cleanup failure is non-fatal and retryable: it preserves the ready source
manager but never authorizes compiled-path fallback. Unexpected or mutated
quarantine content is preserved for diagnosis rather than deleted.

## Governance boundary

MacTalk is a **solo-maintainer** repository. During Task 12, the sole
maintainer declared owner approval and risk acceptance for the canonical lock
and source cutover at commit
`d6eab1041efc024976502099c157907274ff3154`; the lock SHA-256 was
`9707fb09598e23902d5a3847e84acae468ca85b357d6c100b199f35a7312e3b2`.
For this project, that recorded maintainer declaration is the provenance
governance gate. Changes to the canonical lock require a new declaration
binding the changed lock digest and reviewed commit.

This repository record is not a cryptographically authenticated signature or a
claim of independent attestation, CODEOWNERS review, required GitHub approvals,
or branch-protection enforcement. Git author display names and the repository
owner account are not treated as independent identity proof. If another
maintainer joins the project, this policy should be revisited rather than
retroactively inventing independent evidence.
