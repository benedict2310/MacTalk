# Opt-in hardware audio validation

This procedure is **not a unit test** and does not claim a hardware pass. It is
an operator-controlled check for production timestamp behavior and application
audio loss handling.

The recorder is disabled unless `MACTALK_AUDIO_HARDWARE_VALIDATION_LOG` is set.
It writes CSV metadata only: microphone host-time, ScreenCaptureKit PTS and its
host-nanosecond mapping, callback arrival uptime, frame counts, and an
`application_loss` event. It never writes audio samples, transcript text, or
model data.

## Procedure

1. Review and authorize microphone and Screen Recording capture on the test
   Mac. Do not run this on a call or with sensitive audio.
2. Ensure the Release signing identity and private key are available. The
   launcher fails closed for unsigned builds.
3. Run, from the repository root:

   ```sh
   MACTALK_HARDWARE_VALIDATION_ACK=I_HAVE_AUTHORIZED_CAPTURE \
     ./scripts/hardware-validation.sh
   ```

   The script builds/verifies a signed Release app and launches its executable
   with metadata logging. It does not download a model. The recorder itself
   never invokes ASR; use only an already prepared local setup for the
   production capture callbacks and do not trigger model preparation during
   this check.
4. Select an app-audio source, start mic+app capture, and produce a known
   acoustic/electronic impulse. Stop capture after several callbacks.
5. Repeat while intentionally stopping or revoking the app-audio stream. The
   resulting CSV must contain `microphone`, `application`, and
   `application_loss` rows. Compare `media_host_ns` between source rows and use
   `arrival_uptime_ns` to inspect callback lateness.
6. Preserve the CSV and signed-bundle identity as test evidence. A reviewer,
   not this script, records pass/fail and device/OS details.

The current repository has no recorded hardware run. A successful build or
CSV generation must not be described as a hardware validation pass.
