#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/../.."

python3 - <<'PY'
from pathlib import Path
project = Path('project.yml').read_text()
entitlements = Path('MacTalk/MacTalk/MacTalk.entitlements').read_text()
assert 'ENABLE_HARDENED_RUNTIME: YES' in project, 'hardened runtime is not enabled in project.yml'
assert 'CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO' in project, 'debug base entitlements must not be injected into releases'
assert 'ENABLE_HARDENED_RUNTIME = YES' in Path('MacTalk.xcodeproj/project.pbxproj').read_text(), 'generated project is stale'
for forbidden in ('com.apple.security.cs.allow-jit', 'com.apple.security.cs.allow-unsigned-executable-memory', 'com.apple.security.device.camera'):
    assert forbidden not in entitlements, f'unjustified entitlement remains: {forbidden}'
for required in ('com.apple.security.device.audio-input', 'com.apple.security.automation.apple-events', 'com.apple.security.cs.disable-library-validation'):
    assert required in entitlements, f'required entitlement missing: {required}'
PY

fixture="$(mktemp -d "${TMPDIR:-/tmp}/mactalk-signing.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
app="$fixture/MacTalk.app"
mkdir -p "$app/Contents/Frameworks" "$app/Contents/MacOS" "$fixture/bin"
touch "$app/Contents/Frameworks/libwhisper.dylib" "$app/Contents/MacOS/MacTalk"

cat > "$fixture/bin/codesign" <<'FAKE_CODESIGN'
#!/bin/bash
set -eu
printf '%s\n' "$*" >> "${FAKE_LOG}"
path="${@: -1}"
if [[ " $* " == *" --verify "* ]]; then
  [[ "${FAKE_UNSIGNED:-0}" != 1 ]]
  exit $?
fi
if [[ " $* " == *" --entitlements :- "* ]]; then
  if [[ "${FAKE_MISSING_ENTITLEMENT:-0}" == 1 ]]; then
    cat >&2 <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>com.apple.security.device.audio-input</key><true/></dict></plist>
PLIST
  else
    cat >&2 <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>com.apple.security.device.audio-input</key><true/><key>com.apple.security.automation.apple-events</key><true/><key>com.apple.security.cs.disable-library-validation</key><true/></dict></plist>
PLIST
  fi
  exit 0
fi
team="${FAKE_TEAM_ID:-TEAM123}"
if [[ "$path" == *.dylib ]]; then
  team="${FAKE_NESTED_TEAM:-$team}"
fi
printf 'Executable=%s\nIdentifier=com.mactalk.app\nTeamIdentifier=%s\nAuthority=Developer ID Application: Fixture (%s)\n' "$path" "$team" "$team" >&2
if [[ "${FAKE_NO_RUNTIME:-0}" != 1 ]]; then
  echo 'CodeDirectory flags=0x10000(runtime)' >&2
fi
FAKE_CODESIGN
chmod +x "$fixture/bin/codesign"
cat > "$fixture/bin/security" <<'FAKE_SECURITY'
#!/bin/bash
set -eu
if [[ "${FAKE_NO_CREDENTIALS:-0}" == 1 ]]; then
  echo '0 identities found' >&2
  exit 0
fi
echo '  1) ABCD "Developer ID Application: Fixture (TEAM123)"'
echo '     1 valid identities found'
FAKE_SECURITY
chmod +x "$fixture/bin/security"
cat > "$fixture/bin/spctl" <<'FAKE_SPCTL'
#!/bin/bash
set -eu
if [[ "${FAKE_GATEKEEPER_REJECT:-0}" == 1 ]]; then
  echo 'source=Unnotarized Developer ID' >&2
  exit 1
fi
echo 'accepted' >&2
FAKE_SPCTL
chmod +x "$fixture/bin/spctl"

export PATH="$fixture/bin:$PATH"
export FAKE_LOG="$fixture/calls.log"
export SIGNING_IDENTITY='Developer ID Application: Fixture (TEAM123)'
export SIGNING_TEAM_ID=TEAM123

run_expect() {
  expected="$1"
  shift
  set +e
  "$@"
  actual=$?
  set -e
  [[ "$actual" == "$expected" ]] || { echo "expected exit $expected, got $actual" >&2; exit 1; }
}

run_expect 0 scripts/verify-signing.sh "$app"
grep -q -- '--deep --strict' "$fixture/calls.log"
FAKE_CODESIGN_LOG="$fixture/calls.log"

FAKE_TEAM_ID=OTHERTEAM run_expect 3 scripts/verify-signing.sh "$app"
FAKE_TEAM_ID=TEAM123 FAKE_NESTED_TEAM=OTHERTEAM run_expect 3 scripts/verify-signing.sh "$app"
FAKE_TEAM_ID=TEAM123 FAKE_NO_RUNTIME=1 run_expect 3 scripts/verify-signing.sh "$app"
FAKE_TEAM_ID=TEAM123 FAKE_MISSING_ENTITLEMENT=1 run_expect 3 scripts/verify-signing.sh "$app"
FAKE_MISSING_ENTITLEMENT=0 FAKE_UNSIGNED=1 run_expect 3 scripts/verify-signing.sh "$app"
FAKE_UNSIGNED=0 FAKE_NO_CREDENTIALS=1 run_expect 2 scripts/verify-signing.sh "$app"
FAKE_NO_CREDENTIALS=0 FAKE_GATEKEEPER_REJECT=1 run_expect 4 scripts/verify-signing.sh "$app"

echo 'verify-signing fixture tests passed'
