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
Only the trusted OS temporary base is canonicalized before appending that
namespace, so system aliases such as macOS `/var` remain usable. Links in either
`rillight-player-cache` or `session-v1` are still rejected; regression tests verify
disk hits and owned cleanup through a linked system base, and memory fallback
without modifying a linked cache target.

Upstream throughput counts response bytes delivered by Dart's HTTP client.
Requests prefer identity encoding; if an upstream nevertheless sends gzip,
automatic decompression means the counter measures decoded response body bytes,
not encoded wire bytes. Such compressed bodies bypass the byte-range cache;
local memory/disk hits remain excluded from the network counter.

### Reproduce transport and storage measurements

```sh
dart run tool/player_cache_benchmark.dart
dart run tool/player_cache_benchmark.dart --protection-only
flutter test test/player/cache/session_byte_cache_test.dart
flutter test test/player/playback_http_proxy_cases.dart
```

Filesystem/process pressure checks are deliberately outside automatic `flutter
test` discovery. Run them explicitly, with the player closed:

```powershell
pwsh -NoProfile -File tool/player_cache_stress.ps1
```

The wrapper invokes `flutter test tool/player_cache_stress.dart` (also usable
directly on other platforms). It refuses to run alongside Rillight unless
`-AllowRunningPlayer` is explicitly provided. These ten checks cover thousands
of files, killed processes, competing writers and deliberately blocked disk
queues. Small storage/HTTP regressions remain in the normal suite; benchmarks
and pressure checks are not invoked by that suite.

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

### Linux X11 process-exit fix — 2026-09-20

The current-source pre-fix reproduction is preserved in
`build/player-validation/linux-current-20260920-222900/` (app and capture both
failed). The diagnostic `linux-exit-stack.trace` locates the child exit in
GDK's fatal X IO handler, reached through XGetGeometry/GLX presentation;
`linux-xio-debug/app.stdout.log` records errno 11 (EAGAIN). These paths are
under `build/player-validation/`. A startup GDB trace with breakpoints on both
XInitThreads and XOpenDisplay (`linux-before-xinit.log`) first stops in GTK's
XOpenDisplay: Xlib threading was not initialized before opening the display.
The runner now initializes it before creating the GTK application. The
corresponding `linux-after-xinit.log` stops in main's XInitThreads first and
only then GTK's XOpenDisplay. This fixes the reproduced XIO early exit in the
tested X11 path; it is not a diagnosis of every historical flicker report.
XInitThreads does not open a display or force GTK to select X11 over Wayland.

The first fixed run (`linux-current-20260920-223300/`) passed all four actual
window/color/motion and virtual-audio checks, then failed the new outage test.
Its resumed position was already 2000 ms and mpv reported 9.633 seconds of
buffered data, but the test started measuring before confirming clock progress.
The original failure did not record the exact before/after position; it must
not be presented as a measured cache starvation event. The outage test now
first requires 500 ms of real progression and more than three seconds of
buffer, then retains its original 900 ms outage / at least 500 ms progression
assertion. Initial loaded/openMs measurements and all window thresholds remain
unchanged. It now records before/after positions even when the assertion fails.

The complete subsequent run in `build/player-validation/linux-window-progress/`
passed: main/child control, H.264/HEVC/AV1/VP9 changing colored window frames,
virtual audio output, subtitles, seek, media switching, replay/restart, failed
open, repeated disposal and parent-confirmed child shutdown. The synthetic
upstream returned 503 while playback advanced 900 ms; user pause remained
preserved. The five core subtitle PNGs were visually inspected (PGS's synthetic
white bitmap and text for ASS/SRT/VTT/SSA); these are separate from the Flutter
window captures. Both production and smoke builds passed their 32-ELF/runtime
checks. The real bundled Linux libmpv package suite passed 45 tests; the changed
native-core tests also passed all eight cases on Windows with real libmpv.
The cleanup tests now explicitly choose the host desktop target, rather than
Flutter test's default Android target, retaining Linux's detach/dispose checks.

The complete current-source wrapper was then rerun successfully in
`build/player-validation/linux-current-20260920-224037/`: production build,
32-ELF audit, 45 real-libmpv package tests, smoke build, a second 32-ELF audit,
and actual-window smoke all passed. `source.json` identifies the archived
working-tree snapshot based on `88f7d2639632177bc3e14a32f87019506167d375`;
`sdk.log`, `compiler.log`, `cmake.log`, `os-release.log` and
`native-versions.json` record Flutter 3.47.4, Clang 14, CMake 3.22.1, Ubuntu
22.04.5 and the actual mpv 0.41.0 / FFmpeg 9.0.1 / client API 2.5. Compiler,
OS and native-version metadata were collected alongside that run; the wrapper
now collects those metadata automatically on future runs.

