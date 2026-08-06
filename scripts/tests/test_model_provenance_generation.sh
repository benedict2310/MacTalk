#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GENERATOR="$ROOT/scripts/generate-model-provenance.py"
CANONICAL="$ROOT/Config/ModelProvenance/model-provenance.v1.json"
GENERATED="$ROOT/MacTalk/MacTalk/Whisper/GeneratedModelProvenance.swift"
SECURITY_CHECKS="$ROOT/scripts/ci-security-checks.sh"

for path in "$GENERATOR" "$CANONICAL" "$GENERATED" "$SECURITY_CHECKS"; do
  test -f "$path" || { echo "missing provenance artifact: $path" >&2; exit 1; }
done
python3 "$GENERATOR" --root "$ROOT" --check

grep -Fq 'bash scripts/tests/test_model_provenance_generation.sh' "$SECURITY_CHECKS" || {
  echo 'security checker does not execute the provenance negative fixture suite' >&2
  exit 1
}

tmp="$(mktemp -d "${TMPDIR:-/tmp}/mactalk-provenance-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

restore_fixture() {
  rm -rf "$tmp/Config" "$tmp/docs" "$tmp/MacTalk" "$tmp/scripts"
  cp -R "$ROOT/Config" "$tmp/Config"
  cp -R "$ROOT/docs" "$tmp/docs"
  cp -R "$ROOT/MacTalk" "$tmp/MacTalk"
  cp -R "$ROOT/scripts" "$tmp/scripts"
}
restore_fixture

expect_failure() {
  local label="$1"
  shift
  local expected=""
  if [[ "${1:-}" != python3 && "${1:-}" != bash ]]; then
    expected="$1"
    shift
  fi
  if "$@" >"$tmp/$label.out" 2>&1; then
    echo "negative provenance fixture unexpectedly passed: $label" >&2
    cat "$tmp/$label.out" >&2
    exit 1
  fi
  if [[ -n "$expected" ]] && ! grep -Fq "$expected" "$tmp/$label.out"; then
    echo "negative provenance fixture failed at the wrong validation layer: $label" >&2
    cat "$tmp/$label.out" >&2
    exit 1
  fi
}

update_evidence_index() {
  local evidence_path="$1"
  python3 - "$tmp/docs/security/model-provenance/evidence-index.v1.json" "$tmp/docs/security/model-provenance/$evidence_path" <<'PY'
import hashlib, json, sys
index_path, evidence_path = sys.argv[1:]
index = json.load(open(index_path, encoding='utf-8'))
data = open(evidence_path, 'rb').read()
name = evidence_path.rsplit('/', 1)[-1]
record = next(item for item in index['files'] if item['path'] == name)
record['bytes'] = len(data)
record['sha256'] = hashlib.sha256(data).hexdigest()
with open(index_path, 'w', encoding='utf-8') as stream:
    json.dump(index, stream, indent=2)
    stream.write('\n')
PY
}

# Update the canonical tuple and generated output after a coherent nested LFS
# mutation. Without the pointer-to-Git-blob binding, these fixtures otherwise
# pass because the tuple's LFS digest/size remains internally consistent.
update_canonical_entry_and_generated() {
  local path="$1"
  local bytes="$2"
  local digest="$3"
  python3 - "$tmp/Config/ModelProvenance/model-provenance.v1.json" "$path" "$bytes" "$digest" <<'PY'
import json, sys
canonical_path, target, bytes_value, digest = sys.argv[1:]
canonical = json.load(open(canonical_path, encoding='utf-8'))
entry = next(item for item in canonical['entries'] if item['path'] == target)
entry['bytes'] = int(bytes_value)
entry['sha256'] = digest
with open(canonical_path, 'w', encoding='utf-8') as stream:
    json.dump(canonical, stream, indent=2, sort_keys=True)
    stream.write('\n')
PY
  python3 "$tmp/scripts/generate-model-provenance.py" --root "$tmp"
}

