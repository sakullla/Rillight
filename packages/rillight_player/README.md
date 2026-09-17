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
  The initial import uses an initialized transparent 1x1 texture. Notifications
  are coalesced onto the GTK main loop and check registration/generation again.

All surfaces disable libmpv's internal target-time sleep. The control isolate
therefore enforces `video-timing-offset=0`, including when a caller supplies an
alternative creation option. This follows the Render API's documented timing
contract and removes the default 50ms premature publication. This policy does
not prove zero display/audio latency: the native smoke reports mpv `avsync`
samples; end-to-end audio/display measurement still needs target hardware.

### Linux retirement ordering

Linux's public registrar has no unregister-completion callback. Normal dispose
first clears the Dart texture ID, then uses an explicit two-stage protocol:

1. `detach` stops production, invalidates queued GTK notifications, and calls
   the registrar to enqueue unregister. It retains the texture GObject and all
   allocations which an in-flight raster import could still access.
2. Only after the MethodChannel reply does Dart request an asynchronous
   `Picture.toImage(1, 1)`. This posts real work to the same engine raster runner
   after unregister; its completed Future proves that earlier raster callbacks
   and the unregister task have run. It does not wait for a vsync/frame-timing
   callback, so it also works without a mounted view or visible window.
3. Dart sends `dispose` only after that barrier. The worker frees the retired
   GL allocations, joins, and drops the texture GObject. Core destruction is
   still last. The producer never rewrites published texture allocations.

Initialization/render failures retain allocations and follow exactly this
retirement path. A missing native surface returns `detach=false`; all other
detach/barrier failures, malformed replies, and timeouts retain resources for
process-host escalation. A late completion after timeout cannot trigger
dispose. Loss of the channel only stops producers: engine finalization, after
FlutterEngineShutdown joins raster, is the alternate safe retirement signal.

This ordering was checked against Flutter **3.47.4**, framework commit
`9584c6713b324636289d067944a46fd6b49df14b`, engine commit
`06a2e2a110089dff50fe635cffd2a61e1b24fbcd`. Recheck these engine contracts when
upgrading Flutter:

- `shell/common/shell.cc`, `OnPlatformViewUnregisterTexture`: posts unregister
  to the raster task runner before returning to the platform channel.
- `lib/ui/painting/picture.cc`, `Picture::DoRasterizeToImage`: posts snapshot
  work to that raster runner and replies to Dart afterward.
- `shell/platform/linux/fl_texture_registrar.cc`: unregister drops its GObject
  reference immediately, which is why the plugin retains a separate reference.
- `shell/platform/linux/fl_engine.cc`, `fl_engine_dispose`: synchronous engine
  shutdown precedes GObject finalization and its weak-notify retirement hook.

`test/surface_retirement_test.dart` covers ordering, absent surfaces, errors,
timeouts and late completions, plus an actual raster snapshot without a widget.
These Windows-hosted tests do not prove Linux GTK/GL behavior. On Linux, validate
first import before file load, close during import/resize, minimize then close,
failed initialization/render and engine teardown, with GL diagnostics enabled;
there must be no GTK thread assertions, null GError access, or access to retired
texture objects. Native Linux build/GPU execution remains unverified here.

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
