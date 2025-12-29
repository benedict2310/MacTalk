# Parakeet UX - Story Index

**Epic:** Parakeet Integration & Real-Time Streaming UX
**Last Updated:** 2025-12-23

---

## Overview

This directory contains implementation stories for integrating Parakeet (FluidAudio's Core ML-based ASR) and building a real-time streaming transcription UX that rivals commercial dictation solutions.

This README is the **epic overview**. Every `S.03.x` document in this folder is an **implementation story** (except the completed investigation spike, which is explicitly labeled as such).

---

## Story Status & Dependencies

```
┌─────────────────────────────────────────────────────────────────┐
│                    FOUNDATION LAYER                             │
├─────────────────────────────────────────────────────────────────┤
│  S.03.0 Foundation Recovery  ───────────┐                       │
│  [CRITICAL - Recover stashed code]      │                       │
│                                         ▼                       │
│  S.03.0 Streaming Investigation   (DONE)                        │
│  [Spike - FluidAudio API review]                                │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                    STREAMING CORE                               │
├─────────────────────────────────────────────────────────────────┤
│  S.03.1a Streaming Infrastructure  ◄────────────────────────────┤
│  [Ring buffer, hop timer, diffing]                              │
│                              │                                  │
│                              ▼                                  │
│  S.03.1b VAD Integration  ◄─────────┬───────────────────────────┤
│  [Energy VAD, barge-in detection]   │                           │
│                              │                                  │
│                              ▼                                  │
│  S.03.1 Streaming UX Integration   [HUD/caption text] ✅ DONE   │
└─────────────────────────────────────┼───────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────┐
│                    ENHANCED FEATURES                            │
├─────────────────────────────────────────────────────────────────┤
│  S.03.1c Voice Commands         S.03.1d Caption Strip           │
│  [Hotword detection]            [Window pinning]                │
│                                                                 │
│  S.03.1e Minutes Pad            S.03.1f Paste Safety            │
│  [Background buffer]            [App blacklist]                 │
│  (Independent)                  (Depends: S.03.3)               │
└─────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────┐
│                    PERMISSIONS INFRASTRUCTURE                   │
├─────────────────────────────────────────────────────────────────┤
│  S.03.3 Accessibility Permissions  [CRITICAL - Foundational]   │
│  [Permission flow, auto-insert, polling, diagnostics]          │
└─────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────┐
│                    POLISH & INTELLIGENCE                        │
├─────────────────────────────────────────────────────────────────┤
│  S.03.1g Language Auto-Detect   S.03.1h Rolling Summaries       │
│  [Multi-language UX]            [LLM integration]               │
└─────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────┐
│                         DIARIZATION                             │
├─────────────────────────────────────────────────────────────────┤
│  S.03.2 Diarization Core        [shared models + alignment]     │
│                              │                                  │
│                 ┌────────────┴────────────┐                     │
│  S.03.2a Batch Diarization   S.03.2b Live Diarization            │
│  [Offline speaker ID]        [Real-time speaker ID]             │
└─────────────────────────────────────────────────────────────────┘
```

---

## Story Summary

| Story | Title | Priority | Status | Dependencies |
|-------|-------|----------|--------|--------------|
| **S.03.0** | [Foundation Recovery](S.03.0-FOUNDATION-RECOVERY.md) | CRITICAL | Ready | S.02.3 (Swift 6) |
| **S.03.0** | [Streaming API Investigation](S.03.0-STREAMING-API-INVESTIGATION.md) | N/A | **DONE** | None |
| **S.03.1** | [Streaming UX Integration](S.03.1-LOW-LATENCY-STREAMING-UX.md) | High | **Implemented** | S.03.1a, S.03.1b |
| **S.03.1a** | [Streaming Infrastructure](S.03.1a-STREAMING-INFRASTRUCTURE.md) | Critical | Ready | S.03.0-RECOVERY |
| **S.03.1b** | [VAD Integration](S.03.1b-VAD-INTEGRATION.md) | High | Ready | S.03.1a |
| **S.03.1c** | [Voice Commands](S.03.1c-VOICE-COMMANDS.md) | Medium | Draft | S.03.1a |
| **S.03.1d** | [Caption Strip](S.03.1d-CAPTION-STRIP.md) | Medium | Draft | S.03.1a |
| **S.03.1e** | [Minutes Pad](S.03.1e-MINUTES-PAD.md) | Medium | Draft | S.01.2 |
| **S.03.1f** | [Paste Safety](S.03.1f-PASTE-SAFETY.md) | Medium | Draft | S.01.2 |
| **S.03.1g** | [Language Auto-Detect](S.03.1g-LANGUAGE-AUTODETECT-UX.md) | Low | Draft | S.03.1a |
| **S.03.1h** | [Rolling Summaries](S.03.1h-ROLLING-SUMMARIES.md) | Low | Draft | S.03.1a |
| **S.03.2** | [Diarization Core](S.03.2-SPEAKER-DIARIZATION.md) | Medium | Draft | S.01.2 |
| **S.03.2a** | [Batch Diarization](S.03.2a-BATCH-DIARIZATION.md) | Low | Draft | S.03.2 |
| **S.03.2b** | [Live Diarization](S.03.2b-LIVE-DIARIZATION.md) | Low | Draft | S.03.2, S.03.1a |
| **S.03.3** | [Accessibility Permissions](S.03.3-ACCESSIBILITY-PERMISSIONS.md) | Critical | Ready | None |

---

## Recommended Implementation Order

### Phase 1: Foundation (MUST DO FIRST)

1. **S.03.0-FOUNDATION-RECOVERY** - Recover stashed Parakeet implementation
   - Unblock all other Parakeet work
   - Migrate to Swift 6 strict concurrency

### Phase 2: Core Streaming

2. **S.03.1a** - Streaming Infrastructure
   - Ring buffer, hop timer, partial diffing

3. **S.03.1b** - VAD Integration
   - Energy-based VAD for CPU savings
   - Barge-in detection

4. ~~**S.03.1** - Streaming UX Integration~~ ✅ **DONE**
   - HUD/caption partials and finalization UX

### Phase 3: Permissions & Enhanced Features

5. **S.03.3** - Accessibility Permissions (CRITICAL - blocks paste features)
   - PermissionsActor for thread-safe checks
   - Auto-insert with AX SetValue + Cmd+V fallback
   - Permission polling & deep-link to Settings
   - Settings UI fix for live status display

6. **S.03.1e** - Minutes Pad (can run in parallel)
7. **S.03.1f** - Paste Safety (depends on S.03.3)
8. **S.03.1c** - Voice Commands
9. **S.03.1d** - Caption Strip

### Phase 4: Polish

10. **S.03.1g** - Language Auto-Detect UX
11. **S.03.1h** - Rolling Summaries
12. **S.03.2** - Diarization Core
13. **S.03.2a/b** - Speaker Diarization

---

## Key Technical Decisions

### 1. Streaming Approach: Rolling Window
FluidAudio doesn't expose native streaming until v0.7.10+. We use a **rolling-window** approach:
- 10-12s context window
- 320-640ms hop interval
- Text diffing for stable partials

**Rationale:** Full control over behavior, proven pattern used by other macOS dictation apps.

### 2. VAD: Energy-Based (with FluidAudio option)
Start with simple energy-based VAD (low latency). FluidAudio's Silero VAD available if needed.

### 3. Swift 6 Compliance
All code must be Swift 6 strict concurrency compliant:
- `@unchecked Sendable` with manual locks
- `@MainActor` for UI callbacks
- Thread Sanitizer validation

### 4. Apple HIG Compliance
Follow Apple Human Interface Guidelines for:
- Progress indicators (spinning vs determinate)
- Menu bar extras
- Settings UI patterns

---

## Performance Targets

| Metric | Target | Notes |
|--------|--------|-------|
| Partial latency | <400ms | From speech to HUD |
| Final latency | <300ms | After speech pause |
| CPU (M1, active) | <30% | During transcription |
| CPU (M1, idle) | <5% | VAD only |
| Memory growth | <50MB/hour | Long session stability |

---

## References

- **FluidAudio SDK:** https://github.com/FluidInference/FluidAudio
- **Parakeet Model:** https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml
- **Apple HIG:** [MODEL-SELECTION-UX-BEST-PRACTICES.md](../design/MODEL-SELECTION-UX-BEST-PRACTICES.md)
- **Swift 6 Migration:** [S.02.0-MIGRATION-STRATEGY.md](../02-SWIFT-6/S.02.0-MIGRATION-STRATEGY.md)

---

## Git Safety Reminder

**ALWAYS COMMIT, NEVER STASH:**
- Per CLAUDE.md git safety rules, always commit work to a branch
- Never use `git stash` for implementation work
- The S.03.0-FOUNDATION-RECOVERY story exists because of a previous stash incident
