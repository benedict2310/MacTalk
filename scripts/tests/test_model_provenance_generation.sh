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
  if "$@" >"$tmp/$label.out" 2>&1; then
    echo "negative provenance fixture unexpectedly passed: $label" >&2
    cat "$tmp/$label.out" >&2
    exit 1
  fi
}

# Canonical tuple, evidence size/OID, path-set, immutable-reference, digest,
# generated-output, and vocabulary identity checks must all fail closed.
restore_fixture
python3 - "$tmp/Config/ModelProvenance/model-provenance.v1.json" <<'PY'
import json, sys
p=sys.argv[1]; d=json.load(open(p)); d['entries'][0]['sha256']='0'*64; json.dump(d,open(p,'w'),sort_keys=True,indent=2); open(p,'a').write('\n')
PY
expect_failure canonical-drift python3 "$tmp/scripts/generate-model-provenance.py" --root "$tmp" --check

restore_fixture
python3 - "$tmp/docs/security/model-provenance/whisper-5359861c739e955e79d9a303bcbc70fb988958b1-hf-tree.json" <<'PY'
import json, sys
p=sys.argv[1]; d=json.load(open(p)); next(x for x in d if x['path'] == 'ggml-tiny-q5_1.bin')['size'] += 1; json.dump(d,open(p,'w'),separators=(',',':'))
PY
expect_failure evidence-size python3 "$tmp/scripts/generate-model-provenance.py" --root "$tmp" --check

restore_fixture
python3 - "$tmp/docs/security/model-provenance/parakeet-aed02740059203c4a87495924f685de3722ae9ce-hf-tree-001.json" <<'PY'
import json, sys
p=sys.argv[1]; d=json.load(open(p)); d.append(d[0]); json.dump(d,open(p,'w'),separators=(',',':'))
PY
expect_failure duplicate-evidence python3 "$tmp/scripts/generate-model-provenance.py" --root "$tmp" --check

restore_fixture
python3 - "$tmp/Config/ModelProvenance/model-provenance.v1.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d['entries'][0]['path']='missing.bin'; json.dump(d,open(p,'w'),sort_keys=True,indent=2); open(p,'a').write('\n')
PY
expect_failure unknown-path python3 "$tmp/scripts/generate-model-provenance.py" --root "$tmp" --check

restore_fixture
python3 - "$tmp/Config/ModelProvenance/model-provenance.v1.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d['repositories']['whisper']['revision']='main'; json.dump(d,open(p,'w'),sort_keys=True,indent=2); open(p,'a').write('\n')
PY
expect_failure mutable-ref python3 "$tmp/scripts/generate-model-provenance.py" --root "$tmp" --check

restore_fixture
python3 - "$tmp/Config/ModelProvenance/model-provenance.v1.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d['entries'][0]['sha256']='ABC'; json.dump(d,open(p,'w'),sort_keys=True,indent=2); open(p,'a').write('\n')
PY
expect_failure malformed-digest python3 "$tmp/scripts/generate-model-provenance.py" --root "$tmp" --check

restore_fixture
printf '\n// drift\n' >> "$tmp/MacTalk/MacTalk/Whisper/GeneratedModelProvenance.swift"
expect_failure generated-drift python3 "$tmp/scripts/generate-model-provenance.py" --root "$tmp" --check

restore_fixture
printf 'x' >> "$tmp/docs/security/model-provenance/parakeet_vocab.json"
expect_failure vocabulary-sha python3 "$tmp/scripts/generate-model-provenance.py" --root "$tmp" --check

# Negative fixtures for the Task-1 review blockers. These fail closed when
# compiled LFS entries, regular-file bytes, or the evidence index drift.
restore_fixture
python3 - "$tmp/docs/security/model-provenance/parakeet-aed02740059203c4a87495924f685de3722ae9ce-hf-tree-001.json" <<'PY'
import json, sys
p=sys.argv[1]; d=json.load(open(p)); item=next(x for x in d if x['path'] == 'Decoder.mlmodelc/weights/weight.bin'); item['lfs']['oid']='0'*64; json.dump(d,open(p,'w'),separators=(',',':'))
PY
expect_failure compiled-lfs-oid python3 "$tmp/scripts/generate-model-provenance.py" --root "$tmp" --check

restore_fixture
printf 'byte drift' >> "$tmp/docs/security/model-provenance/parakeet-compiled-regular-files-aed02740059203c4a87495924f685de3722ae9ce/Decoder.mlmodelc/metadata.json"
expect_failure compiled-regular-bytes python3 "$tmp/scripts/generate-model-provenance.py" --root "$tmp" --check

restore_fixture
python3 - "$tmp/docs/security/model-provenance/parakeet-aed02740059203c4a87495924f685de3722ae9ce-hf-tree-001.json" <<'PY'
import json, sys
p=sys.argv[1]; d=json.load(open(p)); item=next(x for x in d if x['path'] == 'Decoder.mlmodelc/metadata.json'); item['oid']='0'*40; json.dump(d,open(p,'w'),separators=(',',':'))
PY
expect_failure compiled-regular-git-blob python3 "$tmp/scripts/generate-model-provenance.py" --root "$tmp" --check

restore_fixture
python3 - "$tmp/docs/security/model-provenance/evidence-index.v1.json" <<'PY'
import json, sys
p=sys.argv[1]; d=json.load(open(p)); d['files'][0]['sha256']='0'*64; json.dump(d,open(p,'w'),separators=(',',':'))
PY
expect_failure evidence-index-digest python3 "$tmp/scripts/generate-model-provenance.py" --root "$tmp" --check

echo 'model provenance generation tests passed'
