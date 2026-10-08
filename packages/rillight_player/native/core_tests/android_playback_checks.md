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

A matching component and frame-rendered callbacks do not establish correct
Dolby color. An independent device probe reproduced green/purple Profile 5
buffers even with a matching HEVC Dolby component. A tunneled probe established
a `SIDEBAND` compositor layer and consecutive render callbacks, but its output
was not capturable (`PixelCopy` reported no source data). Neither a black system
screenshot nor these callbacks validate the physical color of that path.
Keep native tunneling unverified until actual output and audio synchronization
are checked; do not enable it on the basis of the decoder name alone.

## Local continuation, 2026-10-08

The profile validation APK with SHA256
`A5F20C3297322B5BCE0DA43B541D908F34202F6C7F9920B68511A4006786D14D`
was retained for the following observations on API 30 / Mali-G31, at a
59.94 Hz display mode. These are local observations, not release acceptance.

- HDR 60fps / DDP: 1,756 compositor timestamps over 29.683 seconds,
  59.12 fps, maximum gap 50.05 ms. Nine intervals exceeded 34 ms. A separate
  startup-inclusive sample contained a 2.42-second gap; do not call startup
  or sustained 60fps solved. Earlier steady samples were 57.46 and 58.52 fps;
  differing durations and cache state prevent a controlled speedup claim.
- Dolby / DDP: 154 compositor timestamps over 13.447 seconds, 11.38 fps,
  maximum gap 133.67 ms. A real system capture showed normally colored
  SDR-mapped output. Download observations were approximately 12–14 MB/s,
  with one read-ahead transfer. This does not establish physical HDR output
  or audio. A catalog request initially timed out after 15 seconds; retry
  succeeded before decoder opening, so that failure was not a Dolby decoder
  rejection.
- Independent GPU experiments were rejected, with no production shader
  changes: removing the HDR branch or reducing precision in SDR tone mapping
  changed roughly 102 ms/frame to 99 ms/frame; splitting the shader into two
  passes took roughly 104 ms/frame. Hardware-trilinear lookup of the entire
  transform reached roughly 48 ms/frame with a 65-cubed table, but failed the
  existing color test (P010, polynomial mode 0, level 127, chroma 120/148:
  15 code values of error versus the allowed 3). These are offscreen timings
  from a fixed captured buffer, not application playback measurements.

Keep color correctness tests unchanged when evaluating approximations. A faster
lookup that blends across piecewise RPU boundaries is not a valid replacement
for the existing polynomial/MMR path. Native tunneled output still requires
actual color and synchronization evidence before it can replace conversion.

Additional checks on the same installed candidate:

- This episode's DV AAC-UBWEB and DV AV35-DDHDTV versions also opened and
  produced colored SDR-mapped captures: 11.51 fps over 13.814 seconds and
  11.52 fps over 13.363 seconds respectively. Together with DV DDP5-SonyHD,
  these observations rule out a problem exclusive to the DDP-labelled version;
  they do not establish results for unrelated encodes or Dolby profiles.
- A local 1080p re-encode retained RPU metadata on all 80 frames. Using the
  same installed core in an independent Surface probe, 1080p input/output
  produced 12.27 fps versus 11.27 fps for 4K input/1080p output. Reducing the
  color output to 720p produced 22.91 fps (76 frames), and 540p produced
  25.01 fps (all 80 frames). Short local probes exclude streaming and UI
  costs. No resolution cap was added to production.
- Flutter regression: `flutter test --no-pub` passed 1,531 tests with two
  platform skips. The Dolby patch helper tests passed all three cases.

### External implementation references

Read on 2026-10-08; upstream branches can change:

