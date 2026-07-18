#!/usr/bin/env python3
"""Verify immutable model evidence and emit the typed Swift provenance table."""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

WHISPER_REVISION = "5359861c739e955e79d9a303bcbc70fb988958b1"
PARAKEET_REVISION = "aed02740059203c4a87495924f685de3722ae9ce"
FLUID_AUDIO_REVISION = "19600a485baa4998812e4654b70d2bab8f2c9949"
WHISPER_REPOSITORY = "ggerganov/whisper.cpp"
PARAKEET_REPOSITORY = "FluidInference/parakeet-tdt-0.6b-v3-coreml"
HEX64 = re.compile(r"^[0-9a-f]{64}$")
HEX40 = re.compile(r"^[0-9a-f]{40}$")

WHISPER_METADATA = {
    "ggml-tiny-q5_1.bin": ("whisper-tiny-q5_1", "Tiny (Q5_1) - 32MB"),
    "ggml-base-q5_1.bin": ("whisper-base-q5_1", "Base (Q5_1) - 60MB"),
    "ggml-small-q5_1.bin": ("whisper-small-q5_1", "Small (Q5_1) - 190MB"),
    "ggml-medium-q5_0.bin": ("whisper-medium-q5_0", "Medium (Q5_0) - 539MB"),
    "ggml-large-v3-turbo-q5_0.bin": ("whisper-large-v3-turbo-q5_0", "Large v3 Turbo (Q5_0) - 574MB"),
}
COMPILED_REGULAR_EVIDENCE_ROOT = "parakeet-compiled-regular-files-aed02740059203c4a87495924f685de3722ae9ce"
COMPILED_REGULAR_PATHS = {
    "Decoder.mlmodelc/metadata.json",
    "Decoder.mlmodelc/model.mil",
    "Encoder.mlmodelc/metadata.json",
    "Encoder.mlmodelc/model.mil",
    "JointDecisionv3.mlmodelc/metadata.json",
    "JointDecisionv3.mlmodelc/model.mil",
    "Preprocessor.mlmodelc/metadata.json",
    "Preprocessor.mlmodelc/model.mil",
}
EVIDENCE_INDEX = {
    "whisper-5359861c739e955e79d9a303bcbc70fb988958b1-hf-tree.json": "https://huggingface.co/api/models/ggerganov/whisper.cpp/tree/5359861c739e955e79d9a303bcbc70fb988958b1?recursive=true&expand=true&limit=100",
    "parakeet-aed02740059203c4a87495924f685de3722ae9ce-hf-tree-001.json": "https://huggingface.co/api/models/FluidInference/parakeet-tdt-0.6b-v3-coreml/tree/aed02740059203c4a87495924f685de3722ae9ce?recursive=true&expand=true&limit=100",
    "parakeet-aed02740059203c4a87495924f685de3722ae9ce-hf-tree-002.json": "https://huggingface.co/api/models/FluidInference/parakeet-tdt-0.6b-v3-coreml/tree/aed02740059203c4a87495924f685de3722ae9ce?expand=true&recursive=true&limit=100&cursor=ZXlKbWFXeGxYMjVoYldVaU9pSk5aV3hGYm1OdlpHVnlMbTFzYlc5a1pXeGpMM2RsYVdkb2RITXZkMlZwWjJoMExtSnBiaUlzSW5SeVpXVmZiMmxrSWpvaU0yVTBPVGMzTUdRNU9HRTJZMlJqTnpjM1pUY3pPREJoWkRWbVpERTNaV0ppWVRNNU5EWTVaaUo5OjEwMA%3D%3D",
    "parakeet_vocab.json": "https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml/resolve/aed02740059203c4a87495924f685de3722ae9ce/parakeet_vocab.json?download=false",
}
COMPILED_PATHS = {
    "Decoder.mlmodelc/analytics/coremldata.bin": "Decoder",
    "Decoder.mlmodelc/coremldata.bin": "Decoder",
    "Decoder.mlmodelc/metadata.json": "Decoder",
    "Decoder.mlmodelc/model.mil": "Decoder",
    "Decoder.mlmodelc/weights/weight.bin": "Decoder",
    "Encoder.mlmodelc/analytics/coremldata.bin": "Encoder",
    "Encoder.mlmodelc/coremldata.bin": "Encoder",
    "Encoder.mlmodelc/metadata.json": "Encoder",
    "Encoder.mlmodelc/model.mil": "Encoder",
    "Encoder.mlmodelc/weights/weight.bin": "Encoder",
    "JointDecisionv3.mlmodelc/analytics/coremldata.bin": "JointDecisionv3",
    "JointDecisionv3.mlmodelc/coremldata.bin": "JointDecisionv3",
    "JointDecisionv3.mlmodelc/metadata.json": "JointDecisionv3",
    "JointDecisionv3.mlmodelc/model.mil": "JointDecisionv3",
    "JointDecisionv3.mlmodelc/weights/weight.bin": "JointDecisionv3",
    "Preprocessor.mlmodelc/analytics/coremldata.bin": "Preprocessor",
    "Preprocessor.mlmodelc/coremldata.bin": "Preprocessor",
    "Preprocessor.mlmodelc/metadata.json": "Preprocessor",
    "Preprocessor.mlmodelc/model.mil": "Preprocessor",
    "Preprocessor.mlmodelc/weights/weight.bin": "Preprocessor",
    "parakeet_vocab.json": "Vocabulary",
}
SOURCE_PATHS = {
    "mlpackages/Preprocessor.mlpackage/Data/com.apple.CoreML/model.mlmodel": ("Preprocessor", "specification"),
    "mlpackages/Preprocessor.mlpackage/Data/com.apple.CoreML/weights/weight.bin": ("Preprocessor", "weights"),
    "mlpackages/Encoder.mlpackage/Data/com.apple.CoreML/model.mlmodel": ("Encoder", "specification"),
    "mlpackages/Encoder.mlpackage/Data/com.apple.CoreML/weights/weight.bin": ("Encoder", "weights"),
    "mlpackages/Decoder.mlpackage/Data/com.apple.CoreML/model.mlmodel": ("Decoder", "specification"),
    "mlpackages/Decoder.mlpackage/Data/com.apple.CoreML/weights/weight.bin": ("Decoder", "weights"),
    "JointDecisionv3.mlpackage/Data/com.apple.CoreML/model.mlmodel": ("JointDecisionv3", "specification"),
    "JointDecisionv3.mlpackage/Data/com.apple.CoreML/weights/weight.bin": ("JointDecisionv3", "weights"),
    "parakeet_vocab.json": ("Vocabulary", "vocabulary"),
}


