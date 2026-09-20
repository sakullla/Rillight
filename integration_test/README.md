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

## Session memory/disk cache validation (2026-09-20)

The production backend now disables mpv's append-only disk cache. HTTP playback
starts with conservative packet/time budgets; a stable media response or ended
HLS media playlist upgrades those budgets. Explicit transcoding and infinite
streams stay conservative. Proxy hotspot/pending limits are 32/4 MiB for stable
content and 8/2 MiB for conservative content; mpv uses 64/16 MiB forward/backward
and 120 seconds, or 32/10 MiB and 10 seconds respectively. These limits describe
cache data, not the process RSS. Disk quotas use the existing setting snapshot
(default 2048 MiB); conservative sessions target at most 64 MiB. Protected reads
can temporarily retain the previous budget after a downgrade; diagnostics expose
the target and pending convergence, and release triggers eviction.

Stable socket fragments are forwarded immediately and aggregated into blocks of
at most 1 MiB (256 KiB for conservative content). This avoids exhausting 8192
file/index slots on 64 KiB socket fragments. Metadata and read-protection files
also consume quota/slots. No next-episode fetch, offline download or cross-session
reuse is added. The new `session-v1` root does not delete unowned legacy mpv files.

### Reproduce transport and storage measurements

```sh
dart run tool/player_cache_benchmark.dart
dart run tool/player_cache_benchmark.dart --protection-only
flutter test test/player/cache/session_byte_cache_test.dart
flutter test test/player/playback_http_proxy_cases.dart
```

The benchmark alternates passthrough and cache modes five times for each scenario,
uses deterministic bytes and verifies every returned byte. It writes `raw.jsonl`,
`summary.json` and `large-protection.json` under a fresh
`build/player-validation/cache-benchmark-*` directory. To force both disk reads
and eviction quickly, HTTP cases use 256 KiB of hotspot memory, a 2/4 MiB disk
quota, and 1 MiB repeat reads; the fault case repeats 256 KiB. The limited source
waits 12 ms per 64 KiB chunk; actual wall-clock delays depend on host scheduling.
The outage scenario returns HTTP 503 after initial loading. These are transport
measurements, not decoded first-frame, physical network or hardware video results.

Executed complete run: `cache-benchmark-1789911781121` (60 HTTP cases plus the
64 MiB storage probe). Repeat-read times in milliseconds, median [min, max]:

| Scenario | Passthrough | Cache | Repeat upstream requests, passthrough/cache |
| --- | --- | --- | --- |
| Stable | 34 [33, 43] | 25 [22, 29] | 1 / 0 |
| Limited | 450 [390, 496] | 27 [21, 86] | 1 / 0 |
| Source unavailable | failed 5/5 | 26 [21, 120], success 5/5 | 1 / 0 |
| Over quota, old range evicted | 32 [31, 36] | 46 [41, 127] | 1 / 1 |
| Limited + old range evicted | 392 [267, 405] | 394 [378, 475] | 1 / 1 |
| Disk unavailable, memory hit | 8 [7, 20] | 2 [2, 2] | 1 / 0 |

Fresh hits transferred zero repeat upstream body bytes. Evicted 1 MiB ranges
transferred exactly 1 MiB in one streaming request. Before the full-miss fallback,
the developmental benchmark (`1789911049920`) split evicted ranges into small
validated gap requests and measured 74 ms versus 35 ms passthrough. The fallback
removes that request amplification; cache bookkeeping/refilling still costs time
on a fast loopback source. Partial hits continue to fetch only validated gaps.
Initial 1 MiB reads in the final run were 39/50 ms (stable) and 341/436 ms
(limited), passthrough/cache medians. Do not claim uniformly faster cold starts.

All HTTP pressure iterations remained below the 2 MiB physical quota; the maximum
observed footprint was 1,835,067 bytes. Hotspot peaks stayed at 262,144 bytes;
the maximum sum of recorded proxy and store pending peaks was 1,966,080 bytes.
Those component peaks need not occur simultaneously. Sampled RSS includes the
Dart VM, synthetic origin and previous benchmark trials; it is not a player RSS
limit or an isolated memory attribution.

