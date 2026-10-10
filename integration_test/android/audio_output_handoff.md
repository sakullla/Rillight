# Android TV audio output fixes — 2026-10-10

Working-tree changes based on `e415dfa75dd9517a8d91622e4f48f5e0cdaf1d09`
(v0.1.54). This is development evidence, not release or hardware acceptance.

## Confirmed defects and changes

- Ordinary E-AC-3 used native format ID 3, but Android only mapped IDs 1 and 2.
  Compressed bytes could therefore reach a PCM AudioTrack. Map every known
  native format explicitly and reject unknown formats or untimed compressed
  frames so the core can decode PCM.
- Recognize ordinary E-AC-3 independently of JOC/Atmos and check the active
  route before accepting compressed output. Clear the rejected format's own
  capability bit and retain that rejection on the same route.
- Pass the source output sample rate across JNI rather than assuming 48 kHz.
  Update the JNI constructor, R8 retention rule and APK audit together.
- Use AudioTimestamp to account for hardware presentation latency beyond the
  PCM consumed-frame counter, with bounded timestamp validation and fallback.
  The core can hold its monotonic clock while delayed audio catches up, instead
  of retaining the initial video lead forever.
- Sync staged SDK libraries to the selected ABIs so a previous build cannot
  leave stale native libraries in a single-ABI APK.

## Target-device observations

Device: Box_R_4K_Plus / SEI804HM, Android 14, 32-bit armeabi-v7a, HDMI to a TV
using its built-in speakers. Tests used the disposable `.validation` package
and synthetic local media; no production credentials were copied.

Before the mapping fix, switching to E-AC-3 created a PCM output whose server
frame count did not advance. The test build opened E-AC-3 as `0x0a000000` and
consumed its queue. AAC, AC-3, E-AC-3, DTS, TrueHD, FLAC, PCM and Opus synthetic
clips completed the first control/progress matrix, including AAC → E-AC-3 →
AAC and seek. That run established control/queue progress, **not physical sound**.
Its first output-status capture used the wrong diagnostic endpoint; null clock
fields from that run must not be interpreted as clock results.

A subsequent PCM test reported an active hardware clock, roughly 140 ms of
hardware delay and no underruns. This establishes use of the presentation
timestamp, not measured lip-sync accuracy.

The user heard DTS when decoded to PCM in the comparison test. That experiment
used 1.01x speed to select the existing PCM path. Raw DTS passthrough was silent
at the same test volume, as was an independent IEC 61937 test using FFmpeg's
SPDIF muxer. Successful AudioTrack writes did not establish audible output.
The vendor log reported DTS-HD output during the raw DTS experiment, but this
alone does not prove the cause of silence. DTS investigation was deferred by
the user. The final change retains Android's previous decoded-PCM policy for
DTS/DTS-HD; the experimental automatic DTS passthrough path is not enabled.
No new PCM preference or test playback rate was added to the product.

The user then powered off the TV and box. Physical E-AC-3/AC-3/TrueHD output,
lip-sync, real JOC and DTS-HD media remain unverified. The final policy change
has not been rerun on the powered-off device. The production installation was
not replaced with a locally signed test package.

## Regression evidence and follow-up

- Native core CTest: 11/11 passed, including delayed presentation-clock recovery.
- Android Kotlin unit tests: 70/70 passed, including encoding, route rejection,
  sample rates, timestamp outage/reset/wrap and hardware-delay accounting.
- Android APK checker Python tests: 36/36 passed.
- Flutter playback-backend and Android seek-cancellation regressions: 22/22 passed.
- Local release-mode validation APK: JNI/R8 and armv7 dependency audit passed.
- Local artifacts, synthetic media and logs: ignored `build/tv-av-sync/`.

On the next hardware session, use a newly built validation package to check
normal-speed E-AC-3 5.1 → AAC → E-AC-3, pause/resume, seek and next episode.
Record actual sound separately from queue progress. Check lip-sync with a
known synchronized flash/click fixture and ordinary dialogue. Leave DTS-specific
investigation deferred unless requested again. No version/tag publication is
part of this fix task.
