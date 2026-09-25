# Direct FFmpeg core development check

The source build currently supports Linux x86_64. It builds FFmpeg from the
commit pinned in `../core_dependencies.json`; the core links directly to its C
libraries. The old libmpv bundle is not a usable SDK for this check.

Install `git`, `make`, a C/C++ compiler, `cmake`, `pkg-config`, `nasm`, and
Python 3 in a Linux build environment, then run from the repository root:

```sh
python3 packages/rillight_player/native/build_core_dependencies.py \
  --prefix "$PWD/build/core-sdk" --work "$PWD/build/core-source" --jobs 4
python3 packages/rillight_player/native/verify_core_dependencies.py \
  --prefix "$PWD/build/core-sdk" --target linux-x64
cmake -S packages/rillight_player/native -B build/core-test \
  -DRILLIGHT_CORE_PREFIX="$PWD/build/core-sdk" -DCMAKE_BUILD_TYPE=Release
cmake --build build/core-test --parallel 4
ctest --test-dir build/core-test --output-on-failure
```

The Linux CTest target sets `LD_LIBRARY_PATH` only for its process so the
loader can find FFmpeg's transitive libraries in the verified SDK prefix.
Release packaging must provide its own complete library closure and RUNPATH.

`core_test.cpp` constructs PCM WAV and RGB BMP media in memory. The test
requires the real pinned FFmpeg libraries and exercises decoding, stream
metadata, first-frame readiness, pause, seek, 2.0x audio sample reduction,
stale operation rejection, session change, EOF drain, frame ownership, and
strict hardware failure versus explicit software fallback. A controlled IO
read blocks after decoded audio is ready; seek must cancel that old read,
produce frames on the new timeline, and tolerate a second seek. A gated EOF
read checks that seeking while old EOF is pending cannot publish old EOF or
accept a premature output-drained report on the new timeline.
When the SDK contains the pinned libass build, `ass_test.cpp` constructs a
Matroska MPEG-4/ASS stream entirely in memory and checks that text changes
decoded RGBA pixels. It also adds an external ASS script through controlled IO,
checks failed reads and invalid scripts preserve the selected subtitle and
timeline, selects the external track, and checks its blue text changes pixels.
An independent blocked subtitle read then checks pause, seek, first video
output, and bounded destroy/cancellation while that loader is still waiting.
The text fixture also muxes SRT and WebVTT tracks and checks actual selection
and subtitle pixels after switching away and back. Its non-square pixel ratio,
display matrix, and BT.709 tags exercise the versioned frame metadata. A
slow external ASS read makes progress for more than five seconds, then returns
EAGAIN; it must be judged by time since last progress.
This is a native composition check, not a Flutter surface or font coverage
check; the build environment must provide a usable sans-serif font.
The test prints the actual loaded FFmpeg library versions. CMake rejects an
SDK whose manifest or library hashes do not pass
`verify_core_dependencies.py`. `--all-platforms` additionally requires real
SDK prefixes for Windows, macOS, and the Android ABIs; it must fail when those
SDKs are absent.

The current core is a development implementation. It reports decoder hardware
configurations separately from actual hardware use. A requested FFmpeg hardware
device is tried when the codec supports it; the caller chooses whether missing
device/configuration permits software fallback. `actual_hardware` changes only
after a hardware frame is actually decoded and transferred. The synthetic BMP
test has no hardware decoder and therefore proves fallback/strict failure, not
GPU decoding on target hardware.
It decodes and blends embedded bitmap subtitles, and routes audio through
FFmpeg `atempo` and `aformat` with automatic resampling. A conditional libass
path processes embedded ASS events and font attachments plus decoded SRT and
WebVTT text, then blends libass images into decoded video. External ASS/SSA
scripts can be added asynchronously
through a separate, cancellable controlled-IO loader and selected by their
synthetic track indices. Callback owners must support concurrent media and
subtitle handles; `cancel` must release both on close. Each
media read has a separate prompt `cancel_media_read` signal for seek and track
changes; its callback must not call core APIs or wait for worker progress.
The transport must leave the media handle reusable after that read is
interrupted and seek resets its state. Each
script is limited to 4 MiB, with 16 tracks and 16 MiB per session. Invalid
external scripts and IO errors leave the selected track and timeline intact;
other external subtitle formats, direct hardware frame import, and verified
platform output remain required before product playback can use it. The base
SDK command above omits libass; compile and run the
separate ASS-enabled build below before claiming that path has been exercised.

To build the ASS/SSA path, the Linux builder accepts `--with-libass`. This
requires Meson, Ninja, and development packages exposing `freetype2`,
`fribidi`, `harfbuzz`, and Fontconfig 2.10.92 or later through `pkg-config`,
plus an installed sans-serif font for the composition test. On Debian or
Ubuntu, install `libfontconfig1-dev` for the Fontconfig headers and metadata.
libass 0.17.5 defaults to requiring a system font provider; the Linux builder
explicitly enables Fontconfig and retains that requirement. The builder shallow-fetches
libass 0.17.5 at the pinned commit, verifies its tag, builds the shared library,
and records its file hash and dependency versions in the SDK manifest. Then
run `verify_core_dependencies.py --prefix "$PWD/build/core-sdk" --target
linux-x64 --require-subtitles` before configuring CMake. An image with these
prerequisites is needed for this optional build. Its transitive release library
closure also remains to be pinned and verified.

The pinned libass 0.17.5 Meson project explicitly warns that its non-Windows
shared-library build does not provide suitable symbol visibility for
distribution. `verify_core_dependencies.py` checks pinned metadata, headers,
and file hashes for development tests; it does not certify this SDK for a
release, audit transitive runtime libraries, or establish an ELF/RUNPATH
closure. Release packaging must resolve the libass build method or upstream
visibility limitation before using it as a distributable playback dependency.

From the repository root, run the ASS-enabled check in a separate prefix:

```sh
python3 packages/rillight_player/native/build_core_dependencies.py \
  --prefix "$PWD/build/core-ass-sdk" --work "$PWD/build/core-ass-source" \
  --jobs 4 --with-libass
python3 packages/rillight_player/native/verify_core_dependencies.py \
  --prefix "$PWD/build/core-ass-sdk" --target linux-x64 --require-subtitles
cmake -S packages/rillight_player/native -B build/core-ass-test \
  -DRILLIGHT_CORE_PREFIX="$PWD/build/core-ass-sdk" -DCMAKE_BUILD_TYPE=Release
cmake --build build/core-ass-test --parallel 4
ctest --test-dir build/core-ass-test --output-on-failure
```