The final 64 MiB disk-only probe used 64 one-MiB blocks with the unchanged 750 ms
per-operation deadline: protection 111 ms, complete checked read 716 ms, no
degradation and complete cleanup. Five additional isolated probes in
`cache-benchmark-1789911743353` recorded protection 40/31/30/28/28 ms and complete
reads 1172/737/723/712/760 ms. A whole-range time can exceed 750 ms because that
deadline applies to each disk operation. Protection verifies file identities and
lengths; each actual read verifies CRC32. CRC32 uses a table with the same stored
checksum format, covered by a known-vector and corruption regression.

The storage suite exercises real competing processes, quota snapshots, corrupted
blocks, lock timeout, abandoned sessions and 8192-file pressure. On the Linux
development copy, the original 8191-file one-byte protection took about 930 ms
and degraded; per-operation inventory reuse reduced it to about 683 ms, followed
by a roughly 5 ms hot read. A 64 MiB protection previously timed out, then took
about 30 ms after removing duplicate whole-range CRC work. These are individual
Docker/local-volume diagnostic samples, not hardware performance statistics.
At extreme file counts, close may return `cleanup=pending` after 750 ms; owned
late cleanup or subsequent abandoned-session recovery must finish it.

### Windows native observations

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tool/player_smoke.ps1 -Runs 5
```

The original `f3cf8f8` baseline passed five runs: `20260920-194609-572`,
`194702-753`, `194741-395`, `194819-055`, `194903-127` (same date prefix).
Its `baseline-loaded.openMs` values were 756/641/572/1003/635: median 641 ms,
range 572–1003 ms. The cache candidate passed `20260920-213138-045`,
`213215-414`, `213256-795`, `213343-542`, `213420-668`: 624/903/628/590/551,
median 624 ms, range 551–903 ms. All had zero dropped frames at that initial
observation. These overlapping ranges do not establish a cold-start improvement.
`openMs` starts after the controller is available and waits for loaded/advancing
playback; it is not end-to-end click-to-first-frame latency.

After the full-miss adjustment, additional run `20260920-214455-072` passed
(initial observation 602 ms). Its synthetic source actively returned 503 while
already-buffered playback advanced 900 ms; user pause remained paused. After
recovery, seeking to 3 seconds reached an advancing position in 350 ms, which
is a position-event measurement, not displayed-frame latency. Stop/dispose
diagnostics reported complete cache cleanup and no degradation. The ordinary
production entrypoint is restored by the script. Native control, track/subtitle,
multi-codec and wake-lock assertions remain included. Core subtitle screenshots
still do not prove Flutter texture presentation, physical audio or GPU stability.

### Remaining evidence limits

An earlier benchmark (`cache-benchmark-1789911537885`) completed its 60 HTTP
cases but failed on a subsequent protected 64 MiB read returning unavailable
while the native smoke was also running. That failure lacked offset/degradation
details; no corruption, timeout or budget root cause is established. Five isolated
probes and a later complete benchmark passed, which does not explain the earlier
failure. The benchmark now emits offset, budget/degradation and physical-block
diagnostics on recurrence. One initial Windows killed-process recovery test saw
three directories instead of two; subsequent targeted and module runs passed,
but the first transient also remains unexplained.

The first added native outage test (`20260920-213842-591`) failed because its
control POST used chunked transfer while the fixture reads Content-Length, so
the outage was never enabled. The harness now sets Content-Length; the subsequent
native run both observed 503 and verified buffered playback/pause.

The Owner's isolated Linux development copy passed 95 related cases, then passed
all 44 backend/proxy cases after the final unknown-length classification change
(including its additional regression). The Linux smoke target built and its
32-ELF/runtime checks passed. The actual-window candidate smoke failed: the child
exited before capture and the main process timed out (`app=1`, `capture=1`).
Evidence is in `build/player-validation/cache-linux-candidate/`, including
`result.json` and `capture.log`. Original baseline attempts also had child
exits/timeouts, but a shared root cause has not been established.

The native package also had an existing surface-failure cleanup expectation
mismatch (`native_core_test.dart`, create/dispose vs create/detach/dispose).
No Linux actual-window playback success or macOS native result is claimed by
these measurements. Final production Linux build and full-suite results remain
separate delivery checks; a successful build cannot substitute for failed
actual-window evidence.
