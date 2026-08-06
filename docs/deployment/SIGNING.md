# MacTalk signing and Gatekeeper

MacTalk uses the hardened runtime (`ENABLE_HARDENED_RUNTIME: YES`) for every
configuration. The release entitlement allowlist is exact and contains only:

- `com.apple.security.device.audio-input` (`true`) for `AVAudioEngine`
  microphone input.
- `com.apple.security.automation.apple-events` (`true`) for the user-requested
  accessibility/Apple Events auto-paste path.

The Metal, Whisper, and Parakeet paths run with library validation enabled and
have no evidence requiring JIT, unsigned-executable-memory, or other
entitlements. The verifier rejects any source or signed entitlement outside
this allowlist (and rejects incorrect values).

## Local development

An Apple Development identity may be used for local debugging, but a local
build is not a distributable release. Ad-hoc (`-`) or unsigned builds are
useful for CI/unit tests and cannot pass signing verification or Gatekeeper.
For a signed local build, set the identity without putting credentials in the
repository:

```bash
MACTALK_CODE_SIGN_IDENTITY='Apple Development: Name (TEAM_ID)' ./build.sh run
```

## Developer ID verification

A Developer ID Application certificate **and its private key** must be
installed in the login keychain. The configured identity and team can be
overridden without editing source:

```bash
security find-identity -v -p codesigning
MACTALK_CODE_SIGN_IDENTITY='Developer ID Application: Name (TEAM_ID)' \
MACTALK_DEVELOPMENT_TEAM='TEAM_ID' ./build.sh
SIGNING_IDENTITY='Developer ID Application: Name (TEAM_ID)' \
SIGNING_TEAM_ID='TEAM_ID' scripts/verify-signing.sh \
  "$HOME/Library/Developer/Xcode/DerivedData/MacTalk-*/Build/Products/Release/MacTalk.app"
```

`verify-signing.sh` checks the Developer ID authority and Team ID for the app
and every nested Whisper/ggml dylib, hardened-runtime flags, exact approved
entitlements, `codesign --verify --deep --strict`, and `spctl`. Exit status 2
means signing credentials are unavailable; status 3 means an unsigned or
invalid bundle (including a non-notarization Gatekeeper rejection); status 4
means Gatekeeper identified a valid Developer ID app as **Unnotarized Developer
ID**.

## Notarization prerequisites

Notarization is deliberately not run by the local build. Distribution also
requires an Apple Developer account, a signed archive/DMG, and notarization
credentials (an App Store Connect API key or a `notarytool` keychain profile).
Submit with `xcrun notarytool`, wait for acceptance, staple the ticket with
`xcrun stapler`, and then rerun `spctl`. Never commit or print passwords,
private keys, API keys, or keychain-profile contents.

Before notarization/stapling, Gatekeeper may reject a correctly Developer ID
signed app as unnotarized. That is expected and is reported separately by the
verifier; it is not evidence that the nested signatures or entitlements are
wrong. No model download is part of signing or verification.
