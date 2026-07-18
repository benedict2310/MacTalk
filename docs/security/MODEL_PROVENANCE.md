# MacTalk model provenance

This commit adds local, deterministic provenance mechanics only. The generated
source `.mlpackage` metadata is **inactive**: the current downloader and
Parakeet bootstrap continue to use the existing 21-file compiled manifest.
Changing the active store/layout or loader is a later security task.

## Evidence and lock

`Config/ModelProvenance/model-provenance.v1.json` is the canonical lock for:

- five Whisper catalog artifacts at immutable revision
  `5359861c739e955e79d9a303bcbc70fb988958b1`;
- all 21 existing compiled Parakeet entries at immutable revision
  `aed02740059203c4a87495924f685de3722ae9ce`; and
- nine future source `.mlpackage`/vocabulary entries at that same Parakeet
  revision.

`docs/security/model-provenance/` contains the unmodified immutable HF tree
responses. Parakeet pagination is retained as two separate response files and
is described by `evidence-index.v1.json`; responses are never concatenated or
normalized. The exact 151,122-byte vocabulary response is committed separately
and is checked both by SHA-256 (`7ec60e05…198735`) and its Git blob ID
(`c684822e…9bb0`). No model specification or LFS payload was fetched.

HF tree metadata exposes LFS OIDs and sizes for model payloads. The existing
compiled manifest also contains eight regular (non-LFS) file digests, which are
retained in `parakeet-compiled-digest-evidence.v1.json` as the prior reviewed
compiled inventory; the generator cross-checks its paths and sizes against the
immutable tree response. The future source entries derive their model and
weight tuples directly from LFS OIDs and sizes in that response.

FluidAudio is pinned independently to version `0.15.5`, revision
`19600a485baa4998812e4654b70d2bab8f2c9949`.

## Generated representation

Run:

```sh
python3 scripts/generate-model-provenance.py --check
```

The generator rejects mutable revisions, malformed or uppercase digests,
duplicate/unknown/missing paths, mismatched evidence sizes/OIDs, vocabulary
identity drift, and canonical tuple drift. It emits
`MacTalk/MacTalk/Whisper/GeneratedModelProvenance.swift`, which is the sole
production representation consumed by `ModelCatalog` and the active compiled
`ParakeetModelDownloader.manifest`. `parakeetSource` is generated for the
future loader but is not referenced by active composition code.

The negative fixture suite is:

```sh
bash scripts/tests/test_model_provenance_generation.sh
```

Both commands are offline and do not access a provider or model store. The
blocking local security checks run the generator check as well.

## Approval boundary

These mechanics prove that the checked-in canonical tuples agree with the
checked-in immutable metadata and vocabulary bytes. They do **not** prove
human approval, GitHub branch protection, CODEOWNERS enforcement, or the
integrity of a future release review. The canonical lock still requires an
actual security-maintainer review and protected-branch administration before
it can be treated as an approved supply-chain change. This commit deliberately
creates no fake approval record and invents no CODEOWNERS identity.
