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

The immutable revision, repository, path, byte-count, and digest tuple fields
in that lock are authoritative. `docs/security/model-provenance/` contains
raw HF API captures stored byte-for-byte at collection. Those captures can
contain mutable `securityFileStatus` scan/message fields; they are not expected
to byte-match a later refetch. `evidence-index.v1.json` is an integrity
inventory of the captured repository response bytes: it locks the local files'
size, SHA-256, URL, and expected raw-response set. It is not a claim that a
provider will return byte-identical scan metadata in the future. The exact
151,122-byte vocabulary response is committed separately and is checked both
by SHA-256 (`7ec60e05…198735`) and its Git blob ID (`c684822e…9bb0`).

HF tree metadata exposes LFS OIDs and sizes for model payloads. For the eight
compiled non-LFS `metadata.json` and `model.mil` files, the exact fetched bytes
are committed under
`parakeet-compiled-regular-files-aed02740059203c4a87495924f685de3722ae9ce/`.
The generator independently verifies each file's exact tree size, Git blob OID,
and runtime SHA-256 before deriving canonical tuples; no locally authored
sidecar is authoritative. The eight newly fetched files total **1,025,477
bytes**. Their immutable raw URLs are the revision-pinned `resolve` URLs for
each path under:
`https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml/resolve/aed02740059203c4a87495924f685de3722ae9ce/`.
The future source entries derive their model and weight tuples directly from
LFS OIDs and sizes in the captured response.

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
captured revision-pinned metadata, exact regular-file bytes, and vocabulary
bytes. They do **not** claim external human approval, GitHub branch protection,
CODEOWNERS enforcement, or the integrity of a future release review. This
commit records byte collection and local integrity checks only; it creates no
fake approval record and invents no external approver identity.