def fail(message: str) -> "NoReturn":
    raise ValueError(message)


def read_json(path: Path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        fail(f"invalid JSON {path}: {exc}")


def validate_evidence_index(root: Path) -> None:
    directory = root / "docs/security/model-provenance"
    index = read_json(directory / "evidence-index.v1.json")
    if set(index) != {"files", "repository_revisions", "schema"} or index.get("schema") != "mactalk.model-evidence.v1":
        fail("unsupported evidence index schema")
    revisions = index.get("repository_revisions")
    if revisions != {"parakeet": PARAKEET_REVISION, "whisper": WHISPER_REVISION}:
        fail("evidence index repository revisions drift")
    files = index.get("files")
    if not isinstance(files, list) or len(files) != len(EVIDENCE_INDEX):
        fail("evidence index file set is incomplete")
    seen = set()
    for entry in files:
        if not isinstance(entry, dict) or set(entry) != {"bytes", "path", "sha256", "url"}:
            fail("malformed evidence index entry")
        path = entry["path"]
        if path in seen or path not in EVIDENCE_INDEX:
            fail(f"unexpected evidence index path: {path}")
        seen.add(path)
        if entry["url"] != EVIDENCE_INDEX[path] or not isinstance(entry["bytes"], int) or entry["bytes"] <= 0 or not HEX64.fullmatch(str(entry["sha256"])):
            fail(f"invalid evidence index metadata: {path}")
        raw = directory / path
        if not raw.is_file():
            fail(f"missing indexed evidence bytes: {path}")
        data = raw.read_bytes()
        if len(data) != entry["bytes"] or hashlib.sha256(data).hexdigest() != entry["sha256"]:
            fail(f"indexed evidence bytes drift: {path}")
    if seen != set(EVIDENCE_INDEX):
        fail("evidence index has missing or extra response pages")


def evidence(root: Path, repository: str) -> dict[str, dict]:
    directory = root / "docs/security/model-provenance"
    validate_evidence_index(root)
    if repository == WHISPER_REPOSITORY:
        paths = [directory / "whisper-5359861c739e955e79d9a303bcbc70fb988958b1-hf-tree.json"]
    else:
        paths = [directory / name for name in sorted(EVIDENCE_INDEX) if name.startswith("parakeet-aed")]
    result: dict[str, dict] = {}
    for path in paths:
        values = read_json(path)
        if not isinstance(values, list):
            fail(f"evidence must be a JSON array: {path}")
        for value in values:
            if not isinstance(value, dict) or not isinstance(value.get("path"), str):
                fail(f"malformed evidence entry: {path}")
            name = value["path"]
            if name in result:
                fail(f"duplicate evidence path: {name}")
            result[name] = value
    return result


def validate_revision(value: str, expected: str, label: str) -> None:
    if value != expected or not HEX40.fullmatch(value):
        fail(f"{label} must be the immutable revision {expected}")


def tuple_from_lfs(item: dict, path: str) -> tuple[int, str]:
    lfs = item.get("lfs")
    if not isinstance(lfs, dict) or not HEX64.fullmatch(str(lfs.get("oid", ""))):
        fail(f"missing immutable LFS digest for {path}")
    size = item.get("size")
    if not isinstance(size, int) or size <= 0 or lfs.get("size") != size:
        fail(f"LFS size mismatch for {path}")
    return size, lfs["oid"]


def tuple_from_regular_file(root: Path, item: dict, path: str, relative_root: str) -> tuple[int, str]:
    if item.get("type") != "file" or item.get("lfs") is not None or not HEX40.fullmatch(str(item.get("oid", ""))):
        fail(f"regular evidence tree identity is invalid for {path}")
    raw = root / "docs/security/model-provenance" / relative_root / path
    if not raw.is_file():
        fail(f"missing byte-preserved regular evidence: {path}")
    data = raw.read_bytes()
    size = item.get("size")
    if not isinstance(size, int) or size <= 0 or len(data) != size:
        fail(f"regular evidence size mismatch for {path}")
    git_blob = hashlib.sha1((f"blob {len(data)}\0").encode() + data).hexdigest()
    if git_blob != item["oid"]:
        fail(f"regular evidence Git blob mismatch for {path}")
    return size, hashlib.sha256(data).hexdigest()


def validate_entry(entry: dict, expected_kind: str, expected_layout: str) -> None:
    required = {"kind", "layout", "path", "bytes", "sha256", "role", "component"}
    if set(entry) != required and not (expected_kind == "whisper" and set(entry) == required | {"id", "displayName", "license", "languages"}):
        fail(f"entry fields mismatch for {entry.get('path')}")
    if entry.get("kind") != expected_kind or entry.get("layout") != expected_layout:
        fail(f"entry kind/layout mismatch for {entry.get('path')}")
    if not isinstance(entry.get("path"), str) or not entry["path"] or entry["path"].startswith("/") or ".." in entry["path"].split("/"):
        fail(f"unsafe provenance path: {entry.get('path')}")
    if not isinstance(entry.get("bytes"), int) or entry["bytes"] <= 0:
        fail(f"invalid byte count for {entry.get('path')}")
    if not isinstance(entry.get("sha256"), str) or not HEX64.fullmatch(entry["sha256"]):
        fail(f"sha256 must be lowercase 64-hex for {entry.get('path')}")


def expected_entries(root: Path) -> tuple[list[dict], list[dict], list[dict]]:
    whisper = evidence(root, WHISPER_REPOSITORY)
    parakeet = evidence(root, PARAKEET_REPOSITORY)
    whisper_entries = []
    for path, (identifier, display) in WHISPER_METADATA.items():
        item = whisper.get(path)
        if item is None:
            fail(f"missing Whisper evidence path: {path}")
        size, digest = tuple_from_lfs(item, path)
        whisper_entries.append({"kind":"whisper", "layout":"catalog", "path":path, "bytes":size, "sha256":digest, "role":"model", "component":identifier, "id":identifier, "displayName":display, "license":"MIT", "languages":["multilingual"]})
    regular_paths = {path for path in COMPILED_PATHS if path in COMPILED_REGULAR_PATHS}
    evidence_root = root / "docs/security/model-provenance" / COMPILED_REGULAR_EVIDENCE_ROOT
    if not evidence_root.is_dir() or {p.relative_to(evidence_root).as_posix() for p in evidence_root.rglob("*") if p.is_file()} != regular_paths:
        fail("compiled regular evidence path set is incomplete or contains an unknown path")
    compiled = []
    for path, component in COMPILED_PATHS.items():
        item = parakeet.get(path)
        if item is None or item.get("type") != "file":
            fail(f"missing compiled Parakeet evidence path: {path}")
        if item.get("lfs") is not None:
            size, digest = tuple_from_lfs(item, path)
        elif path in COMPILED_REGULAR_PATHS:
            size, digest = tuple_from_regular_file(root, item, path, COMPILED_REGULAR_EVIDENCE_ROOT)
        elif path == "parakeet_vocab.json":
            size, digest = tuple_from_regular_file(root, item, path, "")
        else:
            fail(f"compiled entry has neither LFS nor independent regular evidence: {path}")
        compiled.append({"kind":"parakeet", "layout":"compiled", "path":path, "bytes":size, "sha256":digest, "role":"compiled", "component":component})
    source = []
    for path, (component, role) in SOURCE_PATHS.items():
        item = parakeet.get(path)
        if item is None:
            fail(f"missing source Parakeet evidence path: {path}")
        if path == "parakeet_vocab.json":
            size, digest = tuple_from_regular_file(root, item, path, "")
        else:
            size, digest = tuple_from_lfs(item, path)
        source.append({"kind":"parakeet", "layout":"source", "path":path, "bytes":size, "sha256":digest, "role":role, "component":component})
    return whisper_entries, compiled, source


def load_and_validate(root: Path) -> tuple[dict, list[dict], list[dict], list[dict]]:
    canonical = read_json(root / "Config/ModelProvenance/model-provenance.v1.json")
    if canonical.get("schema") != "mactalk.model-provenance.v1": fail("unsupported provenance schema")
    repositories = canonical.get("repositories")
    if not isinstance(repositories, dict): fail("missing repositories")
    for key, name, revision in (("whisper", WHISPER_REPOSITORY, WHISPER_REVISION), ("parakeet", PARAKEET_REPOSITORY, PARAKEET_REVISION)):
        value = repositories.get(key, {})
        if value.get("name") != name: fail(f"wrong {key} repository")
        validate_revision(value.get("revision", ""), revision, key)
        if not isinstance(value.get("sourceURL"), str) or revision not in value["sourceURL"]: fail(f"{key} source URL is not immutable")
    fluid = canonical.get("fluidAudio", {})
    if fluid != {"version":"0.15.5", "revision":FLUID_AUDIO_REVISION}: fail("FluidAudio pin mismatch")
    actual = [*expected_entries(root)[0], *expected_entries(root)[1], *expected_entries(root)[2]]
    entries = canonical.get("entries")
    if not isinstance(entries, list): fail("canonical entries must be a list")
    keys = [(x.get("kind"), x.get("layout"), x.get("path")) for x in entries]
    if len(keys) != len(set(keys)): fail("duplicate canonical tuple")
    for x in entries: validate_entry(x, x.get("kind"), x.get("layout"))
    if entries != actual: fail("canonical tuples drift from immutable evidence")
    return canonical, actual[:5], actual[5:26], actual[26:]


def swift_string(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def emit(root: Path) -> str:
    _, whisper, compiled, source = load_and_validate(root)
    lines = ["// Generated by scripts/generate-model-provenance.py; do not edit.", "import Foundation", "", "struct GeneratedWhisperModel: Sendable {", "    let id: String", "    let displayName: String", "    let filename: String", "    let sha256: String", "    let sizeBytes: Int64", "    let license: String?", "    let languages: [String]?", "    let revision: String", "    let source: String", "}", "", "struct GeneratedParakeetManifestEntry: Codable, Hashable, Sendable {", "    let path: String", "    let size: Int64", "    let sha256: String", "}", "", "enum GeneratedModelProvenance {", f"    static let whisperRepository = {swift_string(WHISPER_REPOSITORY)}", f"    static let whisperRevision = {swift_string(WHISPER_REVISION)}", f"    static let parakeetRepository = {swift_string(PARAKEET_REPOSITORY)}", f"    static let parakeetRevision = {swift_string(PARAKEET_REVISION)}", f"    static let fluidAudioRevision = {swift_string(FLUID_AUDIO_REVISION)}", "", "    static let whisper: [GeneratedWhisperModel] = ["]
    for x in whisper:
        lines.append(f"        .init(id: {swift_string(x['id'])}, displayName: {swift_string(x['displayName'])}, filename: {swift_string(x['path'])}, sha256: {swift_string(x['sha256'])}, sizeBytes: {x['bytes']}, license: {swift_string(x['license'])}, languages: [{', '.join(swift_string(v) for v in x['languages'])}], revision: whisperRevision, source: whisperRepository),")
    lines += ["    ]", "", "    static let parakeetCompiled: [GeneratedParakeetManifestEntry] = ["]
    for x in compiled: lines.append(f"        .init(path: {swift_string(x['path'])}, size: {x['bytes']}, sha256: {swift_string(x['sha256'])}),")
    lines += ["    ]", "", "    // Generated for the future in-memory .mlpackage loader; inactive in this commit.", "    static let parakeetSource: [GeneratedParakeetManifestEntry] = ["]
    for x in source: lines.append(f"        .init(path: {swift_string(x['path'])}, size: {x['bytes']}, sha256: {swift_string(x['sha256'])}),")
    lines += ["    ]", "}", ""]
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--output", type=Path)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    root = args.root.resolve()
    output = (args.output or root / "MacTalk/MacTalk/Whisper/GeneratedModelProvenance.swift").resolve()
    try:
        generated = emit(root)
        if args.check:
            if not output.is_file() or output.read_text(encoding="utf-8") != generated:
                fail(f"generated provenance drift: {output}")
        else:
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_text(generated, encoding="utf-8")
    except ValueError as exc:
        print(f"provenance error: {exc}", file=sys.stderr)
        return 1
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