# Canonical tuple, evidence size/OID, path-set, immutable-reference, digest,
# generated-output, and vocabulary identity checks must all fail closed.
restore_fixture
python3 - "$tmp/Config/ModelProvenance/model-provenance.v1.json" <<'PY'
import json, sys
p=sys.argv[1]; d=json.load(open(p)); d['entries'][0]['sha256']='0'*64; json.dump(d,open(p,'w'),sort_keys=True,indent=2); open(p,'a').write('\n')
PY
expect_failure canonical-drift 'canonical tuples drift' python3 "$tmp/scripts/generate-model-provenance.py" --root "$tmp" --check

restore_fixture
python3 - "$tmp/Config/ModelProvenance/model-provenance.v1.json" <<'PY'
import json, sys
p=sys.argv[1]; d=json.load(open(p)); d['approval']={'approvedBy':'attacker'}; json.dump(d,open(p,'w'),sort_keys=True,indent=2); open(p,'a').write('\n')
PY
expect_failure canonical-unknown-key 'canonical top-level fields mismatch' python3 "$tmp/scripts/generate-model-provenance.py" --root "$tmp" --check

restore_fixture
python3 - "$tmp/Config/ModelProvenance/model-provenance.v1.json" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
text=p.read_text()
text=text.replace('  "schema": "mactalk.model-provenance.v1"', '  "schema": "mactalk.model-provenance.v1",\n  "schema": "mactalk.model-provenance.v1"')
p.write_text(text)
PY
expect_failure canonical-duplicate-key 'duplicate JSON key' python3 "$tmp/scripts/generate-model-provenance.py" --root "$tmp" --check

restore_fixture
python3 - "$tmp/Config/ModelProvenance/model-provenance.v1.json" <<'PY'
import json, sys
p=sys.argv[1]; d=json.load(open(p)); d['repositories']['whisper']['evil']='field'; json.dump(d,open(p,'w'),sort_keys=True,indent=2); open(p,'a').write('\n')
PY
expect_failure repository-unknown-key 'repository fields mismatch' python3 "$tmp/scripts/generate-model-provenance.py" --root "$tmp" --check

restore_fixture
python3 - "$tmp/Config/ModelProvenance/model-provenance.v1.json" <<'PY'
import json, sys
p=sys.argv[1]; d=json.load(open(p)); d['fluidAudio']['approvedBy']='attacker'; json.dump(d,open(p,'w'),sort_keys=True,indent=2); open(p,'a').write('\n')
PY
expect_failure fluidaudio-unknown-key 'fluidAudio fields mismatch' python3 "$tmp/scripts/generate-model-provenance.py" --root "$tmp" --check

restore_fixture
python3 - "$tmp/Config/ModelProvenance/model-provenance.v1.json" <<'PY'
import json, sys
p=sys.argv[1]; d=json.load(open(p)); d['entries'][0]['signature']='attacker'; json.dump(d,open(p,'w'),sort_keys=True,indent=2); open(p,'a').write('\n')
PY
expect_failure entry-unknown-key 'entry fields mismatch' python3 "$tmp/scripts/generate-model-provenance.py" --root "$tmp" --check

restore_fixture
python3 - "$tmp/docs/security/model-provenance/evidence-index.v1.json" <<'PY'
import json, sys
p=sys.argv[1]; d=json.load(open(p)); d['approval']='attacker'; json.dump(d,open(p,'w'),sort_keys=True,indent=2); open(p,'a').write('\n')
PY
expect_failure evidence-index-unknown-key 'evidence index fields mismatch' python3 "$tmp/scripts/generate-model-provenance.py" --root "$tmp" --check

restore_fixture
python3 - "$tmp/docs/security/model-provenance/evidence-index.v1.json" <<'PY'
import json, sys
p=sys.argv[1]; d=json.load(open(p)); d['files'][0]['approvedBy']='attacker'; json.dump(d,open(p,'w'),sort_keys=True,indent=2); open(p,'a').write('\n')
PY
expect_failure evidence-record-unknown-key 'evidence index entry fields mismatch' python3 "$tmp/scripts/generate-model-provenance.py" --root "$tmp" --check

