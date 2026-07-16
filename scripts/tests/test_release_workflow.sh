#!/bin/bash
# Fixture test for the archive/notarize workflow. Every external release tool is
# replaced with a recorder so this test never signs, uploads, or downloads data.
set -euo pipefail

cd "$(dirname "$0")/../.."

fixture="$(mktemp -d "${TMPDIR:-/tmp}/mactalk-release-test.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/bin" "$fixture/work/Vendor/whisper.cpp/build/src" "$fixture/work/Vendor/whisper.cpp/build/ggml/src" "$fixture/work/Vendor/whisper.cpp/build/ggml/src/ggml-blas" "$fixture/work/Vendor/whisper.cpp/build/ggml/src/ggml-metal"
log="$fixture/tools.log"

cat > "$fixture/bin/xcodegen" <<'TOOL'
#!/bin/bash
printf 'xcodegen %s\n' "$*" >> "$FAKE_LOG"
TOOL
cat > "$fixture/bin/cmake" <<'TOOL'
#!/bin/bash
printf 'cmake %s\n' "$*" >> "$FAKE_LOG"
if [[ "$*" == *'--build'* ]]; then
  mkdir -p "$PWD/src" "$PWD/ggml/src"
  touch "$PWD/src/libwhisper.1.dylib"
fi
TOOL
cat > "$fixture/bin/xcodebuild" <<'TOOL'
#!/bin/bash
printf 'xcodebuild %s\n' "$*" >> "$FAKE_LOG"
archive=''
for arg in "$@"; do
  case "$arg" in
    -archivePath) next=archive;;
    *) if [[ "${next:-}" == archive ]]; then archive="$arg"; unset next; fi;;
  esac
done
mkdir -p "$archive/Products/Applications/MacTalk.app/Contents/Frameworks"
cat > "$archive/Products/Applications/MacTalk.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>1.1.3</string><key>CFBundleVersion</key><string>4</string></dict></plist>
PLIST
touch "$archive/Products/Applications/MacTalk.app/Contents/Frameworks/libwhisper.1.dylib"
TOOL
cat > "$fixture/bin/codesign" <<'TOOL'
#!/bin/bash
printf 'codesign %s\n' "$*" >> "$FAKE_LOG"
if [[ "$*" == *'-dvvv'* ]]; then
  printf 'Executable=%s\nTeamIdentifier=TEAM123\nAuthority=Developer ID Application: Fixture (TEAM123)\nCodeDirectory flags=0x10000(runtime)\n' "${@: -1}" >&2
elif [[ "$*" == *'--entitlements :-'* ]]; then
  cat <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>com.apple.security.device.audio-input</key><true/><key>com.apple.security.automation.apple-events</key><true/></dict></plist>
