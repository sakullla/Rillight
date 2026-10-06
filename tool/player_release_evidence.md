# Playback candidate evidence

`player_core_release_checks.py` and `player_performance_checks.py` audit recorded
results. They do not launch media or infer success from a successful build.
Keep raw logs, screenshots, audio observations, SDK markers, package hashes and
failure samples under ignored `build/` or another immutable evidence directory.
Use an exact candidate Git commit and package bytes for every report.

## Aggregation/private-region development evidence (T7 working tree)

- `flutter test test/aggregation/presentation_test.dart --plain-name 'desktop actual UI opens isolated'` executed the real desktop aggregation/comparison/detail play action, `DesktopPlayerWindowHost.open`, an OS-isolated Flutter test helper running `PlayerWindowApp.testing`/`PlayerController` with `FakeVideoBackend`, the production per-process file mailboxes, and the main application's sole `HistoryWriter`. It observed ordered B-source 7s then 11s events and revoked the helper and ordinary history on membership migration. This is simulated playback/control/IPC evidence, not a native independent-window rendering pass.
- `flutter test test/aggregation/presentation_test.dart --plain-name 'TV remote actual'` executed real multi-frame directional-key navigation from TV aggregation to `TvDetailPage`, select to `TvPlayerPage`/`PlayerController`, B-source 7s local history and membership revocation rejecting late 9s. The backend and HTTP are synthetic; this does not establish a physical remote, native surface, decoder or sound.
- Management/PIN tests exercise the three actual routing trees, mismatch/cancel without widening unknown library scope. Registry tests cover independent target-account login, explicit library discovery without automatic participation expansion, and late private login after lock.
- Resume development run: `flutter test --no-pub --reporter expanded --timeout 40s test/aggregation/presentation_test.dart --name 'phone|TV remote actual|management'` passed six tests (`/private/tmp/t7-current-adjacent.log`). The real phone tree finds/compares B, manually switches to A, commits an actual synthetic backend observation, preserves A when ordinary Auth selects B, migrates A, reopens private A, locks from its switch dialog and rejects late observations. This remains FakeVideoBackend/HTTP evidence, not native playback. Original business/semantics failures and the tree-locked disposal stack remain in `/private/tmp/t7-resume-phone-reason.log`, `/private/tmp/t7-resume-phone-chain3.log`, and `/private/tmp/t7-current-chain10.log`; the original Flutter semantics root cause is not established by the later scoped pass.
- Focused prototype capture executed `node tool/capture-ui.mjs --only 'aggregation-management,aggregation-pin-error' --platform desktop --theme light --size 1024`: both states passed; report `build/ui-capture/2026-10-05T11-34-17-151Z-WkGS0Y/index.html`. This establishes only those desktop light-theme appearances, not the full three-platform/two-theme capture or any native result.
- A3 resumed development closed the old phone/TV consumer failures without removing their behavior/semantics checks. TV history teardown advances fake-zone timers while draining real IO; aggregation pagination uses its actual per-source label, waits for query completion, and drives the remote through lazy card rows. Phone source cancellation now starts from a persisted backend viewing receipt, not a successful open. The combined phone-player/TV-flow run passed 46 tests (`/private/tmp/t7-a3-resume-consumers-final.log`). Earlier bounded failures remain historical evidence, not the current result.
- The current desktop cumulative test (`--plain-name 'desktop actual helper menu'`) drives the actual isolated helper's menu through production file RPC, B→A switch, target viewing receipt, migration, private reopen/receipt, and urgent lock while catalogue HTTP is stalled. It rejects forged pid/configured-server/verified-server/user/region, old generation and old sequence before the real lock; late catalogue and old writer events cannot revive private state (`/private/tmp/t7-a3-resume-desktop-secure2.log`). The cumulative run exposed concurrent shutdown/revocation deleting the same mailbox; cleanup now shares one Future, and Windows closes the retained original handle once. IPC/control/launch/window/snapshot adjacent tests passed 49 tests; the final cleanup/protocol rerun passed 17 (`/private/tmp/t7-a3-resume-ipc-adjacent2.log`, `/private/tmp/t7-a3-resume-cleanup-final.log`).
- Real phone/TV switch dialogs lock independently of stalled version preflight and reject late receipts. Both actual episode menus resolve the concrete B episode and its selected version before writing B history. Three routing trees reject pre-lock decoded extras after unlock and forged-account restoration; revocation of covered B detail preserves independently authorized A playback, while a revoked route cannot erase fresh different-source navigation. These scenarios are included in the final development full suite below, not native-device evidence.
- Final development `TMPDIR=/private/tmp flutter test --no-pub --reporter expanded` passed 1327 tests (`/private/tmp/t7-a3-resume-full-final.log`), after fixing the cumulative mailbox race. Formatting check, suite registration check and analysis also passed (`/private/tmp/t7-a3-resume-format-check.log`, `/private/tmp/t7-a3-resume-suites-check.log`, `/private/tmp/t7-a3-resume-analyze-check.log`). Earlier `/private/tmp/t7-full.log` and A3 failed/timeout logs remain failure history; no conclusion about their original Flutter semantics cause follows solely from a later pass. These are working-tree developer results; formal Delivery verification, including its separate integration/full-capture commands, is not claimed here.
- Current affected prototype capture: `TMPDIR=/private/tmp node tool/capture-ui.mjs --only 'player-settings-source*,player-settings-quality*,library-filters-watch,library-filters-genre'` passed desktop 1024/1440, phone 360/412 and TV 1920 in both themes (`/private/tmp/t7-a3-resume-capture-final.log`; report `build/ui-capture/2026-10-05T17-55-29-350Z-1kY1sS/index.html`). This is filtered generated-layout evidence, not a full registry capture, a manual visual approval, native windows, decoder, physical audio or hardware acceptance.