restore_fixture
python3 - "$tmp/docs/security/model-provenance/whisper-5359861c739e955e79d9a303bcbc70fb988958b1-hf-tree.json" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
text=p.read_text()
text=text.replace('{"type":"file",', '{"type":"file","type":"file",', 1)
p.write_text(text)
PY
update_evidence_index whisper-5359861c739e955e79d9a303bcbc70fb988958b1-hf-tree.json
expect_failure raw-duplicate-key 'duplicate JSON key' python3 "$tmp/scripts/generate-model-provenance.py" --root "$tmp" --check

restore_fixture
python3 - "$tmp/docs/security/model-provenance/whisper-5359861c739e955e79d9a303bcbc70fb988958b1-hf-tree.json" <<'PY'
import json, sys
p=sys.argv[1]; d=json.load(open(p)); next(x for x in d if x['path'] == 'ggml-tiny-q5_1.bin')['type']='directory'; json.dump(d,open(p,'w'),separators=(',',':'))
PY
update_evidence_index whisper-5359861c739e955e79d9a303bcbc70fb988958b1-hf-tree.json
expect_failure whisper-type 'raw evidence item type must be file' python3 "$tmp/scripts/generate-model-provenance.py" --root "$tmp" --check

restore_fixture
python3 - "$tmp/docs/security/model-provenance/whisper-5359861c739e955e79d9a303bcbc70fb988958b1-hf-tree.json" <<'PY'
import json, sys
p=sys.argv[1]; d=json.load(open(p)); next(x for x in d if x['path'] == 'ggml-tiny-q5_1.bin')['lfs']['evil']='field'; json.dump(d,open(p,'w'),separators=(',',':'))
PY
update_evidence_index whisper-5359861c739e955e79d9a303bcbc70fb988958b1-hf-tree.json
expect_failure lfs-unknown-key 'raw LFS fields mismatch' python3 "$tmp/scripts/generate-model-provenance.py" --root "$tmp" --check

restore_fixture
python3 - "$tmp/Config/ModelProvenance/model-provenance.v1.json" <<'PY'
import json, sys
p=sys.argv[1]; d=json.load(open(p)); d['repositories']['whisper']['sourceURL']='https://attacker.example/huggingface.co/api/models/ggerganov/whisper.cpp/tree/5359861c739e955e79d9a303bcbc70fb988958b1'; json.dump(d,open(p,'w'),sort_keys=True,indent=2); open(p,'a').write('\n')
PY
expect_failure attacker-source-url 'source URL mismatch' python3 "$tmp/scripts/generate-model-provenance.py" --root "$tmp" --check

restore_fixture
python3 - "$tmp/docs/security/model-provenance/whisper-5359861c739e955e79d9a303bcbc70fb988958b1-hf-tree.json" <<'PY'
import json, sys
p=sys.argv[1]; d=json.load(open(p)); next(x for x in d if x['path'] == 'ggml-tiny-q5_1.bin')['size'] += 1; json.dump(d,open(p,'w'),separators=(',',':'))
PY
update_evidence_index whisper-5359861c739e955e79d9a303bcbc70fb988958b1-hf-tree.json
expect_failure evidence-size 'LFS size mismatch' python3 "$tmp/scripts/generate-model-provenance.py" --root "$tmp" --check

restore_fixture
python3 - "$tmp/docs/security/model-provenance/parakeet-aed02740059203c4a87495924f685de3722ae9ce-hf-tree-001.json" <<'PY'
import json, sys
p=sys.argv[1]; d=json.load(open(p)); d.append(d[0]); json.dump(d,open(p,'w'),separators=(',',':'))
PY
update_evidence_index parakeet-aed02740059203c4a87495924f685de3722ae9ce-hf-tree-001.json
expect_failure duplicate-evidence 'duplicate evidence path' python3 "$tmp/scripts/generate-model-provenance.py" --root "$tmp" --check

restore_fixture
python3 - "$tmp/docs/security/model-provenance/parakeet_vocab.json" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
data=p.read_bytes()+b'x'
p.write_bytes(data)
PY
update_evidence_index parakeet_vocab.json
expect_failure vocabulary-bytes 'regular evidence size mismatch' python3 "$tmp/scripts/generate-model-provenance.py" --root "$tmp" --check