- [AOSP multimedia tunneling](https://source.android.com/docs/devices/tv/multimedia-tunneling)
  describes direct decoder-to-display output, sideband HWC layers, and the
  timestamped `AudioTrack` / audio-session synchronization contract. Render
  callbacks alone do not prove physical color or audible synchronization.
- [Android HDR playback](https://developer.android.com/media/grow/hdr-playback)
  recommends `MediaCodec` with `SurfaceView`; `TextureView` HDR has additional
  restrictions and may tone-map on newer Android versions.
- [Kodi Android MediaCodec](https://github.com/xbmc/xbmc/blob/master/xbmc/cores/VideoPlayer/DVDCodecs/Video/DVDVideoCodecAndroidMediaCodec.cpp)
  deliberately attempts a matching Dolby decoder for Profile 5 even when
  the display does not declare Dolby support. Therefore absent display Dolby
  capability is not, by itself, proof that hardware tone mapping is impossible.
- [Media3 codec selection](https://github.com/androidx/media/blob/release/libraries/exoplayer/src/main/java/androidx/media3/exoplayer/mediacodec/MediaCodecUtil.java)
  excludes Profile 5 from ordinary HEVC compatibility fallback. A native Dolby
  decoder is different from interpreting the Profile 5 base as ordinary HEVC.

A further independent ordinary-Surface probe used the matching HEVC Dolby
decoder, BT.2020/PQ color keys, and explicit non-tunneled mode. Input access
units contained VPS/SPS/PPS and RPU NAL 62; `PixelCopy` still showed green/purple
output on the AV35 sample. AAC also decoded with RPU present, but its captured
opening logo lacks a matched color reference. This rules out missing RPU in
those specific probes, not other vendor configuration requirements. Tunneled
AAC produced about 24.66 callbacks per second over 200 consecutive callbacks;
`PixelCopy` still reports source-no-data and requires a physical check.

### Native tunnel physical feedback and follow-up research

The user subsequently confirmed that the native tunneled probe looked smooth,
but remained green/purple. This establishes a subjective smoothness improvement
for this short looping sample, not correct Dolby output or general playback
acceptance. The user explicitly requested retaining native tunneling despite
the unresolved color issue; these checks do not establish color correctness.

A follow-up diagnostic supplied a 24-byte `csd-2` configuration record matching
the independently inspected Profile 5 / BL+RPU / 2160p25 fixture (level 7).
The selected component remained the advertised HEVC Dolby decoder and render
callbacks continued, but the user again reported green/purple. This rejects
that particular configuration change as a sufficient fix. Merely logging
`csd-2` in the configured format does not prove that the vendor consumed it.
The fixture-specific configuration exists only in the ignored diagnostic probe,
not in production stream detection or decoder policy.

During native playback, both the display API and hardware composer advertised
HDR10 without Dolby display support; SurfaceFlinger reported `HDR current type:
SDR` despite a live SIDEBAND layer. These are observations about the connected
output chain, not proof that the decoder hardware lacks Dolby capability or
that hardware Dolby-to-HDR10/SDR conversion is impossible.

Additional sources read on 2026-10-08:

- [Android 11 Stagefright metadata conversion](https://github.com/LineageOS/android_frameworks_av/blob/lineage-18.1/media/libstagefright/Utils.cpp)
  defines the 24-byte Dolby configuration record, profile/level extraction and
  `csd-2` metadata mapping. This motivated the diagnostic, not a verified fix.
- [Media3 issue 2024](https://github.com/androidx/media/issues/2024)
  describes the analogous Profile 5 decoder / non-Dolby display combination;
  its comments do not demonstrate a solution.
- [ExoPlayer issue 9794](https://github.com/google/ExoPlayer/issues/9794)
  discusses preferring ordinary HEVC for compatible Dolby streams when the
  display does not support Dolby. That is not a valid substitute for Profile 5
  IPT conversion; the stream's base-layer compatibility must be checked.
- [Public Amlogic Dolby driver](https://github.com/khadas/common_drivers/blob/master/drivers/media/enhancement/amdolby_vision/amdv.c)
  contains hardware Dolby-to-HDR10/SDR output policies. It demonstrates that
  such hardware paths exist in some implementations, not that this firmware
  enables them or exposes an ordinary application API. Its Dolby HDMI tunnel
  modes must not be confused with Android MediaCodec tunneled playback.

Native tunneling integration was subsequently started at the user's request.
The build40 profile APK compiles, but its playback lifecycle and fallback paths
have not yet been validated on the device. The retained installed validation
APK is build35; compilation does not establish acceptance of build40.

### Official device OTA, 2026-10-08

The Box R 4K Plus accepted its own official OTA from Android 11 build
`RTT0.211009.001.5554` to Android 14 / API 34 build `UKG3.250803.001.8963`
(security patch `2026-04-05`). After reboot, `sys.boot_completed=1`, the boot
animation stopped, and a device screenshot showed the TV launcher. Existing
production and validation application packages remained installed. No factory
reset or firmware from another model was used.

Download required a temporary USB reverse connection to the host's HTTP proxy
and an Android VPN restricted to Google update/download services. DNS worked
with the VPN's mixed stack, but TCP forwarding stalled. Changing only the stack
to gVisor in the otherwise identical IPv4-only diagnostic profile restored OTA
traffic. Early connections ended with `ERR_CONTENT_LENGTH_MISMATCH`; the official
updater resumed and completed the 1.29 GB package. Temporary VPN, global proxy
settings and host relay processes were stopped/cleared after the update.

These observations verify firmware installation and boot only. Dolby colors,
tunneled playback lifecycle and HDR performance require fresh checks on this
firmware; the preceding Android 11 playback measurements do not establish them.

### Native tunnel retest on Android 14 / 8963

The temporary `io.nekohasekai.sfa` VPN application was uninstalled successfully
at the user's request. Both global HTTP proxy and always-on VPN settings are
null. The native probe was then rerun with the application players stopped.

The old diagnostic MP4 remuxes contained a `dvh1` sample entry but omitted
`dvcC`; Android 14's extractor exposed no video track. Adding the independently
known fixture's P5/L7/BL+RPU record restored extraction. The encoded `mdat`
payload was byte-for-byte unchanged. This fixture repair is confined to ignored
diagnostics and is not a production override of media metadata.

With explicit BT.2020/PQ keys, the selected decoder was
`c2.amlogic.dolby-vision.dvhe.decoder`, with a live SIDEBAND layer. The last
750 render callbacks spanned 29.950 seconds (25.009 callbacks/second), median
gap 40 ms, maximum 80.62 ms, with nine gaps over 60 ms in the short looping
fixture. These callbacks do not prove smooth physical playback. PixelCopy
returned 3 (source-no-data), and the system screenshot could not capture video.

The user confirmed that the physical picture remained green/purple after the
upgrade. SurfaceFlinger reported HDR10/ST2084 output and no Dolby-capable sink.
This is evidence that upgrading alone did not fix the observed color problem,
not proof that the box lacks a Dolby hardware decoder. A second diagnostic
preserved the extractor's full source format and omitted manually forced color
keys. It sustained 25.024 callbacks/second across 750 callbacks / 29.931 seconds,
but the user again confirmed green/purple. Neither passing the full source
format nor omitting forced color keys was sufficient to fix physical output.
The diagnostic loop was stopped after both checks; the application tunnel
integration remains unvalidated, and these results do not establish a color fix.

### Release boundary for v0.1.45

The unfinished native tunnel integration is retained behind the explicit Android
Gradle property `rillightExperimentalNativeTunnel=true` (Flutter build argument
`--android-project-arg=rillightExperimentalNativeTunnel=true`). The property
defaults to false, including tag builds. Ordinary releases retain the compatible
decoder/color path; the experimental path is not advertised as a Dolby color
fix. In-app pause, seeking, rate changes, end-of-stream and surface lifecycle
still require validation before enabling it by default.
