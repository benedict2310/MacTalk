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
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>1.1.5</string><key>CFBundleVersion</key><string>6</string></dict></plist>
PLIST
touch "$archive/Products/Applications/MacTalk.app/Contents/Frameworks/libwhisper.1.dylib"
chmod 0751 "$archive/Products/Applications/MacTalk.app/Contents/Frameworks/libwhisper.1.dylib"
ln -s libwhisper.1.dylib "$archive/Products/Applications/MacTalk.app/Contents/Frameworks/libwhisper-link.dylib"
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
cat > "$fixture/bin/ditto" <<'TOOL'
#!/bin/bash
set -euo pipefail
printf 'ditto %s\n' "$*" >> "$FAKE_LOG"
if [[ "${1:-}" == -c ]]; then
  source="${@: -2:1}"; archive="${@: -1}"
  source="${source%/.}"
  tar -czf "$archive" -C "$source" .
elif [[ "${1:-}" == -x ]]; then
  archive="${@: -2:1}"; destination="${@: -1}"
  mkdir -p "$destination"
  tar -xzf "$archive" -C "$destination"
else
  source="${@: -2:1}"; destination="${@: -1}"
  if [[ -d "$source" ]]; then mkdir -p "$destination"; cp -a "$source/." "$destination/"; else cp -a "$source" "$destination"; fi
fi
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
cat > "$fixture/work/scripts/release-version.env" <<'VERSION'
MACTALK_MARKETING_VERSION=1.1.5
MACTALK_BUILD_NUMBER=6
VERSION
mkdir -p "$fixture/work/release"
( cd "$fixture/work" && git init -q && git config user.email fixture@example.test && git config user.name Fixture && git add . && git commit -qm fixture && git tag v1.1.5 && git checkout --detach -q v1.1.5 )
(
  cd "$fixture/work"
  git switch -q -c reserved-v1.1.4
  sed -i '' -e 's/MACTALK_MARKETING_VERSION=1.1.5/MACTALK_MARKETING_VERSION=1.1.4/' \
    -e 's/MACTALK_BUILD_NUMBER=6/MACTALK_BUILD_NUMBER=5/' scripts/release-version.env
  git add scripts/release-version.env
  git commit -qm 'reserved v1.1.4 fixture'
  git tag v1.1.4
  git checkout --detach -q v1.1.4
  if RELEASE_TAG=v1.1.4 bash scripts/release-preflight.sh >/dev/null 2>&1; then
    echo 'preflight accepted reserved v1.1.4' >&2; exit 1
  fi
  git checkout --detach -q v1.1.5
)
export PATH="$fixture/bin:$PATH"
export FAKE_LOG="$log"
export RELEASE_TAG=v1.1.5
export MACTALK_CODE_SIGN_IDENTITY='Developer ID Application: Fixture (TEAM123)'
export MACTALK_DEVELOPMENT_TEAM=TEAM123
export MACTALK_NOTARY_KEYCHAIN_PROFILE=FixtureNotary

# Wrong ref/tag, dirty source, missing inputs, and phase violations are all
# exercised inside the fixture repository; this test must never mutate its source checkout.
(
  cd "$fixture/work"
  if RELEASE_TAG=v1.1.3 bash scripts/release-preflight.sh >/dev/null 2>&1; then
    echo 'preflight accepted immutable v1.1.3' >&2; exit 1
  fi
  if RELEASE_TAG=v1.1.6 bash scripts/release-preflight.sh >/dev/null 2>&1; then
    echo 'preflight accepted a tag different from source version' >&2; exit 1
  fi
  printf 'dirty source\n' >> scripts/release-version.env
  if bash scripts/release-preflight.sh >/dev/null 2>&1; then
    echo 'preflight accepted dirty source' >&2; exit 1
  fi
  git show HEAD:scripts/release-version.env > scripts/release-version.env

  if env -u MACTALK_CODE_SIGN_IDENTITY -u MACTALK_DEVELOPMENT_TEAM bash scripts/archive-release.sh --output-dir "$fixture/work/release/missing" >/dev/null 2>&1; then
    echo 'archive accepted missing signing environment' >&2; exit 1
  fi
  if env -u MACTALK_NOTARY_KEYCHAIN_PROFILE bash scripts/notarize-release.sh --output-dir "$fixture/work/release/missing" >/dev/null 2>&1; then
    echo 'notarize accepted missing credential environment' >&2; exit 1
  fi

  if bash scripts/notarize-release.sh --output-dir "$fixture/work/release/out" >/dev/null 2>&1; then
    echo 'notarize accepted an unverified archive' >&2; exit 1
  fi
)

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
# The handoff is a real archive boundary: metadata, modes, and symlinks survive.
mkdir -p "$fixture/work/release/received"
# The consumer receives a fresh directory and has no producer signing identity
# or phase-marker assumptions. The original ZIP and sidecar remain outside it
# and are passed explicitly into the notarization command.
env -u MACTALK_CODE_SIGN_IDENTITY -u MACTALK_NOTARY_KEYCHAIN_PROFILE \
  bash "$fixture/work/scripts/reverify-handoff.sh" \
  --handoff "$fixture/work/release/out/MacTalk-release-handoff.zip" \
  --handoff-sha256 "$fixture/work/release/out/MacTalk-release-handoff.zip.sha256" \
  --received-dir "$fixture/work/release/received" --phase verified
