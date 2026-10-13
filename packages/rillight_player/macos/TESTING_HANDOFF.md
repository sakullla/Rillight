# macOS aggregation/private-region handoff

## Compressed PGS subtitle regression

The FFmpeg builder explicitly enables zlib despite disabled autodetection.
SDK verification rejects missing/disabled zlib on macOS, Windows and Android
(Linux also requests it explicitly). Run the native `rillight_bitmap_subtitle`
test against the rebuilt universal SDK: it demuxes an in-memory Matroska track
with zlib-compressed PGS, decodes it, and checks visible scaled pixels.
On both Intel and Apple Silicon, select a compressed Simplified Chinese PGS
track and verify visible subtitles during playback, seeking and resizing.
Record the actual loaded SDK hashes and displayed frames separately.
Current macOS build and actual-window subtitle results: **unverified** on the
Windows development host.

## GPU texture presentation validation

The candidate imports VideoToolbox NV12/P010 planes with CVMetalTextureCache,
converts SDR/PQ/HLG or Dolby RPU on Metal, and retains an IOSurface-backed output
through GPU fitting, rotation/SAR and subtitle composition. Flutter SDR textures
and the extended-linear Metal presenter consume the completed GPU output without
video-pixel readback. Cropped subtitle rasterization/upload remains CPU work.
Unsupported imports/conversion retain the mapped/downloaded portable fallback;
presentation fallback is counted separately. Software decoding and FEL CPU
reconstruction are not reported as a direct GPU route.

Enable `RILLIGHT_CORE_GPU_TESTS=ON` and run
`rillight_macos_hardware_video_route`, `rillight_macos_color_pipeline` and
`rillight_macos_texture_pipeline`. Check retained output across converter/window
teardown, immutable paused subtitle redraw, padded rows, rotation/SAR, source
size changes, seek and reopen. Compare pixels against the portable reference;
readback inside a pixel test is not part of production GPU presentation.

On the target system, record `cvmetal-direct-linear` / `cvmetal-direct-sdr`,
`mapped+metal-linear` / `mapped+portable-linear`, presenter fallback counts,
actual decoder, changing window frames and physical output separately. Keep
machine information, paths, hashes and raw evidence under ignored `build/`.
Do not infer physical HDR, audio or a performance improvement from the native
contracts or a submitted Metal command. Use identical media, window dimensions
and build mode when collecting comparative measurements.

## v0.1.55 digital audio output

The candidate adds exclusive Core Audio HAL output for IEC 61937 AC-3,
E-AC-3/JOC, DTS, DTS-HD and TrueHD. Only explicitly advertised digital physical
formats with matching carrier rate/layout are eligible. Ordinary speakers,
Bluetooth, float-only paths and unavailable digital formats remain decoded PCM.
JOC/TrueHD data is preserved but Atmos is not inferred from generic device
formats. A downstream receiver can still reject a codec after the driver
accepts the carrier; software queue progress cannot prove physical sound.

The audio worker owns device/format changes and a bounded single-producer,
single-consumer buffer; the HAL callback only copies queued bytes and publishes
timing. Failures retire the compressed output, restore device state and revoke
that codec's acceptance for the route before reopening PCM. A real default
device change permits a fresh probe. No forced PCM-as-bitstream workaround is
used. Pause, seek, stream changes and shutdown reset queued compressed bursts.

Host-portable checks exercise packet sample counts, byte preservation,
queue wrap/backpressure/concurrency, Linux route rejection and a virtual
PulseAudio sink. The dedicated `Native audio contracts` workflow compiles the
actual macOS header against Apple frameworks and tests format rejection without
claiming speaker output. Hosted package/control CI remains a separate check.

On a physical Mac (both Intel and Apple Silicon where available), record the
candidate/package hash, HDMI/USB receiver, advertised physical/virtual formats,
actual receiver codec indicator and audible output for each supported format.
Check stereo PCM fallback, busy device/hog failure, unplug/replug and switching
between two devices with the same channel count, pause/resume, seek, track
changes, and close/reopen. Verify another application can use the device after
close and that its original physical format and mixing state were restored.
Measure lip-sync separately. Current physical passthrough result: **unverified**.
Also verify application mute and non-unity volume switch to PCM, and restoring
100% permits passthrough again. Receiver volume remains independent.

## Target-machine procedure

Use macOS 12+ and the pinned verified universal SDK/core artifact described by the package README. Record the candidate commit, built package and native dependency hashes, machine/OS/GPU, the actually loaded decoder/libraries and raw logs under ignored `build/`. Use disposable synthetic server credentials only.

1. Create two independently authenticated Emby services A/B with a common provider identity, explicit participating library scope, distinct media-version IDs, two verified same-server lines and differing editions/durations/audio/subtitle languages. Leave a third service's scope unknown; verify it is not automatically included.
2. In the actual desktop UI, find and compare the work, open B in the independent player window, observe changing displayed frames and physical sound, and verify B's actual version/line/account in the local ordered history. Check that A's active browsing/login does not change.
3. Switch a same-server line, an edition and a cross-server source separately. Record real position/pause intent and target language/bitrate. Test timeline confirmation/cancel, missing-language selection, identity mismatch, target failure and explicit permitted-original restoration; no automatic cross-server failover or silent clamping is acceptable.
4. Set a PIN through UI, lock, cancel/error/rate-limit/unlock, then restart the packaged app and verify locked startup. Open private detail/search/compare/settings overlays and exercise back/forward. No private name, address, source count, card, image or history may remain in the ordinary projection after lock, including with private unlocked earlier.
5. During a pending switch and during playback, move a service ordinary→private and lock private. Record main/helper PIDs, generation, close-budget timing and mailbox acknowledgements. The helper must stop/exit or be terminated within the configured budget; stale observations, snapshots, image requests, reports and restoration/retries must be rejected. Migration failure must remain explainable, not auto-resume playback.
6. Repeat with mouse/keyboard and at a narrow window. Separately retain display-frame capture, speaker observation, actual decoder evidence and GPU stability. A first-frame event, fake backend or virtual audio sink does not establish these facts.

Keep target results unverified until the candidate is measured. Do not substitute prototype captures or a configured CI job for target observations.
