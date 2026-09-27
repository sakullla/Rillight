# Rillight player

This package owns the FFmpeg-based playback core used by the Flutter desktop
and Android app. `CorePlayer` supplies one session per open, native media
decode, audio/video clocks, subtitle/track control and a platform video
surface. Android uses an in-process TextureView; desktop uses the native core
and platform texture bridge. There is one production player path; the retired
libmpv and Media3 adapters are not runtime fallbacks.

The package API is in `lib/src/core_player.dart`. The native ABI and source are
under `native/`; platform adapters live under `windows/`, `macos/`, `linux/` and
`android/`. The application owns HTTP transport, cache, representation and
playback policy in `lib/player/`. A core first-frame event establishes decoded
output readiness, not that Flutter displayed a changing frame or that a real
speaker played sound. Backend diagnostics report `coreActualHardware` from the
selected video track (0 means software or no video); the requested decoder
preference is not used as proof of actual hardware decoding.

## Pinned media SDK

[`native/core_dependencies.json`](native/core_dependencies.json) pins FFmpeg
n9.0.2, the local HLS I/O patch, libass 0.17.5, dav1d 1.5.3 and Android
subtitle build sources. Desktop SDKs enable dav1d for AV1 software fallback.
Each SDK prefix must carry `rillight-core-dependencies.json` with
actual build options and SHA256 of its libraries. Verify a target SDK with:

```sh
python packages/rillight_player/native/verify_core_dependencies.py \
  --prefix /absolute/sdk/prefix --target linux-x64 --require-subtitles
```

Supported manifest targets are `windows-x64`, `macos-universal`, `linux-x64`,
`android-arm64-v8a`, `android-armeabi-v7a` and `android-x86_64`. Source pins and
SDK hashes are necessary inputs; release checks must also verify actual
loadable dependency closure and recorded native versions. License material is
listed in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

### Linux

`native/build_linux.sh ABSOLUTE_PREFIX ABSOLUTE_WORK` builds the pinned SDK
with libass and dav1d. Set `RILLIGHT_CORE_PREFIX` to the resulting SDK before
`flutter build linux --release`. The package and installed launcher are checked
by `tool/linux_release_checks.py`; an Ubuntu 24.04 install, desktop start and
actual changing frames remain separate validation steps. Xvfb and a virtual
audio sink do not establish physical GPU or speaker performance.

### Windows

Set `RILLIGHT_CORE_PREFIX_WINDOWS_X64` to a verified SDK containing FFmpeg,
libass, dav1d and `librillight_core.dll`, then build the Flutter Windows target.
The CMake target fails closed when the SDK marker or libraries are missing.
`tool/player_smoke.ps1` exercises the normal application entry with synthetic
credentials. Record actual window frames, audio output and GPU behavior
separately from native control events. The tag workflow builds the SDK with
`native/build_windows_dependencies.py --prefix SDK --work WORK --msys-root MSYS2`,
using MSYS2 MinGW64. It caches the media dependencies, verifies cache hits and
rebuilds the candidate core. The builder generates library hashes automatically;
no SDK URL or SHA256 repository variables are needed.

### Android

The APK contains `arm64-v8a`, `armeabi-v7a` and `x86_64` native slices. Build
the pinned FFmpeg SDK and libass for all three ABIs with
`native/build_android_core_dependencies.py` and
`native/build_android_libass.py`. Set `RILLIGHT_CORE_SDK_ROOT` to their common
root before `flutter build apk`. `tool/android_release_checks.py` audits the
APK and device scenarios; the `.validation` package uses isolated synthetic
credentials. Emulator first-frame events and virtual audio are recorded as
emulator evidence, distinct from a physical phone or TV.

### macOS

`native/build_macos.sh` builds the pinned universal x86_64+arm64 SDK with
libass, dav1d and VideoToolbox. The plugin supports Swift Package Manager
through `macos/rillight_player/Package.swift` and retains its CocoaPods
podspec. Both paths use the same Objective-C++ sources and require
`RILLIGHT_MACOS_CORE_PREFIX`, `RILLIGHT_MACOS_CORE_DYLIB` and
`RILLIGHT_MACOS_CORE_SHA256` before building. The SwiftPM target links the
staged core through Runner's library search path; its copy of
`rillight_core.h` must match the owned native header, as checked by
`macos/verify_bundle_test.py`. Preparation and bundling verify dual-arch
slices, SDK source/hash markers, `@rpath` closure and signatures. A 2026-09-26
Apple M3 host built, packaged and probed that core; GUI playback, physical
audio, actual VideoToolbox decoder use and Intel remain open in
[`macos/TESTING_HANDOFF.md`](macos/TESTING_HANDOFF.md).

PR/main CI and tag releases build the pinned universal SDK and compile the
candidate's owned core without repository artifact variables.
The SDK cache includes source pins, patches, builder/verifier code and Xcode;
every restored SDK is verified, and the core is rebuilt for each candidate.
`macos-native-inputs` preserves the SDK archive, core, hashes and build context.
Library manifests and artifact checksums are generated during the build.

Hosted CI runs sandbox proxy and production playback controls with synthetic
media; screen capture is disabled explicitly. `validation-scope.json` records
control results separately from unverified frames, physical audio and hardware
acceptance. Hardware release checks still require target-device evidence.

## Checks and evidence

Run `flutter test packages/rillight_player/test`, native platform tests and
the top-level Flutter suite for code regressions. The release and performance
evidence contracts are in
[`tool/player_release_evidence.md`](../../tool/player_release_evidence.md).
Build success, dependency audits, installed launch, visible changing frames,
physical audio, synchronization and GPU stability are distinct observations.
