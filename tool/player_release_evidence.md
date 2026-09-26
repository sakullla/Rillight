# Playback candidate evidence

`player_core_release_checks.py` and `player_performance_checks.py` audit recorded
results. They do not launch media or infer success from a successful build.
Keep raw logs, screenshots, audio observations, SDK markers, package hashes and
failure samples under ignored `build/` or another immutable evidence directory.
Use an exact candidate Git commit and package bytes for every report.

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

The same explicit `--macos-handoff` option is available for the comparator;
it records Mac performance as pending. Missing other target data makes the
check fail. Windows/Linux physical GPU/audio, Android phone and TV hardware,
and Mac target results must be collected before claiming a five-target
performance improvement.