Native manual-switch/lock acceptance remains **unverified** on Windows, macOS, Linux, Android phone and Android TV. On each target, use two synthetic Emby services with common provider identity, independently authenticated users, two validated same-server lines, different edition durations/languages, and explicit library scope. Record actual displayed frames, physical audio, actual decoder/source/version, position and pause intent before/after switching, failure restoration, and lock/migration while pending. For Android additionally verify the native view remains mounted while loading, then playback exit + gesture navigation + screen lock/wake. For desktop independently verify helper process termination at the close budget and no post-revocation request/recovery/snapshot reconciliation. PIN persistence/restart and back/forward/overlay cleanup must be exercised in the packaged app. Keep candidate/package hashes, raw network/event/process logs and display/audio observations under ignored `build/`; no release, SDK, GPU or performance result is established here.

## Current workspace observations (2026-09-26)

These runs use the current working tree, including uncommitted changes. They
are development evidence, not a five-platform release candidate report.

- Windows: `build/player-validation/runs/20260926-212129-319/result.json`
  and `20260926-212305-411/result.json` passed consecutive release-mode
  production main/child smokes. The final cache-revision candidate also passed
  at `build/player-validation/runs/20260926-215733-064/result.json`. These
  cover changing video, virtual app audio, subtitles, HLS, seek, outage
  recovery and display power release. The final production
  `flutter build windows --release` and
  `python tool/verify_player_dependencies.py` passed. The native core survived
  interrupted HTTP reads and 21 timeline
  changes using the 30-second synthetic media fixture. Earlier failed attempts
  remain under `build/player-validation/runs/`.
- Linux: `build/player-validation/linux-current-20260926-213519/validation.json`
  passed a fresh production build, ELF audit, native package tests and actual
  Xvfb window smoke on Ubuntu 24.04.5 with software Mesa and virtual audio.
  The immediately preceding source run failed during a subtitle switch and is
  retained at `linux-current-20260926-212859`; the passing candidate reuses
  unchanged cache timeline snapshots. Xvfb does not establish physical GPU
  performance or speaker output.
