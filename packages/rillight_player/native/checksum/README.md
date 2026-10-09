# Cache CRC32

`hook/build.dart` compiles this SDK-independent C11 library as a Dart native
asset on Windows, macOS, Linux and Android. No downloaded binary or player
initialization is needed. The checksum remains IEEE CRC32 (not CRC32C), including
the initial/final XOR and incremental seed convention used by zlib.

Runtime dispatch uses CPUID for x86 PCLMUL + SSE4.1, Linux/Android HWCAP for ARM
CRC32, and `hw.optional.armv8_crc32` on macOS ARM. Extended instructions are
restricted to their own functions; no global ISA flag raises the baseline.
Unsupported CPUs use the native software path. There are no device model rules.

The x86 folding function is adapted from the pinned Chromium source documented
in `../../THIRD_PARTY_NOTICES.md`. Its BSD license is shipped with the other
native dependency notices. ARM and software implementations are owned source.

`flutter test test/player/cache_crc32_test.dart` from the repository root builds
and tests the real native asset, including software dispatch, unaligned input,
empty input, incremental seeds, SIMD boundaries and multi-chunk buffers. It
prints the detected backend; a passing test on x86 does not establish ARM or
macOS hardware execution. APK/device throughput measurements remain separate.
