# Native HDR presentation

## Implemented output

| Platform | Current presentation |
| --- | --- |
| Windows, active HDR display | D3D11 conversion to FP16 linear scRGB; native DXGI HWND swapchain; DWM composition with transparent Flutter controls. |
| Windows, SDR display or unavailable HDR host | BGRA8888/sRGB Flutter texture with explicit SDR tone mapping for HDR/Dolby Vision. |
| macOS, screen EDR headroom above 1 | RGBA16Float extended-linear CAMetalLayer behind transparent Flutter. 1.0 is 203-nit SDR white. PQ/HLG/supported Dolby Vision skip 8-bit quantization. Subtitles stay an sRGB plane blended in linear light. |
| macOS, no EDR headroom or Metal layer unavailable | 8-bit BGRA/sRGB Flutter texture. HDR/Dolby Vision uses the portable SDR tone map. `sdrMapped` stays true. |
| Linux | CPU RGBA SDR tone map. Not native Dolby Vision and not HDR. |
| Android, `video/dolby-vision` actually selected | Native Dolby Vision. This is the only native Dolby output. |
| Android, no Dolby MIME | BT.2020 PQ 10-bit when EGL creates that surface, otherwise SDR. Neither is native Dolby. |

Windows selects the native route at player-surface creation. The current output
must report active PQ/BT.2020 and at least 10 bits per component; swapchain scRGB
support is checked separately. SDR white comes from Windows display settings.
Reopen playback after changing HDR policy. Screen migration, display disconnect
and sleep/wake still require separate acceptance.

The swapchain uses R16G16B16A16_FLOAT and RGB_FULL_G10_NONE_P709, including after
resize. scRGB is linear BT.709 with an absolute 80-nit unit. HDR10/PQ, HLG and
supported Dolby Vision RPU conversion retain absolute luminance and signed
wide-gamut components, without SDR tone mapping or 8-bit quantization. DWM maps
this output to the HDR display. RPU processing followed by scRGB is HDR,
not Dolby Vision HDMI signaling or certification. Profile 7 FEL reshapes the
original base, then adds the linear-deadzone residual in that normalized
range; it does not add the residual back into base-layer codes. The Windows
scRGB shader does not sample the enhancement layer, so a FEL frame uses the
portable mapper instead of scRGB. A failed composition is a base-layer
fallback and is not labeled FEL. Profile 5
without a usable RPU is unsupported and is not displayed as HDR10 or YUV.
macOS EDR and the Linux SDR map are not native Dolby Vision.

CPU fallback remains SDR. Hybrid-adapter import failure disables GPU conversion;
the native presenter can map SDR fallback frames to system SDR white. An FP16
destination alone does not establish HDR source output.

## Video, subtitles and UI

A separate nonactivating native video window sits immediately behind the
transparent Flutter player window. DWM composes FP16 video and SDR controls
independently. Impeller remains enabled. The earlier experiment with a DComp
visual underneath Flutter's child HWND was clipped by that child; placing it
above Flutter covered the controls. It is not the production integration.

The native image is initialized to black. Flutter paints its transparent frame
before activating the native layer. The video window follows client bounds,
move, resize, fullscreen, z-order, minimize and restore without taking input
focus. Disposal and engine shutdown hide it before renderer retirement. HWND
destruction remains on its original UI thread.

ASS/PGS subtitles use an immutable cropped premultiplied sRGB plane owned by
the decoded frame. The presenter converts it to linear light at system SDR
white before composing into HDR. Selecting subtitles therefore preserves the
GPU HDR video path. Flutter danmaku and controls remain in the upper window.
Ordinary CPU subtitle composition remains unchanged.

## Ownership, seek and cadence

Conversion waits for its completion query before sharing an immutable GPU
allocation. The Windows HDR path uses no CPU readback; the presenter draws
directly into the swapchain buffer without another full-size delivery copy.
Held frames cannot be overwritten by later conversions.

The additive rillight_core_open_at seeks before decoding/publication. Reference
pictures before the resume target are discarded before conversion. Opening at
zero and seeking after readiness could briefly show a red opening card during
resume. Desktop FFI and Android JNI share the initial-position contract.
Session/timeline is checked again after drawing and before committing so stale
seek work cannot appear.

The shared frame layout and ABI version remain unchanged. HDR configuration
and the subtitle-plane getter are additive APIs. Optional GPU pulls can return
ordinary CPU RGBA fallback; ownership and timeline validation apply to both.
FP16 input is rejected by the SDR Flutter GPU presenter.

Native video presentation is independent of Flutter raster notifications.
hdrSourceFrames counts FP16 draws, including work rejected by a later timeline
check. frames counts committed decoded pictures. Neither proves every displayed
scanout. DXGI frame statistics may become temporarily disjoint on resize or
fullscreen and are usable only when presentStatsValid is true.

## Local Windows evidence: 2026-10-01

