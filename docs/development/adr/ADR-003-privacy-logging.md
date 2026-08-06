# ADR-003: Privacy-preserving diagnostics

- **Status:** Accepted
- **Date:** 2026-07-18

## Decision

Diagnostics are opt-in in Debug builds through `MACTALK_DEBUG_LOGGING=1` or
`--mactalk-debug-logging`; Release `DebugLogger` calls are compiled out. The
logger renders event names and character counts, not transcript text or error
descriptions. File logs are written under `~/Library/Logs/MacTalk/debug.log`
with a private directory/file mode. Deterministic tests inject sinks and assert
that transcript/error values do not appear.

Model download is deliberately separate: URLSession is used only by explicit
model provisioning paths, and catalog SHA-256 verification occurs before
installation. Therefore local transcription and absence of cloud ASR are not
claims that the application contains no network code.

## Consequences

- Debug logs must not become a transcript or clipboard export channel.
- Existing lifecycle `print` statements are visible diagnostics and are not a
  privacy audit; future sensitive diagnostics must use the redacting logger.
- Unit tests use a network trap and never contact model providers.

Evidence: `DebugLogger.swift`, `ModelDownloader.swift`,
`ParakeetModelDownloader.swift`, and `MacTalkTests/PrivacyLoggingTests.swift`.
