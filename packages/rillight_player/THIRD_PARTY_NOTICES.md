# Native dependencies

The Dart and native adapter code is maintained in this repository under MIT.
The bundled media libraries have their own licenses; the adapter license does
not relicense those binaries. `native/dependencies.json` locks Windows/Linux
binary sources and hashes, vendored header sources, and measured version floors.
macOS dylibs come from IINA's live file list. Distributors must ship applicable
license texts and provide corresponding source under the component licenses.

- **mpv**: https://github.com/mpv-player/mpv (GPL-2.0-or-later, or LGPL when
  explicitly built that way). Windows source build recipes are maintained by
  https://github.com/shinchiro/mpv-winbuild-cmake. macOS dylibs are provided by
  IINA: https://github.com/iina/iina and https://iina.io/dylibs/universal/.
  The full upstream build configuration must be retained when upgrading.
  Linux builds apply `native/patches/mpv-zero-scaler-padding.patch` to the locked
  v0.41.0 commit. It zero-initializes unused scaler LUT channels, preventing
  uninitialized NaN values from contaminating OpenGL filtering. The patch is
  LGPL-2.1-or-later, like the modified upstream file; its SHA256 is recorded in
  `native/dependencies.json` and the installed source-version record. Linux
  bundles include the patch under `data/rillight_player/patches/`.
- **libmpv C API headers**: copied without modification from mpv v0.41.0,
  ISC license and Copyright (C) 2017 the mpv developers preserved in each file.
- **ANGLE**: https://github.com/google/angle (BSD-3-Clause, with third party
  components); fixed Windows distribution by
  https://github.com/alexmercerind/flutter-windows-ANGLE-OpenGL-ES/tree/v1.0.1.
- **FFmpeg**: https://ffmpeg.org/legal.html (LGPL-2.1-or-later; GPL-enabled
  configurations use GPL). Linux build pins n9.0.1. Windows and macOS component
  versions are those in their fixed distributions, not the Dart package version.
- **libplacebo**: https://code.videolan.org/videolan/libplacebo (LGPL-2.1-or-later).
- **libass**: https://github.com/libass/libass (ISC).
- macOS additionally downloads IINA's current universal dylib set, which
  typically includes libarchive, Brotli, libbs2b, dav1d, fontconfig, FreeType,
  FriBidi, HarfBuzz, libjpeg-turbo, libjxl, LittleCMS, LuaJIT, LZ4, MuJS,
  Ogg/Vorbis, Rubber Band, libsharpyuv/WebP, libsoxr, Speex, SVT-AV1, uchardet,
  libudfread, libunibreak, zimg and zstd. The live file list is the authority
  for which libraries ship. Their source and license collection is maintained
  with IINA's dependency build: https://github.com/iina/iina/tree/develop/other
  and its application notices.

The previous media_kit_video implementation was consulted for platform context.
The adapter does not vendor that plugin. Acknowledgement: Copyright © 2021 &
onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>, MIT license
(https://github.com/media-kit/media-kit/blob/main/LICENSE).

The IINA download paths are mutable upstream endpoints. macOS dylibs are
fetched from the live file list at prepare time and are not SHA256-locked in
this repository. Windows archives, Linux sources, vendored libmpv headers and
license texts remain hash-pinned. macOS native execution and signing require a
Mac.