Repeat from current source with `tool/linux_playback_validation.ps1 -Container
rillight-cache-validation-20260920` (see `linux/packaging/README.md`). This local
environment is Docker Ubuntu 22.04, Xvfb/software Mesa and a virtual PulseAudio
sink. It does not establish Ubuntu 24.04 installation results for this change,
Wayland runtime behavior, physical audio, hardware decode/GPU stability,
real-time 1080p/4K performance or macOS playback. Those remain distinct checks.

### Windows HTTP tail-probe regression (2026-09-20)

A real remote Matroska resume failed after file-loaded, before first frame:
two long-lived HTTP responses occupied the proxy's two response-lifetime slots,
while a required tail/index range waited for a slot until the 45-second open
timeout. A local HTTP regression reproduces the deadlock without credentials.
The proxy now separates bounded transport concurrency from nonblocking cache
workspace reservations; cache pressure bypasses cache work rather than queuing
an index probe behind an open media body. Overload fails promptly, and cancelled
transports release both connection capacity and workspace.

The same remote item and resume point then played in the Windows debug native
child: loading cleared, position advanced from 723.640 to 800.341 seconds, and
no playback error occurred during that observation. A later repeat also played;
one intervening attempt failed loading item information before backend creation.
Temporary diagnostics contained only byte ranges, lengths, status and policy
flags (no media URLs or credentials), and were removed from production code.

That upstream returns `Cache-Control: no-store`; the initial 62 disk bytes were
session metadata, not video. The user subsequently explicitly requested temporary
disk buffering for this source. The backend now opts into playback-only session
storage, retaining validation before reuse even if max-age is present. Generic
proxy users still respect no-store unless explicitly opted in. Unknown Vary,
keys, subtitles and manifests remain excluded. A native Windows repeat wrote
371,236,265 physical bytes across 358 session files; playback advanced from
723.640 to 798.840 seconds without an error or disk degradation. Proxy memory
stayed within 32 MiB. This verifies writing, not real-source disk reuse: observed
diskHitBytes remained zero, and that intermediate version had no independent
forward prefetcher. It was not accepted as a working hybrid read-ahead cache.

A second local regression found that repeated HttpResponse.add/flush calls can
continue after a downstream broken pipe, downloading all 32 MiB of an abandoned
response. Streaming the body with a single addStream propagates cancellation;
the same test now verifies upstream download stops below 8 MiB. This change is
covered by local tests, separately from the earlier native observation.
Dedicated tests verify opt-in no-store disk hits, changed-validator rejection,
upstream-speed exclusion and close cleanup. Linux/macOS native windows have not
been rerun for these changes; earlier platform smoke results are separate.

### Session read-ahead and seek revalidation follow-up (2026-09-21)

The playback backend now opts into a bounded, single-producer sliding window
for stable, strongly validated HTTP range media. It feeds mpv from the same
memory/disk store that the producer fills, even while mpv stops reading at its
short packet-buffer limit. The window is at most 512 MiB and half the session's
disk allowance. Transfers are at most 4 MiB, published as at most 1 MiB blocks;
producer workspace participates in the existing proxy budget. HLS, dynamic,
unvalidated, unsupported-range and unavailable-disk sources retain their bounded
ordinary transport path. Cache readers now wait for an in-flight disk publication
if another read evicts its RAM copy, instead of orphaning the pending disk block.

Real seek diagnostics found two false invalidations: this source can return 502
to HEAD while GET works, and signed CDN redirect URLs rotate while the strong
ETag is unchanged. Playback-only session buffering now verifies a one-byte
conditional GET before accepting such revalidation. It verifies the strong ETag,
total length, response range, encoding and storage policy for the original sealed
resource, without sending credentials to another origin. Changed content still
invalidates the representation; a changed signed location alone does not.

With these validation fixes, a Windows native forward seek to 1000 seconds and
backward seek to 740 seconds increased diskHitBytes from 4,521,984 to 20,905,984
and then 34,078,720; invalidations stayed zero and playback continued. Downloads
also continued for independent forward prefetch, so these samples must not be
reported as zero-network measurements. Concurrent filesystem tests caused one
disk-timeout degradation in this intermediate 256 KiB-block run; later native
checks are separated from pressure scripts, and the producer uses fewer 1 MiB
files. Tiny HTTP regressions separately assert that cached seek targets do not
download their media bytes again (a one-byte validation probe may be needed).

