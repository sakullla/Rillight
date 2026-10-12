# Android device regressions

Configure the Android native build with `RILLIGHT_CORE_GPU_TESTS=ON` to build
`rillight_android_color_pipeline_test` and
`rillight_android_runtime_fallback_test`. Run them on a connected device with
the same verified SDK shared libraries in `LD_LIBRARY_PATH`. These tests need
actual Android MediaCodec/GLES support, not a host unit-test JVM.

The color test compares GPU output against the portable CPU RPU conversion for
P010 and NV12, alternating formats and polynomial/MMR orders 1–3 on one output
Surface. It checks 1,296 samples across nine chroma pairs (including neutral,
saturated and near-boundary values), twelve levels and nine pivots, allowing at most three
8-bit code values of difference. The offscreen test does not certify physical
HDR/Dolby output, source playback throughput, or audio.

Generate the software-fallback fixture under ignored `build/`:

```sh
ffmpeg -f lavfi -i testsrc2=size=96x64:rate=25 -t 6 -an \
  -c:v libx264 -g 30 -bf 2 -pix_fmt yuv420p build/fallback-h264.mkv
```

Pass its absolute device path to `rillight_android_runtime_fallback_test`.
Only this test translation unit injects one failed MediaCodec send after 17
successful packets. The test requires a new timeline, an actual software
backend, increasing timestamps, and over 60 distinct software-decoded frames.
This proves recovery from a running decoder failure, not 4K software speed.

Repeat with `--presentation` after the fixture path to inject consecutive
hardware presentation failures. It verifies that stale sessions/timelines are
ignored, successful presentation resets the failure count, and three current
failures recover through a new timeline and changing software frames. This
tests the recovery contract; it does not emulate every vendor EGL failure.

For Profile 5 device acceptance, additionally play a clip containing inter
frames. A correct first I-frame does not validate a vendor byte-output path:
some devices advertise NV12 but return corrupt inter-frame planes. Compare
multiple real frames through the private Surface/RPU path against software
reference output, and separately sample compositor frame presentation. Check
seek, subtitle redraw, exit/reopen, navigation, and screen sleep/wake. Keep
personal source media and captures under ignored `build/`.

Native Dolby selection must match the stream's Android `CodecProfileLevel`,
not only `video/dolby-vision`: the same MIME can expose separate HEVC, AVC and
AV1 components. Check that the JNI bridge registers the VM before opening the
first decoder, then verify the selected component advertises the requested
profile. Missing capability must fail selection rather than retrying an
unqualified MIME match. `python packages/rillight_player/native/android_dovi_patch_test.py`
covers the locked selection helper, including an AVC-first codec catalog.

A matching component or render callback does not prove Dolby color correctness.
Verify physical output against a known reference before qualifying a native or
tunneled path. Profile 5 cannot be displayed as an ordinary HEVC/HDR10 base.

## Filtered-plane and diagnostic regression

The color test also compares nonuniform resized P010/NV12 input with the integer
reference. Run with `--benchmark` for a synthetic upload/mapping/readback comparison.
P010 normalized filtering requires `GL_EXT_texture_norm16`; an unsupported device
must retain the integer path, not reduce precision. Do not count identical fallback
routes as a performance improvement.

Check that Android output events include decoder/source diagnostics, only current
session/timeline data is accepted, and a diagnostic-only change advances the epoch.
The GLES `submit` sample includes submission/backpressure, not GPU execution time.

## References

- [Android HDR playback](https://developer.android.com/media/grow/hdr-playback)
- [AOSP multimedia tunneling](https://source.android.com/docs/devices/tv/multimedia-tunneling)
- [Android NDK media and image lifetime](https://developer.android.com/ndk/reference/group/media)
- [Khronos EXT_YUV_target](https://registry.khronos.org/OpenGL/extensions/EXT/EXT_YUV_target.txt)

Keep per-device observations, media identifiers, addresses, artifacts and timing
samples under ignored `build/`; this document defines the reproducible checks.