restore_fixture
python3 - "$tmp/docs/security/model-provenance/evidence-index.v1.json" <<'PY'
import json, sys
p=sys.argv[1]; d=json.load(open(p)); d['files'][0]['sha256']='0'*64; json.dump(d,open(p,'w'),sort_keys=True,indent=2); open(p,'a').write('\n')
PY
expect_failure evidence-index-tamper 'indexed evidence bytes drift' python3 "$tmp/scripts/generate-model-provenance.py" --root "$tmp" --check

restore_fixture
python3 - "$tmp/docs/security/model-provenance/whisper-5359861c739e955e79d9a303bcbc70fb988958b1-hf-tree.json" <<'PY'
import json, sys
p=sys.argv[1]; d=json.load(open(p)); next(x for x in d if x['path'] == 'ggml-tiny-q5_1.bin')['xetHash']='0'*63; json.dump(d,open(p,'w'),separators=(',',':'))
PY
update_evidence_index whisper-5359861c739e955e79d9a303bcbc70fb988958b1-hf-tree.json
expect_failure raw-unknown-key 'raw evidence identity is invalid' python3 "$tmp/scripts/generate-model-provenance.py" --root "$tmp" --check

restore_fixture
python3 - "$tmp/Config/ModelProvenance/model-provenance.v1.json" <<'PY'
import json, sys
p=sys.argv[1]; d=json.load(open(p)); d['repositories']['whisper']['sourceURL']='https://huggingface.co/api/models/ggerganov/whisper.cpp/tree/5359861c739e955e79d9a303bcbc70fb988958b1'; json.dump(d,open(p,'w'),sort_keys=True,indent=2); open(p,'a').write('\n')
PY
expect_failure attacker-api-source-url 'source URL mismatch' python3 "$tmp/scripts/generate-model-provenance.py" --root "$tmp" --check

restore_fixture
python3 - "$tmp/docs/security/model-provenance/parakeet-aed02740059203c4a87495924f685de3722ae9ce-hf-tree-002.json" <<'PY'
import json, sys
p=sys.argv[1]; d=json.load(open(p)); next(x for x in d if x['path'] == 'mlpackages/Preprocessor.mlpackage/Data/com.apple.CoreML/model.mlmodel')['type']='directory'; json.dump(d,open(p,'w'),separators=(',',':'))
PY
update_evidence_index parakeet-aed02740059203c4a87495924f685de3722ae9ce-hf-tree-002.json
expect_failure source-type 'raw evidence item type must be file' python3 "$tmp/scripts/generate-model-provenance.py" --root "$tmp" --check

restore_fixture
python3 - "$tmp/docs/security/model-provenance/parakeet-aed02740059203c4a87495924f685de3722ae9ce-hf-tree-002.json" <<'PY'
import json, sys
p=sys.argv[1]; d=json.load(open(p)); next(x for x in d if x['path'] == 'mlpackages/Preprocessor.mlpackage/Data/com.apple.CoreML/model.mlmodel')['lfs']['size'] += 1; json.dump(d,open(p,'w'),separators=(',',':'))
PY
update_evidence_index parakeet-aed02740059203c4a87495924f685de3722ae9ce-hf-tree-002.json
expect_failure source-lfs-size 'LFS size mismatch' python3 "$tmp/scripts/generate-model-provenance.py" --root "$tmp" --check

restore_fixture
python3 - "$tmp/docs/security/model-provenance/parakeet_vocab.json" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); p.write_bytes(p.read_bytes()+b'x')
PY
update_evidence_index parakeet_vocab.json
expect_failure vocabulary-digest 'regular evidence size mismatch' python3 "$tmp/scripts/generate-model-provenance.py" --root "$tmp" --check

