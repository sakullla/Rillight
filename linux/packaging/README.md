# Linux package and playback regression

Build the pinned FFmpeg/libass SDK with
`packages/rillight_player/native/build_linux.sh ABS_PREFIX ABS_WORK`, then set
`RILLIGHT_CORE_PREFIX=ABS_PREFIX` for Flutter. The SDK verifier requires the
locked source commit, patch, library hashes, libass, VAAPI/DRM build inputs and
HTTP/TCP input protocols. The package builder copies only verified libraries
and records final ELF hashes after RUNPATH rewriting.

`tool/linux_release_checks.py verify BUNDLE` checks ELF dependencies, private
RUNPATH resolution, absence of libmpv, bundled source provenance and final
library hashes. The installed launcher diagnoses a missing
`librillight_core.so` or transitive dependency visibly. Run the installed
desktop check on Ubuntu 24.04:

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
  build/player-validation/media build/player-validation/linux-window-new
```

The smoke uses Xvfb/software Mesa and a PulseAudio null sink.
`capture_playback.py` captures the actual child-player X11 window and requires
changing colored frames for H.264, HEVC, AV1 and VP9; it also verifies a
sink input for the child PID. It does not establish physical audio output,
hardware GPU performance, or a macOS/Windows result. Restore the ordinary
`lib/main.dart` target before packaging a release.

From Windows, `tool/linux_playback_validation.ps1 -Container NAME` copies a
current source snapshot into a prepared Linux container, builds production and
smoke targets, and saves logs under `build/player-validation/`. The container
needs Flutter 3.47.4, a verified core SDK at `/cache/native`, and the listed
window-smoke dependencies. The script reports failures as failures; it does
not turn Docker/Xvfb evidence into a Linux hardware claim.