- Android Studio API 36 emulators: 360dp phone
  `build/android-validation/runs/20260926-narrow-final/result.json`, 412dp
  phone `build/android-validation/runs/20260926-large-final/result.json`, and
  TV `build/android-validation/runs/20260926-tv-final-grpc/result.json`
  passed their separate app/native checks, changing frames and virtual audio.
  The current-source ordinary APK audit passed at
  `build/android-validation/runs/20260926-apk-final-candidate/result.json`.
  The TV run used a cold Android Studio AVD with an explicit authenticated
  emulator gRPC audio endpoint. Earlier failed TV runs are retained: one
  sampled only 4.48 of 6 requested audio seconds, one lost the emulator, and
  one used a stale gRPC discovery file. The phone runs predate the final
  desktop transport/cache revisions; they are not fresh current-source runs.
  All three targets have emulator evidence only.
- macOS: an Apple M3 host on 2026-09-26 built the pinned universal SDK/core,
  verified the Release bundle, probed FFmpeg n9.0.1/ABI 8, adhoc-signed a
  test DMG and passed the sandbox proxy. GUI H.264/HEVC/VP9/AV1 frames,
  physical audio, actual VideoToolbox decoder use and Intel remain open in
  `packages/rillight_player/macos/TESTING_HANDOFF.md`. That is not a
  playback pass.

The all-hardware release gate and matched baseline/candidate performance
comparison have not passed: physical Windows/Linux/Android audio and GPU
observations, macOS target checks, and the required frozen baseline samples
are unavailable in this workspace. Do not cite the passing local smoke as a
measured five-platform speedup.

During active playback, the cache bar maps locally present session blocks to
media time and refreshes when the cache revision changes. The foreground read
validates each block's CRC; an explicit integrity snapshot can also revoke a
same-length corrupted disk block. External same-length corruption before the
next read can temporarily overstate the live bar because its real-time path
avoids a repeated full CRC scan that blocked seek/subtitle controls on Windows
and Linux. This limit is not evidence of a fully tamper-proof live buffer bar.

## Package and output gate

Run `python tool/player_core_release_checks.py --all-platforms --require-hardware
--evidence-root build/player-core-release`. The default targets are Windows,
macOS, Linux, Android phone and Android TV. Place one `<target>.json` in the
evidence root using this schema:

```json
{
  "schema": 1,
  "target": "android-tv",
  "candidate_revision": "<40-character Git commit>",
  "artifact": "../app-release.apk",
  "artifact_sha256": "<SHA256 of that file>",
  "dependencies": {
    "librillight_core": {"path": "../libcore.so", "sha256": "<SHA256>"}
  },
  "checks": {
    "native_build": {"passed": true, "evidence": "native-build.log", "environment": "ci"},
    "package_closure": {"passed": true, "evidence": "apk-closure.json", "environment": "ci"},
    "installed_launch": {"passed": true, "evidence": "launch.log", "environment": "hardware"},
    "actual_video": {"passed": true, "evidence": "visible-changing-frames.mp4", "environment": "hardware"},
    "actual_audio": {"passed": true, "evidence": "physical-audio-observation.json", "environment": "hardware"},
    "av_sync": {"passed": true, "evidence": "sync-observation.json", "environment": "hardware"}
  }
}
```

Every `passed` check needs an existing evidence file. The aggregator verifies
the artifact and listed native-library hashes. The platform package audit must
also prove the full dependency closure and absence of libmpv/Media3. A native
first-frame callback, core screenshot, emulator virtual speaker, Xvfb image or
CI configuration must be labeled with its actual environment; it cannot count
as physical output. The JSON example describes a fully observed candidate,
not a current result.