test -L "$fixture/work/release/received/MacTalk.xcarchive/Products/Applications/MacTalk.app/Contents/Frameworks/libwhisper-link.dylib"
test "$(stat -f '%Lp' "$fixture/work/release/received/MacTalk.xcarchive/Products/Applications/MacTalk.app/Contents/Frameworks/libwhisper.1.dylib")" = 751
test -f "$fixture/work/release/received/release-provenance.env"
cp "$fixture/work/release/out/MacTalk-release-handoff.zip.sha256" "$fixture/work/release/bad-sidecar"
sed -i.bak 's/MacTalk-release-handoff.zip/not-the-original.zip/' "$fixture/work/release/bad-sidecar"
rm -f "$fixture/work/release/bad-sidecar.bak"
if bash "$fixture/work/scripts/reverify-handoff.sh" \
  --handoff "$fixture/work/release/out/MacTalk-release-handoff.zip" \
  --handoff-sha256 "$fixture/work/release/bad-sidecar" \
  --received-dir "$fixture/work/release/bad-received" --phase verified >/dev/null 2>&1; then
  echo 'consumer accepted a sidecar naming another container' >&2; exit 1
fi
if bash "$fixture/work/scripts/reverify-handoff.sh" \
  --handoff "$fixture/work/release/out/MacTalk-release-handoff.zip" \
  --handoff-sha256 "$fixture/work/release/out/MacTalk-release-handoff.zip.sha256" \
  --received-dir "$fixture/work/release/bad-phase" --phase archive >/dev/null 2>&1; then
  echo 'consumer accepted a non-verified phase' >&2; exit 1
fi
( cd "$fixture/work" && bash scripts/notarize-release.sh \
  --output-dir "$fixture/work/release/received" \
  --handoff "$fixture/work/release/out/MacTalk-release-handoff.zip" \
  --handoff-sha256 "$fixture/work/release/out/MacTalk-release-handoff.zip.sha256" )

# A failed external gate retains the DMG and emits recovery guidance.
( cd "$fixture/work" && bash scripts/archive-release.sh --output-dir "$fixture/work/release/retry" >/dev/null )
( cd "$fixture/work" && bash scripts/verify-release.sh --output-dir "$fixture/work/release/retry" >/dev/null )
if ! recovery=$(FAKE_NOTARY_FAILURE=1 bash scripts/notarize-release.sh --output-dir "$fixture/work/release/retry" 2>&1); then
  grep -Eq 'artifacts retained|provenance source commit mismatch' <<< "$recovery"
  if grep -q 'artifacts retained' <<< "$recovery"; then
    test -n "$(find "$fixture/work/release/retry" -name '*.dmg' -print -quit)"
  fi
else
  echo 'notarization failure fixture unexpectedly succeeded' >&2; exit 1
fi

python3 - "$log" "$fixture/work/release/received" <<'PY'
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
manifest = Path(sys.argv[2]) / 'MacTalk-1.1.5-manifest.txt'
text = manifest.read_text()
for key in ('version=1.1.5', 'build=6', 'commit=', 'sha256='):
    if key not in text: raise SystemExit(f'manifest missing {key}')
print('python assertions passed')
PY

echo 'release workflow fixture tests passed'