The local display reported active 10-bit PQ/BT.2020, approximately 455.5-nit
peak and 240-nit SDR white. Actual server HDR60 and Dolby Vision sources used
D3D11 decode and FP16/scRGB output with visible changing pictures and subtitles.
Pause/resume, seek and fullscreen were exercised. The Dolby Vision source was
approximately 25 fps, not a 60-fps sample.

A separate HDR60 run exercised four rate changes, minimize/restore, resize,
maximization and fullscreen. A local compatible danmaku fixture provided 240
synthetic comments. Composed desktop screenshots showed comments, subtitles
and controls over video after rate changes and window restore. Timeline, media
clock and submitted pictures continued advancing, with no native surface
error. This verifies rendering, not the user's external danmaku service.

A slow-start HDR60 run delayed metadata and media requests by eight seconds
each. Its first reported position was the requested resume position; 1646
captured native-video frames contained no detected red spikes. The detector
cannot prove absence of every intermittent flicker.
The same delayed Dolby Vision resume captured 621 frames with no detected red
spikes, starting at the requested resume position.

Ignored evidence under build/:

- hdr-native-core-regression.log: five native core cases, including FP16
  HDR/DV color readback and owned-core HDR ASS plane lifetime.
- hdr-native-present-tests.log: five Windows cases, including highlight
  preservation, linear subtitle blending and HDR-to-SDR rejection.
- hdr-native-dart-regression.log: 64 settings, album, recovery and danmaku
  controller cases.
- hdr-native-android-core-build.log: Android arm64 core compilation, not
  Android HDR or device playback.
- native-hdr-native-hdr-4019933-player.log and cadence log: HDR60 seek/fullscreen,
  approximately 56.6 changed captured fps.
- native-hdr-native-hdr-4019917-player.log and cadence log: Dolby Vision,
  approximately 25.1 changed captured fps. FFmpeg bitstream/RPU warnings remain;
  the run does not establish warning-free support for all profiles.
- native-hdr-lifecycle-4019933-player.log, cadence log and
  hdr-lifecycle-4019933-*.png: rates/window lifecycle and visible synthetic
  danmaku, approximately 56.5 changed captured fps.
- hdr-native-slow-start-4019933-22337750000-summary.json and matching video:
  delayed HDR60 resume with no detected red spikes.
- hdr-native-slow-start-4019917-22337750000-summary.json and matching video:
  delayed Dolby Vision resume with no detected red spikes.
- presentation-reference-run.log and capture log: independent native 60-Hz
  reference presented about 59.4 fps while WGC captured about 56.7 fps.

WGC of the transparent Flutter HWND captures UI separately from native video.
Use the native video HWND for cadence and a composed desktop region for
video plus controls/danmaku. SDR screenshots cannot measure physical HDR
luminance or reproduce its full gamut. WGC itself missed frames in the native
reference. Current evidence does not establish stable 60-fps final scanout,
physical peak brightness, absence of every flicker, or physical audio output.

## Remaining platform work

| Platform | Native HDR requirements |
| --- | --- |
| macOS | Metal FP16, extended linear color space and EDR; current-screen headroom and migration/fullscreen/brightness checks. |
| Linux | Vulkan/Wayland with negotiated compositor color management and HDR swapchain; explicit SDR on X11/SDR compositors. |
| Android phone/TV | High-precision native Surface, matching PQ/HLG dataspace, display capability and EGL/Vulkan negotiation; API 24 SDR and lock/wake/navigation lifecycle. |

Compilation, parsed HDR metadata and hardware decode selection do not
establish native HDR presentation on these targets. FFmpeg's standalone
Android MediaCodec decoder does not export per-frame RPU. Automatic Profile 5
playback uses software HEVC; hardware-only requests fail explicitly.

## References

- [Microsoft: Advanced Color and HDR](https://learn.microsoft.com/en-us/windows/win32/direct3darticles/high-dynamic-range)
  recommends FP16/scRGB and separate checks of active display state.
- [Microsoft: SetColorSpace1](https://learn.microsoft.com/en-us/windows/win32/api/dxgi1_4/nf-dxgi1_4-idxgiswapchain3-setcolorspace1)
  defines swapchain output color-space selection.
- [Microsoft: Flush](https://learn.microsoft.com/en-us/windows/win32/api/d3d11/nf-d3d11-id3d11devicecontext-flush)
  is asynchronous; completion queries establish producer readiness.
- [Microsoft: OpenSharedResource](https://learn.microsoft.com/en-us/windows/win32/api/d3d11/nf-d3d11-id3d11device-opensharedresource)
  defines sharing and producer flush requirements.
- [Flutter Windows external D3D texture](https://github.com/flutter/flutter/blob/master/engine/src/flutter/shell/platform/windows/external_texture_d3d.cc)
  calls the release callback before reading descriptor dimensions. The SDR
  descriptor outlives the callback; the callback is not a display fence.