Temporary on-screen cache-size/status labels were removed at the user's request.
The UI retains network speed and mpv's timestamp-based buffer bar; arbitrary
cached byte ranges are not converted into invented buffered timestamps. Cache
occupancy, disk-hit counts, read-ahead state and validation failures are available
only through backend diagnostics. No diagnostic logging is added to production.

Final Windows native check (without concurrent pressure scripts): the current
1 MiB-block producer reached 362,758,138 physical disk bytes in 348 files, then
stopped prefetching; memory peaked at 33,554,432 bytes. From that warmed session,
a seek to 1000 seconds increased disk-hit bytes by 5,308,416 and upstream bytes
by exactly 1. A following seek back to 740 seconds increased disk-hit bytes by
5,373,952 and upstream bytes by exactly 1. These two upstream bytes were content
validation probes, not re-downloaded video bodies. Playback position advanced
after both seeks, with zero invalidations, no playback error and no disk
degradation. Sanitized snapshots are in the ignored local validation artifact
`build/player-validation/cache-seek-proof.json`. Disk-hit accounting describes
returned bytes; subsequent reads from a block promoted into RAM count as memory
hits rather than additional disk hits. The ordinary suite passed 583 tests;
the separate manual pressure script passed its 10 checks, and analysis passed.

### Optional subtitle timeout and readiness (2026-09-21)

The PlaybackState regression reproduced a specific 15-second failure with the
bundled Windows libmpv: a stalled HTTP `sub-add` hits the adapter's reply deadline,
while a subsequent `pause` property request still succeeds. Previously that
exception escaped track restoration into `PlayerController._failOpen`, stopping
already-ready media. This synthetic reproduction is not confirmation that the
user's original server failed for exactly the same reason.

External subtitles now load with `auto` after pinning the actual sid, then select
only after successful completion. On timeout the backend checks the current
session, readiness/surface failure state and a fresh sid reply within two seconds.
A responsive session retains its selection and shows a track warning; a failed
health check still retires playback. Late completion can add an unselected track
without changing the user's selection. The existing surface watchdog remains
active. Media readiness is published before optional restoration and Playing
reporting; report failures stay in the ordered session queue. Request traces are
bounded in memory and contain IDs, request names, timing and outcome, not arguments
or credentials. No production log file is introduced.

Executed `powershell -NoProfile -ExecutionPolicy Bypass -File tool/player_smoke.ps1`:
the pre-change run is `build/player-validation/runs/20260921-204806-050`; the
extended run is `build/player-validation/runs/20260921-210043-429` (both ignored
local evidence). In the extended run, `player.jsonl` records readiness at 473 ms
with Playing delayed, then continued playback at 16,050 ms. The slow-subtitle
case was ready at 392 ms; native `command:sub-add` timed out after 15,015 ms,
followed by a successful control check. Playback continued, and after the delayed
subtitle arrived its sid remained false at about 20 seconds with position 19,666
ms. `result.json` and `player-result.json` passed; the script restored the ordinary
production release build afterward. Pause/resume, EOF, failed media, replay,
subtitle selection, power requests and disposal were also exercised.

This launches the actual Windows main and child windows with the native renderer.
The recorded first-frame/watchdog and core screenshots do not independently
verify Flutter's displayed pixels, absence of flicker or physical audio output.
No new desktop pixel capture or human visual/audio inspection was performed.
The native package tests use real libmpv when `RILLIGHT_TEST_MPV` points to
`build/windows/x64/runner/Release/libmpv-2.dll` and `RILLIGHT_TEST_MEDIA` to
`build/player-validation/media/baseline.mp4`; their surface method channel is
mocked or video output is null. These tests are distinct from the window smoke.
Development checks passed: the two session/backend case files (45 tests),
`flutter test test/suites/player_test.dart` (69 tests), and
`flutter test packages/rillight_player/test` with the above native variables
(47 tests, including the real 15-second subtitle timeout). Targeted Dart analysis
and changed-source formatting passed. An initial trace implementation triggered
synchronous stream reentrancy; trace delivery now uses a microtask, and its tests
wait for diagnostic delivery before checking replies. The full adapter suite
passed after these corrections.
macOS/Linux native checks and full Delivery verification remain unexecuted for
this change.
