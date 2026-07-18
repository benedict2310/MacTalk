#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GENERATOR="$ROOT/scripts/generate-model-provenance.py"
CANONICAL="$ROOT/Config/ModelProvenance/model-provenance.v1.json"
GENERATED="$ROOT/MacTalk/MacTalk/Whisper/GeneratedModelProvenance.swift"

for path in "$GENERATOR" "$CANONICAL" "$GENERATED"; do
  test -f "$path" || { echo "missing provenance artifact: $path" >&2; exit 1; }
done
python3 "$GENERATOR" --root "$ROOT" --check

tmp="$(mktemp -d "${TMPDIR:-/tmp}/mactalk-provenance-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
cp -R "$ROOT/Config" "$tmp/Config"
cp -R "$ROOT/docs" "$tmp/docs"
cp -R "$ROOT/MacTalk" "$tmp/MacTalk"
cp -R "$ROOT/scripts" "$tmp/scripts"

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
python3 - "$tmp/Config/ModelProvenance/model-provenance.v1.json" <<'PY'
import json, sys
p=sys.argv[1]; d=json.load(open(p)); d['entries'][0]['sha256']='0'*64; json.dump(d,open(p,'w'),sort_keys=True,indent=2); open(p,'a').write('\n')
PY
expect_failure canonical-drift python3 "$tmp/scripts/generate-model-provenance.py" --root "$tmp" --check

cp -R "$ROOT/Config" "$tmp/config-evidence"
cp -R "$tmp/config-evidence" "$tmp/Config"
python3 - "$tmp/docs/security/model-provenance/whisper-5359861c739e955e79d9a303bcbc70fb988958b1-hf-tree.json" <<'PY'
import json, sys
p=sys.argv[1]; d=json.load(open(p)); next(x for x in d if x['path'] == 'ggml-tiny-q5_1.bin')['size'] += 1; json.dump(d,open(p,'w'),separators=(',',':'))
PY
expect_failure evidence-size python3 "$tmp/scripts/generate-model-provenance.py" --root "$tmp" --check

rm -rf "$tmp/Config"; cp -R "$ROOT/Config" "$tmp/Config"
python3 - "$tmp/docs/security/model-provenance/parakeet-*.json" <<'PY'
import glob,json,sys
p=glob.glob(sys.argv[1])[0]; d=json.load(open(p)); d.append(d[0]); json.dump(d,open(p,'w'),separators=(',',':'))
PY
expect_failure duplicate-evidence python3 "$tmp/scripts/generate-model-provenance.py" --root "$tmp" --check

rm -rf "$tmp/Config"; cp -R "$ROOT/Config" "$tmp/Config"
python3 - "$tmp/Config/ModelProvenance/model-provenance.v1.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d['entries'][0]['path']='missing.bin'; json.dump(d,open(p,'w'),sort_keys=True,indent=2); open(p,'a').write('\n')
PY
expect_failure unknown-path python3 "$tmp/scripts/generate-model-provenance.py" --root "$tmp" --check

rm -rf "$tmp/Config"; cp -R "$ROOT/Config" "$tmp/Config"
python3 - "$tmp/Config/ModelProvenance/model-provenance.v1.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d['repositories']['whisper']['revision']='main'; json.dump(d,open(p,'w'),sort_keys=True,indent=2); open(p,'a').write('\n')
PY
expect_failure mutable-ref python3 "$tmp/scripts/generate-model-provenance.py" --root "$tmp" --check

rm -rf "$tmp/Config"; cp -R "$ROOT/Config" "$tmp/Config"
python3 - "$tmp/Config/ModelProvenance/model-provenance.v1.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d['entries'][0]['sha256']='ABC'; json.dump(d,open(p,'w'),sort_keys=True,indent=2); open(p,'a').write('\n')
PY
expect_failure malformed-digest python3 "$tmp/scripts/generate-model-provenance.py" --root "$tmp" --check

rm -rf "$tmp/Config"; cp -R "$ROOT/Config" "$tmp/Config"
printf '\n// drift\n' >> "$tmp/MacTalk/MacTalk/Whisper/GeneratedModelProvenance.swift"
expect_failure generated-drift python3 "$tmp/scripts/generate-model-provenance.py" --root "$tmp" --check

rm -rf "$tmp/Config"; cp -R "$ROOT/Config" "$tmp/Config"
printf 'x' >> "$tmp/docs/security/model-provenance/parakeet_vocab.json"
expect_failure vocabulary-sha python3 "$tmp/scripts/generate-model-provenance.py" --root "$tmp" --check

echo 'model provenance generation tests passed'