restore_fixture
python3 - "$tmp/Config/ModelProvenance/model-provenance.v1.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d['entries'][0]['path']='missing.bin'; json.dump(d,open(p,'w'),sort_keys=True,indent=2); open(p,'a').write('\n')
PY
expect_failure unknown-path 'canonical tuples drift' python3 "$tmp/scripts/generate-model-provenance.py" --root "$tmp" --check

restore_fixture
python3 - "$tmp/docs/security/model-provenance/whisper-5359861c739e955e79d9a303bcbc70fb988958b1-hf-tree.json" <<'PY'
import json, sys
p=sys.argv[1]; d=json.load(open(p)); next(x for x in d if x['path'] == 'ggml-tiny-q5_1.bin')['lfs']['oid']='0'*64; json.dump(d,open(p,'w'),separators=(',',':'))
PY
update_evidence_index whisper-5359861c739e955e79d9a303bcbc70fb988958b1-hf-tree.json
expect_failure evidence-lfs-oid 'LFS pointer Git blob mismatch' python3 "$tmp/scripts/generate-model-provenance.py" --root "$tmp" --check

restore_fixture
python3 - "$tmp/Config/ModelProvenance/model-provenance.v1.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d['entries'][0]['sha256']='ABC'; json.dump(d,open(p,'w'),sort_keys=True,indent=2); open(p,'a').write('\n')
PY
expect_failure malformed-digest 'sha256 must be lowercase 64-hex' python3 "$tmp/scripts/generate-model-provenance.py" --root "$tmp" --check

restore_fixture
printf '\n// drift\n' >> "$tmp/MacTalk/MacTalk/Whisper/GeneratedModelProvenance.swift"
expect_failure generated-drift 'generated provenance drift' python3 "$tmp/scripts/generate-model-provenance.py" --root "$tmp" --check

restore_fixture
printf 'x' >> "$tmp/docs/security/model-provenance/parakeet_vocab.json"
update_evidence_index parakeet_vocab.json
expect_failure vocabulary-sha 'regular evidence size mismatch' python3 "$tmp/scripts/generate-model-provenance.py" --root "$tmp" --check

# Negative fixtures for the Task-1 review blockers. These fail closed when
# compiled LFS entries, regular-file bytes, or the evidence index drift.
restore_fixture
python3 - "$tmp/docs/security/model-provenance/parakeet-aed02740059203c4a87495924f685de3722ae9ce-hf-tree-001.json" <<'PY'
import json, sys
p=sys.argv[1]; d=json.load(open(p)); item=next(x for x in d if x['path'] == 'Decoder.mlmodelc/weights/weight.bin'); item['lfs']['oid']='0'*64; json.dump(d,open(p,'w'),separators=(',',':'))
PY
update_evidence_index parakeet-aed02740059203c4a87495924f685de3722ae9ce-hf-tree-001.json
expect_failure compiled-lfs-oid 'LFS pointer Git blob mismatch' python3 "$tmp/scripts/generate-model-provenance.py" --root "$tmp" --check

restore_fixture
printf 'byte drift' >> "$tmp/docs/security/model-provenance/parakeet-compiled-regular-files-aed02740059203c4a87495924f685de3722ae9ce/Decoder.mlmodelc/metadata.json"
update_evidence_index parakeet-aed02740059203c4a87495924f685de3722ae9ce-hf-tree-001.json
expect_failure compiled-regular-bytes 'regular evidence size mismatch' python3 "$tmp/scripts/generate-model-provenance.py" --root "$tmp" --check

restore_fixture
python3 - "$tmp/docs/security/model-provenance/parakeet-aed02740059203c4a87495924f685de3722ae9ce-hf-tree-001.json" <<'PY'
import json, sys
p=sys.argv[1]; d=json.load(open(p)); item=next(x for x in d if x['path'] == 'Decoder.mlmodelc/metadata.json'); item['oid']='0'*40; json.dump(d,open(p,'w'),separators=(',',':'))
PY
update_evidence_index parakeet-aed02740059203c4a87495924f685de3722ae9ce-hf-tree-001.json
expect_failure compiled-regular-git-blob 'regular evidence Git blob mismatch' python3 "$tmp/scripts/generate-model-provenance.py" --root "$tmp" --check