GUI playback, physical audio and Intel results are still missing. For the
explicitly agreed handoff, append `--macos-handoff
packages/rillight_player/macos/TESTING_HANDOFF.md`. The result reports
`passed: false`, `accepted_with_handoff: true`, and an unverified macOS item.
This permits local workflow closure while preserving the missing playback proof.
An existing Mac result is audited even when the flag is present, so a recorded
failure cannot be hidden by the handoff. Do not use that flag for a release
decision that requires all five target hardware results.

## Baseline versus candidate

Run `python tool/player_performance_checks.py --compare-baseline
--require-all-targets` after collecting JSONL at
`build/player-performance/baseline.jsonl` and `candidate.jsonl`. Override the
paths with `--baseline` and `--candidate` as needed. Each line is one attempted
run, including failures or timeouts. Required identity fields are `phase`,
`target`, `category` (`page`, `network`, `animation`), `label`, `cache` (`cold`
or `warm`), `device`, `buildMode` (`profile` or `release`), `media`, `network`,
`quality`, `frameBudgetMs`, `artifactPath`, and `artifactSha256`. The artifact
path resolves from its JSONL directory and its bytes must match the hash.
`complete` records whether the attempt finished; incomplete attempts remain
in the denominator.

For page scenarios record `firstOperableMs`; for network scenarios record
`stallMs`. Animation samples need at least 60 seconds of `elapsedMs`,
`frameTimingsComplete: true`, and matching `uiFrameMs` and `rasterFrameMs`
arrays. Frame budget comes from the tested device's refresh rate. The
comparator requires at least 20 attempts for each matched scenario, reports
median, p95, range and failure counts, rejects more candidate failures and
classifies improvement only when it exceeds baseline variation. Scenario
identities must match exactly, including media, quality, network and cache
state. It never deletes outliers or treats missing samples as fast samples.

Android phone additionally requires `image`, `startup`, `power` and `thermal`
categories at the same minimum 20 attempts per matched scenario. Image samples
need `firstDisplayedImageMs` plus `renderedImageObserved: true` from a decoded
image whose bounds survive opacity, clipping and viewport checks. A keyed
placeholder is only `firstContentMs`. Image and startup samples require hashed
before/after PNG captures, a `screenRegion` of at least 48×48 pixels with
computed mean RGB change of at least 2, `screenPixelChangeObserved: true` and
clock uncertainty at most 100 ms. Startup uses `firstDisplayedFrameMs`. Native
`firstFrame` is a separate timestamp, never a substitute for displayed pixels.
Power and thermal attempts require a physical phone, at least five minutes per
run, measured `energyMWh` or `tempRiseC`, method, initial temperature,
brightness and volume. Candidate failures stay in the denominator; conditions
must match and initial median temperature must differ by at most 1 °C. Missing
power rails need an identified fuel gauge method with its uncertainty recorded,
not an emulator estimate presented as phone energy.

