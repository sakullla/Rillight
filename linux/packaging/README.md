# Linux package and playback regression

`desktop_smoke.sh` launches the installed desktop entry, checks its actual
process/window, closes it, removes only the private `libmpv.so.2` temporarily,
then requires a visible diagnostic with the missing dependency and log path.
The library is restored on exit. `assert_diagnostic.py` reads the dialog through
AT-SPI; checking only a process exit code would miss a silent desktop failure.

```sh
python3 tool/linux_release_checks.py verify /opt/rillight \
  --desktop /usr/share/applications/rillight.desktop
xvfb-run -a dbus-run-session -- bash linux/packaging/desktop_smoke.sh
```

Build `tool/player_smoke.dart` as a separate release target, generate fixtures
with `tool/player_fixtures.py`, and use a fresh output directory:

```sh
flutter build linux --release --target tool/player_smoke.dart
xvfb-run -a -s '-screen 0 1440x1000x24' dbus-run-session -- \
  bash linux/packaging/playback_smoke.sh build/linux/x64/release/bundle \
  build/player-validation/media /tmp/rillight-playback-evidence
```

The script uses the real main and child processes, a temporary Emby fixture
server and a PulseAudio null sink. `capture_playback.py` verifies the child
executable and captures its actual X11 window, not the desktop background or
an mpv screenshot. H.264, HEVC, AV1 and VP9 must each show three consecutive
colored video samples with at least two different video-region hashes during
the same media phase. First visible video has a bounded three-second deadline.
The audio stream must belong to that child PID. Both the app result and this
independent window check must pass. Restore the ordinary `lib/main.dart` target
before producing a release package. The reusable Linux CI runs both targets.

From Windows, a prepared Docker container can validate an exact snapshot of
the current working tree, including uncommitted source edits:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tool/linux_playback_validation.ps1 -Container rillight-cache-validation-20260920
```

The container needs the pinned Flutter SDK at `/cache/flutter`, package cache
at `/cache/pub`, pinned media prefix at `/cache/native`, build tools and the
window-smoke dependencies above. Mount this repository read-only at `/source`
with generated fixtures at `/source/build/player-validation/media`. The
wrapper copies sources to a new `/work/rillight-validation-*` directory,
builds both production and smoke targets, audits their ELF/RUNPATH resolution,
runs the native package tests with the bundled real libmpv, and runs the
unchanged window-pixel checks. Evidence, including the source archive hash and
Git base, is copied to `build/player-validation/linux-current-*/`, including
on failure. It does not rebuild media libraries, alter the host build, or
claim an Ubuntu 24.04 install check from an Ubuntu 22.04 container.

This catches the scaler-padding regression found during integration: mpv
0.41.0 allocated a six-tap LUT in eight-channel rows without initializing the
last two channels. Observed NaN padding contaminated GL linear filtering.
Decoded CPU frames and the first chroma-merge pass were valid; the next scaling
pass and window were black. An isolated release build with zero padding passed
three H.264 and three HEVC runs; injecting NaN only into the unused channels made
all six runs black. The fixed, hashed one-line patch is shipped with the bundle.
The normal scaler, frame dropping, decoder direct rendering and automatic
hardware selection remain enabled. This is not evidence about the earlier
Windows flicker report.

Xvfb/software Mesa and a virtual audio sink prove this tested path only.
Record the three-second drop-count deltas, RSS, actual hardware decoder and
mpv A/V samples; do not treat a colored window as proof of real-time throughput,
physical audio output, GPU hardware decode or end-to-end synchronization.
