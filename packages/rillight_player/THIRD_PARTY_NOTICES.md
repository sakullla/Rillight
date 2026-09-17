# Native dependencies

The Dart and native adapter code is maintained in this repository under MIT.
The bundled media libraries have their own licenses; the adapter license does
not relicense those binaries. `native/dependencies.json` locks binary sources,
hashes, header sources and measured versions. Distributors must ship applicable
license texts and provide corresponding source under the component licenses.

- **mpv**: https://github.com/mpv-player/mpv (GPL-2.0-or-later, or LGPL when
  explicitly built that way). Windows source build recipes are maintained by
  https://github.com/shinchiro/mpv-winbuild-cmake. macOS dylibs are provided by
  IINA: https://github.com/iina/iina and https://iina.io/dylibs/universal/.
  The full upstream build configuration must be retained when upgrading.
- **libmpv C API headers**: copied without modification from mpv v0.41.0,
  ISC license and Copyright (C) 2017 the mpv developers preserved in each file.
- **ANGLE**: https://github.com/google/angle (BSD-3-Clause, with third party
  components); fixed Windows distribution by
  https://github.com/alexmercerind/flutter-windows-ANGLE-OpenGL-ES/tree/v1.0.1.
- **FFmpeg**: https://ffmpeg.org/legal.html (LGPL-2.1-or-later; GPL-enabled
  configurations use GPL). Linux build pins n8.0.1. Windows and macOS component
  versions are those in their fixed distributions, not the Dart package version.
- **libplacebo**: https://code.videolan.org/videolan/libplacebo (LGPL-2.1-or-later).
- **libass**: https://github.com/libass/libass (ISC).
- The macOS lock additionally includes libarchive, Brotli, libbs2b, dav1d,
  fontconfig, FreeType, FriBidi, HarfBuzz, libjpeg-turbo, libjxl, LittleCMS,
  LuaJIT, LZ4, MuJS, Ogg/Vorbis, rav1e, Rubber Band, libsharpyuv/WebP, libsoxr,
  Speex, SVT-AV1, uchardet, libudfread, libunibreak, zimg and zstd. Their source
  and license collection is maintained with IINA's dependency build:
  https://github.com/iina/iina/tree/develop/other and its application notices.

The previous media_kit_video implementation was consulted for platform context.
The adapter does not vendor that plugin. Acknowledgement: Copyright © 2021 &
onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>, MIT license
(https://github.com/media-kit/media-kit/blob/main/LICENSE).

The IINA download paths are mutable upstream endpoints. Hash mismatches fail
closed; update the entire lock after checking new upstream versions, rather
than weakening verification. macOS native execution and signing require a Mac.