The offline comparator above accepts recorded JSONL for analysis. The formal
phone candidate gate additionally requires a unique `probeTraceId` on **every**
baseline and candidate row, bound to a locally signed live capture/probe trace
for the row's APK, device, phase, app-generated run ID and category. First audit
the frozen baseline from a separate checkout of
`48316fc71c8c5e19ae3af34a59168e6f8eccaa8e` with
`python tool/phone_player_validation.py --audit-baseline --baseline-checkout
CHECKOUT --evidence-root build/phone-player-validation`. Copy the current
`integration_test/mobile_performance.dart` into that checkout first; this is a
**probe-only overlay**, so the measured baseline is the frozen application
source plus the exact recorded instrumentation diff, not an unmodified frozen
APK. The audit rejects any other checkout changes, builds the profile probe
entrypoint and verifies the APK/native libraries and source tree. Audit the
candidate's matching profile probe entrypoint with
`--audit-performance-candidate`, then install the appropriate audited profile
APK for each phase. The separate three-device `app-probe.apk` remains the
functional validation APK and cannot supply port 8798 performance evidence.
Collect a `page` or `animation`
trace with `python tool/phone_player_validation.py --capture-performance page
--capture-phase after --performance-phase candidate --serial SERIAL
--evidence-root build/phone-player-validation` while the profile/release
validation app and its port 8798 probe run on that phone. Start each scenario
with probe `/begin` first; the `after` capture consumes that run through `/end`
exactly once. For `image`, `startup`, `network`, `power` and `thermal`, collect
`before` and `after` during the same active run and attach their exact screenshot
paths/hashes. Baseline capture uses `--performance-phase baseline`; its installed
APK must equal the frozen audited build. The gate requires row timings/frame
arrays to match the stored one-time probe trace. Display
latency uses the probe's elapsed time after the live screen capture, an upper
bound on the first visible pixel. For `network`, play the synthetic
`multi-source` item from the loopback fixture on port 8784 with an active player
probe run (`adb -s SERIAL reverse tcp:8784 tcp:8784` routes the phone to that
synthetic host service). The `before` command injects `media_fail`, waits for an actual 503
media request and a `PlayerController.isBuffering` transition, then captures
the stalled screen. The `after` command clears the fault, waits for a successful
media request and the controller's recovery transition, then captures the
recovered screen and a later frame in its center video region. Both requests
must have the same hashed client identity and media path; raw auth is never
logged. The same player must remain actively playing without a terminal error
or disconnect, and its position must advance at least 500 ms after recovery.
The center video region must show changing colored pixels between the two
recovery captures. `stallMs` is the difference between controller buffering
event times. A failed capture clears the synthetic media fault in `finally`.
The gate requires signed fixture controls, requests, event order, player state,
position advance and video motion; screenshot interval alone is insufficient.
The client digest correlates requests but cannot independently prove which
process issued them; the player and display observations supply that context.
Power/thermal `after` capture additionally
requires `--measurement-file FILE`: a schema-1
`physical-meter-attestation` with `category`, `runId`, `deviceSerial`,
`apkSha256`, `method` (`power-rail` or `thermal-zone`), named `attestedBy`,
`observedAtUtc`, `instrumentModel`, `instrumentSerial`,
`uncertaintyPercent`, `initialTempC`, `brightnessPercent`, `volumePercent`,
and hashed `rawLogPath`/`rawLogSha256` under the evidence root. That log is a
JSON array of at least 20 increasing `elapsedMs` readings spanning five
minutes with cumulative `energyMWh` or `tempC`; the gate derives the row metric
from its endpoints and checks duration against the live run. A named external
physical meter and retained raw log are required; a virtual battery estimate
or caller-authored metric row does not qualify. Reusing a run or trace ID,
changing a raw log, or supplying self-authored PNG/timing values fails. The
local signature and human meter attestation make the observation reviewable;
they do not independently prove instrument calibration or an absence of human
error.

For the current phone candidate run `python tool/phone_player_validation.py
--verify-candidate --evidence-root build/phone-player-validation`. It writes
`result.json` with Git revision and working-tree content hashes and checks the
current Android 360dp/412dp/TV runner, paired baseline/candidate samples and
physical-phone observations. The runner's audited `.validation` APK hash and
source identity are saved in `candidate-build.json`; a valid manifest can be
reused on a later run without deleting previous evidence. Supply
`physical-phone.json` under that ignored root with the same `candidate_head`,
`working_tree_sha256`, exact audited APK path/hash, physical device serial and
fingerprint. The physical phone must still be connected, and its installed APK
hash must equal the audited build. Each check named by `PHYSICAL_CHECKS` in the
validator needs a hashed schema-2 observation with scenario-specific measured
fields. Capture each screen check's before and after PNG through the live gate:
`python tool/phone_player_validation.py --capture-scenario SCENARIO
--capture-phase before --serial SERIAL --evidence-root build/phone-player-validation`
and repeat with `--capture-phase after` while the audited `.validation` app is
foreground on the same connected phone. Use a `SCREEN_EVENTS` scenario name.
The gate captures `adb exec-out screencap -p` itself, binds the files to the
installed APK and candidate in its local capture ledger, and accepts only those
exact paths and hashes in the observation. It also checks visible pixel change.
Caller-supplied PNGs cannot substitute for this live capture. Physical audio
requires ambient/playback WAV amplitude plus a separate, hashed, named manual
attestation that the built-in physical speaker was heard on that phone and
candidate. WAV alone does not prove speaker output. Power/thermal contains
repeated timed readings. Plain `passed` flags and placeholder JSON cannot
satisfy the gate. The local capture ledger detects accidental substitution;
it is not a tamper-proof or independent measurement authority.
This gate fails closed when the verified native SDK, device, samples or a check
is unavailable. Emulator control results remain separate from physical output,
audio and energy evidence. Never put runtime server details in repository files
or saved evidence.