restore_fixture
python3 - "$tmp/docs/security/model-provenance/evidence-index.v1.json" <<'PY'
import json, sys
p=sys.argv[1]; d=json.load(open(p)); d['files'][0]['sha256']='0'*64; json.dump(d,open(p,'w'),separators=(',',':'))
PY
expect_failure evidence-index-digest python3 "$tmp/scripts/generate-model-provenance.py" --root "$tmp" --check

# The nested LFS record is not enough: its exact pointer bytes must hash to the
# outer Git blob OID. These four fixtures deliberately keep the canonical
# tuples/generated output coherent wherever the tuple would otherwise change.
restore_fixture
nested_oid_evidence="$tmp/docs/security/model-provenance/parakeet-aed02740059203c4a87495924f685de3722ae9ce-hf-tree-002.json"
nested_oid_original=$(python3 - "$nested_oid_evidence" <<'PY'
import json, sys
item=next(x for x in json.load(open(sys.argv[1])) if x['path']=='mlpackages/Preprocessor.mlpackage/Data/com.apple.CoreML/model.mlmodel')
print(item['oid'])
PY
)
python3 - "$nested_oid_evidence" <<'PY'
import hashlib, json, sys
p=sys.argv[1]
d=json.load(open(p))
target='mlpackages/Preprocessor.mlpackage/Data/com.apple.CoreML/model.mlmodel'
item=next(x for x in d if x['path'] == target)
item['lfs']['oid']='1'*64
lfs=item['lfs']
pointer=(f"version https://git-lfs.github.com/spec/v1\noid sha256:{lfs['oid']}\nsize {lfs['size']}\n").encode('ascii')
item['oid']=hashlib.sha1(f"blob {len(pointer)}\0".encode('ascii')+pointer).hexdigest()
json.dump(d, open(p, 'w'), separators=(',', ':'))
PY
update_evidence_index parakeet-aed02740059203c4a87495924f685de3722ae9ce-hf-tree-002.json
update_canonical_entry_and_generated 'mlpackages/Preprocessor.mlpackage/Data/com.apple.CoreML/model.mlmodel' "$(python3 - "$nested_oid_evidence" <<'PY'
import json, sys
item=next(x for x in json.load(open(sys.argv[1])) if x['path']=='mlpackages/Preprocessor.mlpackage/Data/com.apple.CoreML/model.mlmodel'); print(item['lfs']['size'])
PY
)" "$(python3 - "$nested_oid_evidence" <<'PY'
import json, sys
item=next(x for x in json.load(open(sys.argv[1])) if x['path']=='mlpackages/Preprocessor.mlpackage/Data/com.apple.CoreML/model.mlmodel'); print(item['lfs']['oid'])
PY
)"
python3 - "$nested_oid_evidence" "$nested_oid_original" <<'PY'
import json, sys
p, original = sys.argv[1:]
d=json.load(open(p)); item=next(x for x in d if x['path']=='mlpackages/Preprocessor.mlpackage/Data/com.apple.CoreML/model.mlmodel'); item['oid']=original
json.dump(d, open(p, 'w'), separators=(',', ':'))
PY
update_evidence_index parakeet-aed02740059203c4a87495924f685de3722ae9ce-hf-tree-002.json
expect_failure nested-lfs-oid 'LFS pointer Git blob mismatch' python3 "$tmp/scripts/generate-model-provenance.py" --root "$tmp" --check

