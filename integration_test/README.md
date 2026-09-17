# Native desktop playback validation

Run `powershell -NoProfile -ExecutionPolicy Bypass -File tool/player_smoke.ps1`
on Windows. The release-mode wrapper in `tool/player_smoke.dart` invokes the
production `lib/main.dart` entry in both main and player processes and drives the
actual page/controller/native texture. It is not part of `flutter test`'s widget
subset and is never packaged by the release workflow.

The synthetic loopback Emby server, media generation and isolated credentials,
settings and cache need no personal server. Evidence goes to
`build/player-validation/runs/`. Set `RILLIGHT_SMOKE_HOLD_SECONDS=5` to pause each
loaded video for visual inspection. Automated diagnostics cannot prove audible
sound, absence of flicker, or end-to-end display latency; inspect the actual
window and audio device. The script restores the ordinary release entrypoint.

The harness also exports `pgs-core.png`, `ass-core.png`, `srt-core.png`,
`vtt-core.png` and `ssa-core.png` with libmpv's `screenshot-to-file` command in
`subtitles` mode. These verify the core's subtitle composition, independently
of Flutter window capture. The JSONL records include playback position and
subtitle state for each image.

The platform CI and `tool/linux_release_checks.py` provide Ubuntu package
installation, desktop launch and missing-library diagnostics. These are
separate from the Windows runtime checks.

Validation recorded on 2026-09-18:

- Windows run `build/player-validation/runs/20260917-235603-642/` passed;
  all five core subtitle PNGs were visually checked. The ordinary
  `lib/main.dart` release build was restored successfully afterward.
- Docker Ubuntu 22.04 completed the production build, deb packaging and all
  ELF checks, loading mpv 0.41.0 with a pinned scaler-padding patch, FFmpeg 9.0.1
  and client API 2.5. Ubuntu 24.04 desktop launch, shutdown and missing-library
  dialogs passed, including the visible diagnostic text through AT-SPI.
  `linux/packaging/playback_smoke.sh` passed the real main/child playback path,
  subtitles, seek, switching, close/reopen, four-codec moving window pixels and
  a matching PulseAudio stream. Xvfb software Mesa and a virtual sink were used;
  1080p/4K playback had substantial frame drops, so real-time hardware throughput
  and physical audio output are not established.
- macOS has no local native result. The new PR/main macOS build/bundle CI has
  not yet run. Hardware GPU behavior, end-to-end audio/display timing and the
  historical flicker still need separate evidence; package or core-image
  checks cannot establish those outcomes.