The same explicit `--macos-handoff` option is available for the comparator;
it records Mac performance as pending. Missing other target data makes the
check fail. Windows/Linux physical GPU/audio, Android phone and TV hardware,
and Mac target results must be collected before claiming a five-target
performance improvement.

## Dolby Vision and realtime enhancement capability record

<!-- capability-record:start -->

This section records Dolby Vision and realtime-enhancement capability for the
five playback targets. It is not a hardware pass. A first-frame callback, an
emulator, or a single screenshot cannot be written as a physical pass.

四种状态只允许：支持并验证、能力不支持、尚未验证、已失败。当前五端矩阵没有支持并验证行。支持并验证必须落到参考设备、媒体样本、操作和物理输出。构建、模拟器、首帧回调和单张截图不能记成整项通过。测量结果不能反过来改阈值。1080p24 是下列数字的片源档。4K 实时不是承诺。缺样本、缺光学测量或物理声音时保持尚未验证。未单列的片源、连接和增强组合同样尚未验证，不能用邻近行的状态填上。

固定阈值。稳态窗口排除跳转或暂停后的 2 秒。理想帧间隔是 `1000 / 目标帧率` 毫秒。

- 至少 95% 的呈现间隔落在理想值的 0.5 到 1.5 倍，超过 2 倍的不超过 1%。
- 稳态视频 PTS 与音频时钟的中位绝对误差不超过 80 毫秒。
- 跳转后 2 秒内出现时间正确的帧，且没有跳转前时间线的帧。
- 同一片段增强开启 10 分钟，工作集比关闭时增加不超过 1.5 GiB。
- FEL 通过只认与纯基础层有可见差别的样本。回退到基础层不算 FEL 通过。

参考配置：

- Windows x64 D3D11：HDR 行要一台报告 HDR10 PQ、至少 10 bit 的显示器。原生杜比记能力不支持。Atmos 在没有报告 Atmos 的接收端时记尚未验证。
- macOS：已有记录的 MacBook Air M3 这一类机器。原生杜比记能力不支持。EDR 只在 headroom 大于 1 时记可测。HDMI Atmos 未接设备则尚未验证。
- Linux x64：只验收 SDR 映射和协商后的 PCM。原生杜比与 HDR 记能力不支持。
- Android 手机：已有记录的 PKM110 / Android 16。该机没有 `video/dolby-vision`，原生杜比记能力不支持。Profile 5 的 RPU 路径和实体锁屏要在本候选重测，旧通过不沿用。
- Android TV：仓库没有具体 leanback 机器。取得设备前各行记尚未验证，不用手机结果顶替。

scRGB、EDR 和 SDR 映射都是非原生杜比。只有 Android 实际选中 `video/dolby-vision` 且增强未生效时，才可能写成原生杜比；PKM110 没有该类型。