restore_fixture
nested_size_evidence="$tmp/docs/security/model-provenance/parakeet-aed02740059203c4a87495924f685de3722ae9ce-hf-tree-002.json"
nested_size_original=$(python3 - "$nested_size_evidence" <<'PY'
import json, sys
item=next(x for x in json.load(open(sys.argv[1])) if x['path']=='mlpackages/Preprocessor.mlpackage/Data/com.apple.CoreML/model.mlmodel')
print(item['oid'], item['lfs']['pointerSize'])
PY
)
nested_size_original_oid=${nested_size_original%% *}
nested_size_original_pointer=${nested_size_original##* }
python3 - "$nested_size_evidence" <<'PY'
import hashlib, json, sys
p=sys.argv[1]
d=json.load(open(p))
target='mlpackages/Preprocessor.mlpackage/Data/com.apple.CoreML/model.mlmodel'
item=next(x for x in d if x['path'] == target)
item['lfs']['size'] += 1
item['size'] = item['lfs']['size']
lfs=item['lfs']
pointer=(f"version https://git-lfs.github.com/spec/v1\noid sha256:{lfs['oid']}\nsize {lfs['size']}\n").encode('ascii')
lfs['pointerSize']=len(pointer)
item['oid']=hashlib.sha1(f"blob {len(pointer)}\0".encode('ascii')+pointer).hexdigest()
json.dump(d, open(p, 'w'), separators=(',', ':'))
PY
update_evidence_index parakeet-aed02740059203c4a87495924f685de3722ae9ce-hf-tree-002.json
update_canonical_entry_and_generated 'mlpackages/Preprocessor.mlpackage/Data/com.apple.CoreML/model.mlmodel' "$(python3 - "$nested_size_evidence" <<'PY'
import json, sys
item=next(x for x in json.load(open(sys.argv[1])) if x['path']=='mlpackages/Preprocessor.mlpackage/Data/com.apple.CoreML/model.mlmodel'); print(item['lfs']['size'])
PY
)" "$(python3 - "$nested_size_evidence" <<'PY'
import json, sys
item=next(x for x in json.load(open(sys.argv[1])) if x['path']=='mlpackages/Preprocessor.mlpackage/Data/com.apple.CoreML/model.mlmodel'); print(item['lfs']['oid'])
PY
)"
python3 - "$nested_size_evidence" "$nested_size_original_oid" "$nested_size_original_pointer" <<'PY'
import json, sys
p, original_oid, original_pointer = sys.argv[1:]
d=json.load(open(p)); item=next(x for x in d if x['path']=='mlpackages/Preprocessor.mlpackage/Data/com.apple.CoreML/model.mlmodel'); item['oid']=original_oid; item['lfs']['pointerSize']=int(original_pointer)
json.dump(d, open(p, 'w'), separators=(',', ':'))
PY
update_evidence_index parakeet-aed02740059203c4a87495924f685de3722ae9ce-hf-tree-002.json
expect_failure nested-lfs-size 'LFS pointer Git blob mismatch' python3 "$tmp/scripts/generate-model-provenance.py" --root "$tmp" --check

restore_fixture
python3 - "$tmp/docs/security/model-provenance/parakeet-aed02740059203c4a87495924f685de3722ae9ce-hf-tree-002.json" <<'PY'
import json, sys
p=sys.argv[1]
d=json.load(open(p))
target='mlpackages/Preprocessor.mlpackage/Data/com.apple.CoreML/model.mlmodel'
item=next(x for x in d if x['path'] == target)
item['lfs']['pointerSize'] += 1
json.dump(d, open(p, 'w'), separators=(',', ':'))
PY
update_evidence_index parakeet-aed02740059203c4a87495924f685de3722ae9ce-hf-tree-002.json
expect_failure nested-pointer-size 'LFS pointer size mismatch' python3 "$tmp/scripts/generate-model-provenance.py" --root "$tmp" --check

restore_fixture
python3 - "$tmp/docs/security/model-provenance/parakeet-aed02740059203c4a87495924f685de3722ae9ce-hf-tree-002.json" <<'PY'
import json, sys
p=sys.argv[1]
d=json.load(open(p))
target='mlpackages/Preprocessor.mlpackage/Data/com.apple.CoreML/model.mlmodel'
item=next(x for x in d if x['path'] == target)
item['oid']='0'*40
json.dump(d, open(p, 'w'), separators=(',', ':'))
PY
update_evidence_index parakeet-aed02740059203c4a87495924f685de3722ae9ce-hf-tree-002.json
expect_failure outer-git-oid 'LFS pointer Git blob mismatch' python3 "$tmp/scripts/generate-model-provenance.py" --root "$tmp" --check

echo 'model provenance generation tests passed'
