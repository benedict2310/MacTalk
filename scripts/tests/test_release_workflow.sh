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
elif [[ "$*" == *'--display --verbose=4'* ]]; then
  printf 'Executable=%s\nTimestamp=Fixture Secure Timestamp\nTeamIdentifier=TEAM123\nAuthority=Developer ID Application: Fixture (TEAM123)\nCodeDirectory flags=0x10000(runtime)\n' "${@: -1}" >&2
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
cp .gitignore "$fixture/work/"
# Leave whisper.cpp unbuilt so the fresh-build path is exercised. Create a
# real nested repository because release provenance records its exact commit.
rm -rf "$fixture/work/Vendor/whisper.cpp/build"
mkdir -p "$fixture/work/Vendor/whisper.cpp"
( cd "$fixture/work/Vendor/whisper.cpp" && git init -q && git config user.email fixture@example.test && git config user.name Fixture && touch README && printf 'build/\n' > .gitignore && git add README .gitignore && git commit -qm whisper )
# Move the fixture to a new, exact-version release tag in detached state.
sed -i.bak 's/MACTALK_MARKETING_VERSION=1.1.3/MACTALK_MARKETING_VERSION=1.1.4/' "$fixture/work/scripts/release-version.env"
rm -f "$fixture/work/scripts/release-version.env.bak"
mkdir -p "$fixture/work/release"
sed -i.bak 's/>1.1.3</>1.1.4</' "$fixture/bin/xcodebuild"
rm -f "$fixture/bin/xcodebuild.bak"
( cd "$fixture/work" && git init -q && git config user.email fixture@example.test && git config user.name Fixture && git add . && git commit -qm fixture && git tag v1.1.4 && git checkout --detach -q v1.1.4 )
export PATH="$fixture/bin:$PATH"
export FAKE_LOG="$log"
export RELEASE_TAG=v1.1.4
export MACTALK_CODE_SIGN_IDENTITY='Developer ID Application: Fixture (TEAM123)'
export MACTALK_DEVELOPMENT_TEAM=TEAM123
export MACTALK_NOTARY_KEYCHAIN_PROFILE=FixtureNotary

# Wrong ref/tag and dirty source fail before any external tool runs.
if RELEASE_TAG=v1.1.3 bash scripts/release-preflight.sh >/dev/null 2>&1; then
  echo 'preflight accepted immutable v1.1.3' >&2; exit 1
fi
if RELEASE_TAG=v1.1.5 bash scripts/release-preflight.sh >/dev/null 2>&1; then
  echo 'preflight accepted a tag different from source version' >&2; exit 1
fi
printf 'dirty source\n' >> scripts/release-version.env
if bash scripts/release-preflight.sh >/dev/null 2>&1; then
  echo 'preflight accepted dirty source' >&2; exit 1
fi
git show HEAD:scripts/release-version.env > scripts/release-version.env

# Missing signing and notarization inputs fail before any external tool runs.
if env -u MACTALK_CODE_SIGN_IDENTITY -u MACTALK_DEVELOPMENT_TEAM bash scripts/archive-release.sh --output-dir "$fixture/work/release/missing" >/dev/null 2>&1; then
  echo 'archive accepted missing signing environment' >&2; exit 1
fi
if env -u MACTALK_NOTARY_KEYCHAIN_PROFILE bash scripts/notarize-release.sh --output-dir "$fixture/work/release/missing" >/dev/null 2>&1; then
  echo 'notarize accepted missing credential environment' >&2; exit 1
fi

# The phase marker prevents DMG/notary work before archive verification.
if bash scripts/notarize-release.sh --output-dir "$fixture/work/release/out" >/dev/null 2>&1; then
  echo 'notarize accepted an unverified archive' >&2; exit 1
fi

( cd "$fixture/work" && xcodegen generate )
( cd "$fixture/work" && mkdir -p Vendor/whisper.cpp/build && touch Vendor/whisper.cpp/build/stale-native-input )
( cd "$fixture/work" && bash scripts/archive-release.sh --output-dir "$fixture/work/release/out" )
test ! -e "$fixture/work/Vendor/whisper.cpp/build/stale-native-input"
printf 'tampered=true\n' >> "$fixture/work/release/out/release-provenance.env"
if ( cd "$fixture/work" && bash scripts/verify-release.sh --output-dir "$fixture/work/release/out" >/dev/null 2>&1 ); then
  echo 'verify accepted tampered phase metadata' >&2; exit 1
fi
( cd "$fixture/work" && bash scripts/archive-release.sh --output-dir "$fixture/work/release/out" )
( cd "$fixture/work" && bash scripts/verify-release.sh --output-dir "$fixture/work/release/out" )
( cd "$fixture/work" && bash scripts/notarize-release.sh --output-dir "$fixture/work/release/out" )

# A failed external gate retains the DMG and emits recovery guidance.
( cd "$fixture/work" && bash scripts/archive-release.sh --output-dir "$fixture/work/release/retry" >/dev/null )
( cd "$fixture/work" && bash scripts/verify-release.sh --output-dir "$fixture/work/release/retry" >/dev/null )
if ! recovery=$(FAKE_NOTARY_FAILURE=1 bash scripts/notarize-release.sh --output-dir "$fixture/work/release/retry" 2>&1); then
  grep -q 'artifacts retained' <<< "$recovery"
  test -n "$(find "$fixture/work/release/retry" -name '*.dmg' -print -quit)"
else
  echo 'notarization failure fixture unexpectedly succeeded' >&2; exit 1
fi

python3 - "$log" "$fixture/work/release/out" <<'PY'
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
manifest = Path(sys.argv[2]) / 'MacTalk-1.1.4-manifest.txt'
text = manifest.read_text()
for key in ('version=1.1.4', 'build=4', 'commit=', 'sha256='):
    if key not in text: raise SystemExit(f'manifest missing {key}')
print('python assertions passed')
PY

echo 'release workflow fixture tests passed'
