# Native playback dependencies

Rillight's owned Dart/native player adapter is maintained in this repository.
The native media libraries retain their own licenses. The adapter license does
not relicense those binaries.

The source, version, commit, patch hashes, target ABIs, and required FFmpeg
libraries are declared in [`native/core_dependencies.json`](native/core_dependencies.json).
Each SDK must also carry `rillight-core-dependencies.json`, which records the
actual build configuration and SHA256 of its libraries. The platform packaging
checks verify that marker and the libraries in the candidate package. A source
pin alone does not certify that a bundled binary came from that source.

- **FFmpeg n9.0.1**: [source](https://github.com/FFmpeg/FFmpeg/tree/bf1b838f2ab88b4f8fd83443325c782ea0e0f7fa),
  generally LGPL-2.1-or-later unless the actual build enables components that
  change its license. The bundled configuration and component closure must be
  reviewed for each package. License texts:
  [`FFmpeg-LGPL-2.1.txt`](native/licenses/FFmpeg-LGPL-2.1.txt) and
  [`FFmpeg-GPL-2.0.txt`](native/licenses/FFmpeg-GPL-2.0.txt).
- **libass 0.17.5**: [source](https://github.com/libass/libass/tree/4a05d8127f525943ebf45fdc6497c9e665947f0d),
  ISC. The pinned source's
  [`COPYING`](native/licenses/libass-ISC.txt) is included with subtitle-enabled
  packages (SHA256 `f7e30699d02798351e7f839e3d3bfeb29ce65e44efa7735c225464c4fd7dfe9c`).
  libass has its own build dependencies; the SDK marker records the libraries
  selected for a target. The Android source pins for FreeType, FriBidi and
  HarfBuzz are also recorded in `native/core_dependencies.json`.
- **dav1d 1.5.3**: [source](https://github.com/videolan/dav1d/tree/b546257f770768b2c88258c533da38b91a06f737),
  BSD-2-Clause. It supplies software AV1 decoding when hardware decoding is
  unavailable. The pinned source's [COPYING](native/licenses/dav1d-BSD-2-Clause.txt)
  accompanies packages that bundle dav1d.
- **Android subtitle dependency sources**: [FreeType 2.13.3](https://github.com/freetype/freetype/tree/42608f77f20749dd6ddc9e0536788eaad70ea4b5)
  provides the [license choices](native/licenses/FreeType-LICENSE.txt) and
  [FreeType License](native/licenses/FreeType-FTL.txt);
  [FriBidi 1.0.16](https://github.com/fribidi/fribidi/tree/68162babff4f39c4e2dc164a5e825af93bda9983)
  uses [LGPL 2.1](native/licenses/FriBidi-LGPL-2.1.txt);
  [HarfBuzz 10.4.0](https://github.com/harfbuzz/harfbuzz/tree/3ef8709829a5884517ad91a97b32b9435b2f20d1)
  has its [Old MIT notice](native/licenses/HarfBuzz-Old-MIT.txt). These texts
  were copied from the pinned source commits. The actual linked source and
  license closure must still be checked against each packaged ABI.

Windows, macOS, Linux and Android may additionally use system hardware decode
and output APIs. The release bundle's exact dependency list, loaded versions,
source and license material must be checked for that target. The macOS SDK and
core dylib have not yet been built or exercised on a target Mac; see
[`macos/TESTING_HANDOFF.md`](macos/TESTING_HANDOFF.md). No libmpv or Media3
runtime is part of the owned playback core.
