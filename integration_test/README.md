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

## Danmaku redo validation (2026-09-19)

This section records the danmaku redo (ADR-8). It does not change the native
playback facts above. No DevTools timeline, CPU trace, or `debugGlyphCacheSize`
log was found under `build/`, `docs/`, or `integration_test/`; frame times,
cache peaks, and pause CPU figures are therefore not reported.

### Automated tests (executed in T1–T6; not hardware)

Unit/widget coverage via `flutter test` on the `*_cases.dart` modules listed
below. These assert layout, timeline, parse, controller, renderer hooks, panel,
and settings invariants. They are not 1080p profile measurements.

| Area | Modules | What they cover |
| --- | --- | --- |
| Settings / density | `test/player/danmaku/danmaku_settings_cases.dart`, `danmaku_layout_cases.dart` | Full-field JSON, old-field snap, density vs lanes (T1) |
| Timeline / load | `danmaku_timeline_cases.dart`, `dandanplay_client_cases.dart`, `danmaku_controller_cases.dart` | Filter/merge/offset, isolate parse ≥256 KiB, session cache, `refreshFromStore` (T2) |
| Layout | `danmaku_layout_cases.dart` | Overlap, density, fontPx, resize, follow-rate lifespan (T3) |
| Renderer | `danmaku_renderer_cases.dart` | `debugLayoutCallsDuringTick == 0` after warmup, ticker pause, split layers, glyph-cache generation (T4) |
| Player panel | `test/player/player_controls_cases.dart` | 1280×720 basic row, status, keywords, unconfigured guide (T5) |
| Settings page | `test/settings_page_cases.dart` | Display section writes `danmakuDisplay` only (T6) |

T1–T6 task-runs record those module-level `flutter test` commands as passed.
This task did not re-run them. `flutter test` remains the configured full-suite
command; it is still not a hardware result.

### Windows real-machine profile — configured / not executed

Intended command and environment (not run in this workflow):

```sh
flutter run --profile -d windows
```

Open Flutter DevTools on that profile session. Checklist:

- 1080p window
- 10k-level comment load
- 100+ on-screen scroll comments
- DevTools frame time vs the display refresh period
- `DanmakuViewState.debugGlyphCacheSize` peak (code LRU cap is 6000)
- pause: CPU drop toward a no-danmaku idle

No Windows profile session, screenshot, or numeric log exists in-repo for this
redo. Do not treat debug-mode jank as an R6 result.

### Linux Xvfb — functional only; no performance conclusion

ADR-8 allows the existing Xvfb path (`linux/packaging/playback_smoke.sh`) only
as a functional check. That 2026-09-18 run is native playback, not danmaku, and
used software Mesa with substantial 1080p/4K drops. No danmaku functional
screenshot was taken for this redo. Do not infer danmaku frame time from Xvfb.

### macOS — no real-machine result

macOS has no local native or danmaku profile run. Hardware GPU behavior and
R6 metrics are not established there.
