# rillight_player

Minimal desktop libmpv adapter. `MpvPlayer.create()` initializes a control
isolate and native renderer before returning. `nativeVersion` reports the
loaded library. `command`, `setProperty` and `getProperty` complete only on the
matching async reply. `loadfile` acceptance is distinct from `file-loaded`;
events expose property changes, end-file reason/error, seek, playback restart,
first rendered video frame and surface failures. Borrowed mpv nodes are copied
before the next event read. A new media session should own a new player.

`MpvVideoView(player: player)` renders into the existing page. Await
`player.dispose()` before closing the host: it rejects new commands, cancels
pending replies, unregisters the surface, frees the renderer, then destroys the
core in the control isolate. Repeated disposal returns the same Future. A
stalled native teardown reports a timeout; the process host owns escalation.

## Native surfaces

- Windows: own D3D11 device and ANGLE context per player; a worker renders,
  copies into a new shared texture and checks a D3D completion query before
  publication. Raster obtains a latest-ready snapshot without GPU waits.
  Import release retires a ticket; published allocations are never rewritten.
  The descriptor outlives its ticket because Flutter reads fields after release.
- macOS: worker queue renders to a fresh IOSurface/CVPixelBuffer, finishes GPU
  work before publication, and retains it for Flutter. It never recycles a
  mutable buffer pool. Async unregistration precedes render/core destruction.
- Linux: GDK context sharing follows Flutter's `FlTextureGL` contract. A worker
  renders to new GL allocations and completes GPU work before publication.
  Latest/displayed/producing allocations are bounded; deleting old allocations
  uses GL's retained-resource semantics, never a writable rotating texture pool.

There is no automatic software renderer downgrade. Native errors propagate.
Windows fake-registrar smoke verifies production, resize, descriptor lifetime
and shutdown; it does not replace real Flutter import or visual validation.

## Versions and packaging

`native/dependencies.json` is authoritative. Verified on 2026-09-17:

- Upstream stable mpv: **0.41.0**.
- Windows x64: **0.41.0-1023-g69e63f425**, shinchiro 20260903 git build,
  client API 2.5, FFmpeg N-126390-g9fc8c785e. This is explicitly a git build.
  CMake verifies SHA256 and bundles libmpv and ANGLE runtime DLLs.
- macOS universal x64/arm64: IINA libmpv **0.41.0**, minimum **macOS 11.0**.
  All 45 dylibs are locked by individual SHA256. CocoaPods runs
  `native/prepare_macos.py`; set `RILLIGHT_NATIVE_CACHE` to reuse a verified
  download cache. Runner must execute, before application signing:
  `python3 packages/rillight_player/native/bundle_macos.py path/to/Rillight.app`.
  This copies the dependency closure into Contents/Frameworks, checks links,
  signs each dylib with the build identity, and includes the manifest/notices.
- Linux requires **mpv >= 0.41.0**, both at build and runtime. System libraries
  may be used only if they meet that version; Ubuntu 22.04's stock libmpv does
  not. `bash native/build_linux.sh ABSOLUTE_PREFIX` builds fixed mpv 0.41.0,
  FFmpeg n8.0.1 and libplacebo v7.351.0 sources without root installation.
  Export the printed PKG_CONFIG_PATH/LD_LIBRARY_PATH before Flutter build.
  `mpv.pc` reports client API 2.5.0, so the script also initializes the actual
  library with `native/check_mpv.py` and verifies `mpv-version >= 0.41.0`.
  `python3 native/bundle_linux.py PREFIX BUNDLE` packages the built media libs.

Ubuntu source-build prerequisites: build-essential git nasm pkg-config
python3-venv libass-dev libgnutls28-dev libaom-dev libegl1-mesa-dev
libgl1-mesa-dev libasound2-dev libpulse-dev libva-dev libdrm-dev libx11-dev
libxext-dev libxrandr-dev libxinerama-dev libxcursor-dev libxpresent-dev
libwayland-dev wayland-protocols libxkbcommon-dev libepoxy-dev libgtk-3-dev
patchelf. Runtime needs matching system GL/GTK, audio, font and TLS libraries.
The source script has not been executed on the Windows development host.

## Development checks

`flutter test` runs memory-copy tests. Set `RILLIGHT_TEST_MPV` to the real
library and `RILLIGHT_TEST_MEDIA` to a local video to include native core tests
(creation failure, correlated replies, tracks, failed open, EOF, cancellation,
repeat disposal). No private server or credentials are required.

On Windows configure `native/tests` with CMake, set `FLUTTER_ENGINE` to the
Flutter engine artifacts/windows-x64 directory and optionally
`RILLIGHT_ARCHIVE_CACHE` to a verified archive cache. Build Release and run
`surface_test.exe path/to/video`. Repeat with 1080p60 and 4K HEVC material.
macOS/Linux source is implemented but native build, GPU and signing validation
must be performed on the corresponding OS; no Windows test proves those paths.