PLIST
fi
exit 0
TOOL
cat > "$fixture/bin/security" <<'TOOL'
#!/bin/bash
printf 'security %s\n' "$*" >> "$FAKE_LOG"
echo '  1) ABCD "Developer ID Application: Fixture (TEAM123)"'
TOOL
cat > "$fixture/bin/spctl" <<'TOOL'
#!/bin/bash
printf 'spctl %s\n' "$*" >> "$FAKE_LOG"
TOOL
cat > "$fixture/bin/hdiutil" <<'TOOL'
#!/bin/bash
printf 'hdiutil %s\n' "$*" >> "$FAKE_LOG"
touch "${@: -1}"
TOOL
cat > "$fixture/bin/xcrun" <<'TOOL'
#!/bin/bash
printf 'xcrun %s\n' "$*" >> "$FAKE_LOG"
if [[ "${FAKE_NOTARY_FAILURE:-0}" == 1 && "$1" == notarytool ]]; then exit 42; fi
TOOL
cat > "$fixture/bin/gh" <<'TOOL'
#!/bin/bash
printf 'gh %s\n' "$*" >> "$FAKE_LOG"
exit 99
TOOL
chmod +x "$fixture/bin"/*

# The test fixture uses a copied, minimal source tree and a fake project so no
# real Xcode project, certificate, keychain, or whisper model is touched.
cp -R scripts "$fixture/work/"
cp -R MacTalk "$fixture/work/"
cp project.yml "$fixture/work/"
# Leave whisper.cpp unbuilt so the clean-clone path is exercised.
rm -rf "$fixture/work/Vendor/whisper.cpp/build"
mkdir -p "$fixture/work/Vendor/whisper.cpp"
# Give the isolated fixture a source commit for the manifest.
( cd "$fixture/work" && git init -q && git config user.email fixture@example.test && git config user.name Fixture && git add . && git commit -qm fixture )
export PATH="$fixture/bin:$PATH"
export FAKE_LOG="$log"
export MACTALK_CODE_SIGN_IDENTITY='Developer ID Application: Fixture (TEAM123)'
export MACTALK_DEVELOPMENT_TEAM=TEAM123
export MACTALK_NOTARY_KEYCHAIN_PROFILE=FixtureNotary

# Missing signing and notarization inputs fail before any external tool runs.
if env -u MACTALK_CODE_SIGN_IDENTITY -u MACTALK_DEVELOPMENT_TEAM bash scripts/archive-release.sh --output-dir "$fixture/missing" >/dev/null 2>&1; then
  echo 'archive accepted missing signing environment' >&2; exit 1
fi
if env -u MACTALK_NOTARY_KEYCHAIN_PROFILE bash scripts/notarize-release.sh --output-dir "$fixture/missing" >/dev/null 2>&1; then
  echo 'notarize accepted missing credential environment' >&2; exit 1
fi

# The phase marker prevents DMG/notary work before archive verification.
if bash scripts/notarize-release.sh --output-dir "$fixture/out" >/dev/null 2>&1; then
  echo 'notarize accepted an unverified archive' >&2; exit 1
fi

( cd "$fixture/work" && xcodegen generate )
( cd "$fixture/work" && bash scripts/archive-release.sh --output-dir "$fixture/out" )
( cd "$fixture/work" && bash scripts/verify-release.sh --output-dir "$fixture/out" )
( cd "$fixture/work" && bash scripts/notarize-release.sh --output-dir "$fixture/out" )

# A failed external gate retains the DMG and emits recovery guidance.
( cd "$fixture/work" && bash scripts/archive-release.sh --output-dir "$fixture/retry" >/dev/null )
( cd "$fixture/work" && bash scripts/verify-release.sh --output-dir "$fixture/retry" >/dev/null )
if ! recovery=$(FAKE_NOTARY_FAILURE=1 bash scripts/notarize-release.sh --output-dir "$fixture/retry" 2>&1); then
  grep -q 'artifacts retained' <<< "$recovery"
  test -f "$fixture/retry/MacTalk-1.1.3.dmg"
else
  echo 'notarization failure fixture unexpectedly succeeded' >&2; exit 1
fi

python3 - "$log" "$fixture/out" <<'PY'
from pathlib import Path
import sys
log = Path(sys.argv[1]).read_text().splitlines()
need = ['xcodebuild archive', 'codesign --verify', 'hdiutil create', 'xcrun notarytool submit', 'xcrun stapler staple', 'spctl --assess']
positions = []
for needle in need:
    for i, line in enumerate(log):
        if needle in line:
            positions.append(i); break
    else:
        raise SystemExit(f'missing tool call: {needle}')
if positions != sorted(positions):
    raise SystemExit(f'phase order is not monotonic: {positions}')
if any(line.startswith('gh ') for line in log):
    raise SystemExit('local release scripts must not invoke gh or create a release')
manifest = Path(sys.argv[2]) / 'MacTalk-1.1.3-manifest.txt'
text = manifest.read_text()
for key in ('version=1.1.3', 'build=4', 'commit=', 'sha256='):
    if key not in text: raise SystemExit(f'manifest missing {key}')
PY

echo 'release workflow fixture tests passed'