| platform | capability | status | evidence |
| --- | --- | --- | --- |
| windows | native-dolby-vision | 能力不支持 | Windows scRGB 是非原生杜比，本轮不发原生杜比信号 |
| windows | video-output | 尚未验证 | scRGB 是非原生杜比；需要报告 HDR10 PQ 且至少 10 bit 的显示器，本候选未测 |
| windows | atmos-passthrough | 尚未验证 | 没有报告 Atmos 的接收端 |
| windows | multichannel-pcm | 尚未验证 | 本候选没有物理测量 |
| windows | profile5-rpu | 尚未验证 | 本候选没有物理测量 |
| windows | profile7-fel | 尚未验证 | 没有与纯基础层对照的样本 |
| windows | profile8-base-layer | 尚未验证 | 本候选没有物理测量 |
| windows | frame-interpolation | 尚未验证 | 本候选没有物理测量 |
| windows | anime4k | 尚未验证 | 本候选没有物理测量 |
| windows | super-resolution | 尚未验证 | 本候选没有物理测量 |
| windows | denoise | 尚未验证 | 本候选没有物理测量 |
| windows | sharpen | 尚未验证 | 本候选没有物理测量 |
| windows | frame-interval | 尚未验证 | 固定阈值尚未在本候选测量 |
| windows | av-sync | 尚未验证 | 固定阈值尚未在本候选测量 |
| windows | enhancement-working-set | 尚未验证 | 固定阈值尚未在本候选测量 |
| macos | native-dolby-vision | 能力不支持 | macOS EDR 是非原生杜比，本轮不发原生杜比信号 |
| macos | video-output | 尚未验证 | EDR 是非原生杜比；MacBook Air M3 这一类机器仅在 headroom 大于 1 时可测，本候选未测 |
| macos | atmos-passthrough | 尚未验证 | HDMI Atmos 未接设备 |
| macos | multichannel-pcm | 尚未验证 | 本候选没有物理测量 |
| macos | profile5-rpu | 尚未验证 | 本候选没有物理测量 |
| macos | profile7-fel | 尚未验证 | 没有与纯基础层对照的样本 |
| macos | profile8-base-layer | 尚未验证 | 本候选没有物理测量 |
| macos | frame-interpolation | 尚未验证 | 本候选没有物理测量 |
| macos | anime4k | 尚未验证 | 本候选没有物理测量 |
| macos | super-resolution | 尚未验证 | 本候选没有物理测量 |
| macos | denoise | 尚未验证 | 本候选没有物理测量 |
| macos | sharpen | 尚未验证 | 本候选没有物理测量 |
| macos | frame-interval | 尚未验证 | 固定阈值尚未在本候选测量 |
| macos | av-sync | 尚未验证 | 固定阈值尚未在本候选测量 |
| macos | enhancement-working-set | 尚未验证 | 固定阈值尚未在本候选测量 |
| linux | native-dolby-vision | 能力不支持 | 原生杜比记能力不支持；SDR 映射是非原生杜比 |
| linux | video-output | 尚未验证 | SDR 映射是非原生杜比；物理画面尚未在本候选测量 |
| linux | hdr-output | 能力不支持 | 不新做 HDR 合成器，HDR 记能力不支持 |
| linux | atmos-passthrough | 尚未验证 | 本轮只验收协商后的 PCM，没有接受压缩格式的接收端记录 |
| linux | multichannel-pcm | 尚未验证 | 只验收协商后的 PCM，本候选没有物理测量 |
| linux | profile5-rpu | 尚未验证 | 本候选没有物理测量 |
| linux | profile7-fel | 尚未验证 | 没有与纯基础层对照的样本 |
| linux | profile8-base-layer | 尚未验证 | 本候选没有物理测量 |
| linux | frame-interpolation | 尚未验证 | 本候选没有物理测量 |
| linux | anime4k | 尚未验证 | 本候选没有物理测量 |
| linux | super-resolution | 尚未验证 | 本候选没有物理测量 |
| linux | denoise | 尚未验证 | 本候选没有物理测量 |
| linux | sharpen | 尚未验证 | 本候选没有物理测量 |
| linux | frame-interval | 尚未验证 | 固定阈值尚未在本候选测量 |
| linux | av-sync | 尚未验证 | 固定阈值尚未在本候选测量 |
| linux | enhancement-working-set | 尚未验证 | 固定阈值尚未在本候选测量 |
| android-phone | native-dolby-vision | 能力不支持 | PKM110 / Android 16 没有 video/dolby-vision，原生杜比记能力不支持 |
| android-phone | video-output | 尚未验证 | PKM110 没有 video/dolby-vision；PQ 或 SDR 回退不是原生杜比，旧通过不沿用 |
| android-phone | atmos-passthrough | 尚未验证 | 本候选没有物理测量 |
| android-phone | multichannel-pcm | 尚未验证 | 本候选没有物理测量 |
| android-phone | profile5-rpu | 尚未验证 | Profile 5 的 RPU 路径要在本候选重测，旧通过不沿用 |
| android-phone | profile7-fel | 尚未验证 | 没有与纯基础层对照的样本 |
| android-phone | profile8-base-layer | 尚未验证 | 本候选没有物理测量 |
| android-phone | frame-interpolation | 尚未验证 | 本候选没有物理测量 |
| android-phone | anime4k | 尚未验证 | 本候选没有物理测量 |
| android-phone | super-resolution | 尚未验证 | 本候选没有物理测量 |
| android-phone | denoise | 尚未验证 | 本候选没有物理测量 |
| android-phone | sharpen | 尚未验证 | 本候选没有物理测量 |
| android-phone | frame-interval | 尚未验证 | 固定阈值尚未在本候选测量 |
| android-phone | av-sync | 尚未验证 | 固定阈值尚未在本候选测量 |
| android-phone | enhancement-working-set | 尚未验证 | 固定阈值尚未在本候选测量 |
| android-phone | physical-lock | 尚未验证 | 实体锁屏要在本候选重测，旧记录不沿用 |
| android-tv | native-dolby-vision | 尚未验证 | 没有 leanback 机器，不用手机结果顶替 |
| android-tv | video-output | 尚未验证 | 没有 leanback 机器，不用手机结果顶替 |
| android-tv | atmos-passthrough | 尚未验证 | 没有 leanback 机器，不用手机结果顶替 |
| android-tv | multichannel-pcm | 尚未验证 | 没有 leanback 机器，不用手机结果顶替 |
| android-tv | profile5-rpu | 尚未验证 | 没有 leanback 机器，不用手机结果顶替 |
| android-tv | profile7-fel | 尚未验证 | 没有 leanback 机器，不用手机结果顶替 |
| android-tv | profile8-base-layer | 尚未验证 | 没有 leanback 机器，不用手机结果顶替 |
| android-tv | frame-interpolation | 尚未验证 | 没有 leanback 机器，不用手机结果顶替 |
| android-tv | anime4k | 尚未验证 | 没有 leanback 机器，不用手机结果顶替 |
| android-tv | super-resolution | 尚未验证 | 没有 leanback 机器，不用手机结果顶替 |
| android-tv | denoise | 尚未验证 | 没有 leanback 机器，不用手机结果顶替 |
| android-tv | sharpen | 尚未验证 | 没有 leanback 机器，不用手机结果顶替 |
| android-tv | frame-interval | 尚未验证 | 没有 leanback 机器，不用手机结果顶替 |
| android-tv | av-sync | 尚未验证 | 没有 leanback 机器，不用手机结果顶替 |
| android-tv | enhancement-working-set | 尚未验证 | 没有 leanback 机器，不用手机结果顶替 |
| historical-android-2026-10-01 | dolby-frame-interval-and-long-gop-seek | 已失败 | 2026-10-01 杜比 GPU 候选 passed=false，长 GOP 跳转和杜比帧间隔未通过；保留为历史失败，不自动成为当前候选结论 |

<!-- capability-record:end -->

