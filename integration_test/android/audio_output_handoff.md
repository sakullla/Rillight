# Android TV audio output fixes — 2026-10-10

Working-tree changes based on `e415dfa75dd9517a8d91622e4f48f5e0cdaf1d09`
(v0.1.54). This is development evidence, not release or hardware acceptance.

## Confirmed defects and changes

- Ordinary E-AC-3 used native format ID 3, but Android only mapped IDs 1 and 2.
  Compressed bytes could therefore reach a PCM AudioTrack. Map every known
  native format explicitly and reject unknown formats or untimed compressed
  frames so the core can decode PCM.
- Recognize ordinary E-AC-3 independently of JOC/Atmos and check the active
  route before accepting compressed output. Clear the rejected format's own
  capability bit and retain that rejection on the same route.
- Pass the source output sample rate across JNI rather than assuming 48 kHz.
  Update the JNI constructor, R8 retention rule and APK audit together.
- Use AudioTimestamp to account for hardware presentation latency beyond the
  PCM consumed-frame counter, with bounded timestamp validation and fallback.
  The core can hold its monotonic clock while delayed audio catches up, instead
  of retaining the initial video lead forever.
- Sync staged SDK libraries to the selected ABIs so a previous build cannot
  leave stale native libraries in a single-ABI APK.

## Target-device observations

Device: Box_R_4K_Plus / SEI804HM, Android 14, 32-bit armeabi-v7a, HDMI to a TV
using its built-in speakers. Tests used the disposable `.validation` package
and synthetic local media; no production credentials were copied.

Before the mapping fix, switching to E-AC-3 created a PCM output whose server
frame count did not advance. The test build opened E-AC-3 as `0x0a000000` and
consumed its queue. AAC, AC-3, E-AC-3, DTS, TrueHD, FLAC, PCM and Opus synthetic
clips completed the first control/progress matrix, including AAC → E-AC-3 →
AAC and seek. That run established control/queue progress, **not physical sound**.
Its first output-status capture used the wrong diagnostic endpoint; null clock
fields from that run must not be interpreted as clock results.

A subsequent PCM test reported an active hardware clock, roughly 140 ms of
hardware delay and no underruns. This establishes use of the presentation
timestamp, not measured lip-sync accuracy.

The user heard DTS when decoded to PCM in the comparison test. That experiment
used 1.01x speed to select the existing PCM path. Raw DTS passthrough was silent
at the same test volume, as was an independent IEC 61937 test using FFmpeg's
SPDIF muxer. Successful AudioTrack writes did not establish audible output.
The vendor log reported DTS-HD output during the raw DTS experiment, but this
alone does not prove the cause of silence. DTS investigation was deferred by
the user. The final change retains Android's previous decoded-PCM policy for
DTS/DTS-HD; the experimental automatic DTS passthrough path is not enabled.
No new PCM preference or test playback rate was added to the product.

The user then powered off the TV and box. Physical E-AC-3/AC-3/TrueHD output,
lip-sync, real JOC and DTS-HD media remain unverified. The final policy change
has not been rerun on the powered-off device. The production installation was
not replaced with a locally signed test package.

## Regression evidence and follow-up

- Native core CTest: 11/11 passed, including delayed presentation-clock recovery.
- Android Kotlin unit tests: 70/70 passed, including encoding, route rejection,
  sample rates, timestamp outage/reset/wrap and hardware-delay accounting.
- Android APK checker Python tests: 36/36 passed.
- Flutter playback-backend and Android seek-cancellation regressions: 22/22 passed.
- Local release-mode validation APK: JNI/R8 and armv7 dependency audit passed.
- Local artifacts, synthetic media and logs: ignored `build/tv-av-sync/`.

On the next hardware session, use a newly built validation package to check
normal-speed E-AC-3 5.1 → AAC → E-AC-3, pause/resume, seek and next episode.
Record actual sound separately from queue progress. Check lip-sync with a
known synchronized flash/click fixture and ordinary dialogue. Leave DTS-specific
investigation deferred unless requested again. No version/tag publication is
part of this fix task.

## v0.1.55 passthrough stutter follow-up

Device reconnected at `192.168.0.106:5555`. The production APK reported E-AC-3
5.1 direct output (`AUDIO_FORMAT_E_AC3`, 48 kHz) with repeated AudioFlinger
underrun/restart events during 3840x2160 HEVC playback. The user clarified that
switching back to ordinary audio substantially improved playback, with some
residual video stutter. The subsequent PCM track had zero reported underruns.
This does not establish that the remaining video stutter has the same cause.

An isolated 640x360 E-AC-3 synthetic baseline progressed for 13 seconds without
underruns. It does not reproduce the production 4K workload. Do not interpret
that short control test as an acceptance of the reported movie playback.

The candidate keeps the encoded buffer capacity but, on API 31+, sizes its
start/restart threshold from approximately 250 ms of whole raw access units.
The previous fixed 49,152-byte gate represents 1.536 seconds at 256 kbps; IEC
carrier burst size is not a duration for Android's raw encoded AudioTrack.
EOF lowering of the threshold is reset to the selected threshold on flush.
Repeated compressed playback-head queries now share one hardware read per
10 ms rather than issuing several synchronous Binder/HAL calls per feeder
iteration. PCM presentation-clock sampling is unchanged.

Android Kotlin regression: 73 tests passed, zero failures/errors, including
duration-based compressed thresholds and clock-poll invalidation. The isolated
release validation APK built and passed JNI/R8/ABI audit. Local artifacts are
under ignored `build/tv-passthrough-stutter/`.

With the user's permission the isolated candidate was launched on the box.
E-AC-3 (448 kbps) reported a 14,336-byte start threshold, retained 49,152-byte
capacity and zero underruns during the first 15 seconds. The user confirmed
continuous sound and picture. AAC -> E-AC-3 -> seek -> AAC progressed without
errors; each sampled post-transition state had zero underruns. The user did
notice stutter in the first seconds when entering the `switch` test clip (its
initial track is AAC, not E-AC-3). A subsequent replay had no observed problem;
sampled hardware delay was approximately 130-148 ms with zero underruns.
This intermittent startup observation is not considered conclusively fixed.
AudioTrack also logged a stale startup timestamp after compressed seek, which
requires separate follow-up if reproduced; no speculative clock-reset change
was included in this candidate.

The synthetic baseline also played continuously, so these candidate samples do
not establish a measured improvement in the original movie. Production 4K
before/after performance remains **unverified**. No production APK replacement
or new release tag is part of this follow-up so far.

## Playback allocation follow-up (2026-10-10)

The user returned to the production app and replayed the affected movie. The
new sample again showed active 48 kHz, six-channel E-AC-3 direct output and
underrun/restart events. Several Dart workers consumed CPU concurrently;
`NativeAlloc` GC recurred roughly every one to two seconds. Most reported
stop-the-world pauses were short, but one was about 47 ms. GC total duration
is concurrent work and must not be described as an equally long playback stop.
One meminfo sample reported PSS 225,151 KiB, RSS 325,772 KiB and SwapPss
27,064 KiB; subsequent top samples showed RSS around 420-432 MiB. These are
different samples and accounting methods, not a before/after comparison.

Three bounded allocation improvements were made in the shared playback cache:

- Protected disk responses retain one verified block per lease within the
  existing pending-byte budget. Sequential 64 KiB slices reuse that block;
  concurrent reads serialize, close drains outstanding work, and a budget
  reduction can discard the retained buffer. Snapshot identity remains valid
  after cache invalidation/replacement. Returned slices still own their bytes.
- Ordinary disk reads retain the owned worker result without another whole-
  block copy. Writes from external callers still make defensive copies.
- Sequential reads reuse the most recently read index entry. Storage mutations
  invalidate the cursor, including newer overlapping blocks and generations.

The baseline regression sent one 4 MiB disk block in 64 KiB slices and observed
64 block reads / 268,435,456 returned disk bytes / 488 ms. The candidate observed
one block read / 4,194,304 bytes / 14 ms (19 ms in the broader parallel suite).
These are local Windows test-process measurements, not TV throughput, RSS
reduction or movie playback acceptance. `diskBlockReads` counts read attempts;
`diskBlockReadBytes` counts complete verified blocks returned to the caller.

Android CoreInput now reuses an evicted read-window array when its capacity
matches. Its old offset is removed before reuse and its valid length is reset;
the eight-window bound also holds while loading the next window. A rolling
HTTP regression traversed 25 windows with only eight 256 KiB allocations
(2 MiB total), checked retained-window hits and re-fetching an evicted offset.
No extra spare-buffer pool or increased cache limit was introduced.

Validation: Flutter cache/proxy/read-ahead regressions passed 205 tests with
two platform-specific skips; Android Kotlin tests passed 74/74; Flutter analyze
reported no issues; changed Dart files passed formatting and diff whitespace
checks. Artifacts are under ignored `build/tv-passthrough-stutter/`.

The full application release-mode validation APK built, passed JNI/R8/armv7
dependency audit, and was installed and launched on the box as
`com.rillight.rillight.validation`. It uses independent account/settings data;
production credentials were not copied. Artifact:
`build/tv-av-sync/Rillight-tv-memory-pass1-validation.apk`, SHA256
`63af58c088ccf520fe7cf0ffc9ea6021f7722f635b135a9bc831cdb420ed91c4`.

The changes above have not yet established lower device memory use or smooth
playback of the original 4K movie. Compare the validation package using the same
movie, audio track, playback interval and cache conditions. Installation and
activity launch establish neither physical sound nor playback acceptance.


## Cache contention and flashing progress follow-up (2026-10-10)

The second validation build (SHA256
`ffbe7a30570d2a6e70d8e2f06474072bf4ac7bd151a961db45d2160c58f17fe4`)
is not accepted as smooth playback: the user still reported interrupted sound
and video. The proposed PCM comparison was **not performed**, as explicitly
corrected by the user. The active sampled output remained E-AC-3.

The second pass prevents optional timeline metadata from evicting foreground
RAM blocks, borrows Dart bytes for bounded 64 KiB leaf CRC calls instead of
allocating/copying a native staging buffer, and caches Android audio route IDs
for at most 250 ms with immediate callback/explicit-refresh invalidation.
Flutter regression checks passed 210 tests (two Windows platform skips),
Kotlin passed 75 tests, analysis and the validation APK dependency audit passed.
The local Windows CRC benchmark median for 64 x 4 MiB changed from 103,208 us
to 14,488 us; that is not a measurement of TV playback or memory improvement.

A temporary validation-only trace captured actual playback with 8 MiB retained
byte-cache RAM, typically 8-24 MiB pending transfers, recurring optional index
failures (`indexBudgetOrReadUnavailable`/`integrityUnavailable`), and byte
coverage becoming empty while the network continued downloading. Audio queues
repeatedly emptied and AudioTrack's underrun count increased. The native and
Dart file fingerprints matched exactly in the sampled comparison; timestamp
precision mismatch is not supported by this evidence. One meminfo sample was
PSS 176,841 KiB / RSS 306,808 KiB / native heap PSS 80,782 KiB. Other samples
were higher; these are not matched before/after measurements.

The next candidate addresses three demonstrated cache behaviors:

- A retracted block no longer blanks all verified byte coverage. Intersect the
  previous verified ranges with current indexed availability once per coverage
  revision, retracting missing portions without adding unverified bytes.
- Failed or unsupported time-index attempts wait for the existing 2 s integrity
  interval instead of restarting on every 250 ms diagnostics tick during cache
  writes. Byte verification continues independently. Identity, duration and
  track changes bypass the old retry deadline.
- Byte snapshots record the revision at scan start, so a concurrent append
  cannot incorrectly be marked as already scanned.

Regression coverage includes partial reclamation, holes/overlaps, generation
invalidation, metadata read-count suppression under concurrent cache writes,
and immediate track-selection retry. Temporary cache/fingerprint/audio packet
traces were removed from source before building the candidate. Sanitized local
samples are under ignored `build/tv-passthrough-stutter/`. The original 4K
movie's smoothness and a reduction in device memory remain unverified until
candidate playback is compared under equivalent conditions.

Third-pass validation: cache/CRC regressions passed 94 tests with two platform
skips; proxy, response read-ahead, transport and buffer snapshot regressions
passed 136 tests (230 total passed). Flutter analyze found no issues; formatting
and whitespace checks passed. The release-mode armv7 validation APK built and
passed its dependency audit, then installed and launched successfully on
192.168.0.106:5555. Artifact: `build/tv-av-sync/Rillight-tv-memory-pass3-validation.apk`,
SHA256 `98389a4d5e13ce3b1f72ffd9f4ccecc4e672d47508e981a6d2335631a851389f`.
The user initially still reported flashing/stutter, then clarified that the
progress bar's discontinuity occurs only near startup and later becomes stable.
Startup playback stutter is more pronounced; sustained playback still has
occasional visible hesitations (a later correction to the initial "smooth"
reply). This is partial progress, not playback acceptance. Matched memory
measurements are pending. No commit, push or release tag was created.


A subsequent validation-only A/B build limited the existing read-ahead override
to 64 MiB (default disk quota remained unchanged), SHA256
`08087bb7efadb1e85b46d014841c1ffdcb35e1dbb827e266d0ac7253715af560`.
It installed and launched successfully, but the user still reported a lack of
60 fps smoothness. This override is not a proposed production default.
The output panel reported a 60 fps target; the display was at about 59.94 Hz.
A SurfaceFlinger layer sample had a 16.71 ms median and an 83.42 ms maximum
interval (8 intervals over 34 ms in 126 intervals). This measures that layer's
presentation cadence, not independently decoded or physically displayed movie
frames. OS perf-event access for simpleperf was denied; a Flutter profile-mode
build is being used to identify Dart CPU/allocation hotspots separately from
release-mode performance acceptance.


The user subsequently clarified that the 64 MiB override did help somewhat;
it is evidence of partial improvement, not a successful frame-rate acceptance.
The final policy separates Android forward prefetch from storage quota:
64 MiB minimum, raised to approximately one minute of the largest declared
video plus audio bitrates, always capped by the configured disk quota. Unknown
or transcoded bitrates use the floor; desktop behavior is unchanged. This
avoids downloading the entire default 2 GiB quota during ordinary startup
while preserving a larger window for high-bitrate sources. Seven runtime policy
checks passed, including invalid/missing metadata, high bitrate, quota clamping,
transcoded source metadata and the desktop boundary.

The profile-mode diagnostic obtained Dart heap usage around 55-60 MiB in its
samples, but CPU sample retrieval timed out. Profiling overhead and nonmatching
sample times prohibit comparing this with release-mode PSS. Function-level CPU
hotspots and absence of occasional frame stutter remain unverified. The profile
package is replaced with the release-mode validation candidate after diagnosis.


Final release-mode validation APK SHA256:
`61fe48009e599fb03c681f5e2436aca4aee24600fd35090770451e02c731ab7c`,
`build/tv-av-sync/Rillight-tv-memory-validation.apk`. The native dependency
audit passed, installation succeeded, and the activity launched, replacing the
profile-mode package. The 64 MiB compile-time override is absent: the runtime
bitrate-aware policy is active. Relevant Flutter checks passed 237 tests in
this follow-up (two platform skips); final analysis found no issues. This is
not a full-suite or hardware performance acceptance claim.

### Online research follow-up — 2026-10-10

This follow-up compares official Android/Flutter documentation and AndroidX
source with the candidate. It does not change playback behavior or establish a
root cause. Downloaded reference excerpts are in ignored
`build/tv-passthrough-stutter/research/`. AndroidX references below are pinned to
release-branch revision `8c6678b657ede1e7883fc164ef73ed483c7796c3`.

- **Separate forward download, playable duration, and memory.** AndroidX
  [DefaultLoadControl](https://github.com/androidx/media/blob/8c6678b657ede1e7883fc164ef73ed483c7796c3/libraries/exoplayer/src/main/java/androidx/media3/exoplayer/DefaultLoadControl.java)
  combines duration and byte limits and distinguishes start from rebuffer
  thresholds. These are sample-buffer controls, not recommendations to copy its
  byte limits into our disk cache. Our 64 MiB forward window represents about
  5.37 seconds at 100 Mbit/s or 26.84 seconds at 20 Mbit/s, ignoring container
  overhead; disjoint ranges need not represent any such continuous duration.
  The final bitrate-aware policy is still awaiting device comparison. In native
  `enqueue`, OPENING/BUFFERING/RECOVERING can transition to PLAYING once the
  first-video condition is met; there is no separate playable-duration threshold
  there. Investigate repeated starvation/restart before proposing a recovery
  gate, including EOF, seek, and interleaved-track deadlock boundaries.
- **Avoid unnecessary audio timestamp polling, while preserving clock validity.**
  [AudioTrack.getTimestamp](https://developer.android.com/reference/android/media/AudioTrack#getTimestamp(android.media.AudioTimestamp))
  recommends frequent polling during warmup, then roughly every 10–60 seconds
  once stable. AndroidX
  [AudioTimestampPoller](https://github.com/androidx/media/blob/8c6678b657ede1e7883fc164ef73ed483c7796c3/libraries/exoplayer/src/main/java/androidx/media3/exoplayer/audio/AudioTimestampPoller.java)
  uses state-dependent polling (10 ms initialization, 10 s stable/no timestamp,
  500 ms error). Our `CoreAudioOutput.checkedSnapshot` polls every 100 ms
  throughout playback. This is an optimization candidate, not proof of the
  observed stalls. Merely changing the constant to 10 s would be incorrect:
  `CorePresentationClock` accepts timestamps only up to 500 ms old and expires
  its estimate after 2 s. Any change must jointly handle extrapolation, pause,
  speed changes, seek/flush, counter resets, and route changes.
- **Timed release already exists; measure buffer ownership and VSYNC alignment.**
  [MediaCodec.releaseOutputBuffer](https://developer.android.com/reference/android/media/MediaCodec#releaseOutputBuffer(int,long))
  recommends release about two VSYNCs before presentation (about 33 ms at 60 Hz),
  warns that retained buffers can stall the codec, and documents that buffers
  targeting the same VSYNC can be dropped. Our MediaCodec path already schedules
  monotonic presentation timestamps with a 50 ms lead. That difference alone
  does not establish a bug. AndroidX
  [VideoFrameReleaseHelper](https://github.com/androidx/media/blob/8c6678b657ede1e7883fc164ef73ed483c7796c3/libraries/exoplayer/src/main/java/androidx/media3/exoplayer/video/VideoFrameReleaseHelper.java)
  also aligns release timing with VSYNC. Correlate late submissions, decoder
  waits, and actual video-layer timestamps before altering lead or queue depth.
- **Prefer SurfaceView where compatible.** The official
  [surface guide](https://developer.android.com/media/media3/ui/surface) documents
  more accurate frame timing, lower power, HDR support, and full-resolution TV
  output with SurfaceView. Current HDR/unknown output already uses it; SDR uses
  TextureView as a compatibility workaround. A global switch would require
  regression of that workaround and is not justified by this research alone.
- **Separate memory categories and measurement surfaces.**
  [Flutter memory documentation](https://docs.flutter.dev/tools/devtools/memory)
  distinguishes Dart heap, external/native memory, and RSS; disk prefetch size
  is not equivalent to process resident memory. Android's
  [memory overview](https://developer.android.com/topic/performance/memory-overview)
  explains shared/private accounting. Collect matched release-mode samples,
  allocation rates and retained objects rather than infer leaks from one RSS
  value. [Perfetto FrameTimeline](https://perfetto.dev/docs/data-sources/frametimeline)
  currently documents a SurfaceView coverage limitation, so Flutter/UI frame
  statistics alone cannot establish video smoothness.

Prioritized hypotheses: (1) cache verification work repeatedly triggered by RAM
retention/eviction, since `_refreshByteCoverage` and `_refreshResponseCoverage`
key their checks on `cache.revision`; (2) starvation recovery without a separate
duration gate; (3) presentation timing and unnecessary audio clock queries.
These require measured attribution. RAM retention/eviction does increment the
revision in code, but the cost of resulting verification is not yet profiled.
Do not remove integrity checks, conceal real range gaps, add frame interpolation,
or claim the prior PCM comparison occurred. Media3 is a reference only; the
owned FFmpeg core remains the playback implementation.

### Content snapshot reuse — 2026-10-10

Confirmed a redundant-work path with synthetic local playback/cache regressions:
eight alternating reads through a one-block RAM budget triggered eight additional
disk integrity scans despite unchanged, immutable disk-backed content. The
indexed MP4, unknown-container byte coverage, and untagged-response paths each
performed nine scans including the initial one. With the change, each performs
only the initial scan within the integrity interval. This measures scan requests
in a Windows test, not TV CPU time, PSS, or displayed frame rate.

`SessionByteCache.contentRevision` separates content/publication changes from
disk-backed RAM promotion/eviction. The existing storage revision remains in use
for the read cursor; coverage retractions retain their separate revision. The
proxy keys time and byte snapshot reuse on content revision while retaining the
existing periodic integrity expiration. New/overwritten entries, disk publication,
RAM-only loss, invalidation, and close advance the content revision. A cumulative
`diskIntegrityScans` diagnostic counts actual verifier dispatches without media
identities or packet logging.

Regression coverage confirms that all three paths still detect external file
truncation on periodic verification even without a cache revision change. RAM-only
retraction/replacement/invalidation is covered, as are the existing concurrent
append, selected-track, partial reclamation, corruption, and timeout cases.
The bitrate-aware 64 MiB minimum forward window and RAM/pending budgets remain
unchanged. No audio clock interval or native rebuffer threshold was changed in
this patch: their coupled timing behavior requires separate validation.

Validation: 108 cache/CRC/runtime-policy tests passed (two platform skips),
28 response/transport/buffer tests passed, and 108 HTTP proxy tests passed:
244 passes in total, not a full-suite run. Flutter analysis reported no issues.
The release-mode armv7 validation APK built and passed the native dependency
audit. SHA256:
`dd8930846f77273b1004dc5bed560c04bd36c85de6107a2583b648a4d15b1ddf`;
artifact `build/tv-av-sync/Rillight-tv-memory-validation.apk`. ADB installation
succeeded on 192.168.0.106:5555. Actual sustained playback smoothness and matched
release-mode memory measurements remain pending. No commit, push, or tag.

Read-ahead sizing follow-up: the user's concern about a small forward window is
valid for high-bitrate sources falling back to 64 MiB. At 20/50/100 Mbit/s,
64 MiB represents approximately 26.8/10.7/5.4 seconds of sequential file bytes,
not guaranteed playable duration. At 100 Mbit/s the declared-bitrate one-minute
policy instead requests about 715 MiB before quota/reservation constraints.
The policy currently consults per-stream bitrates, not the source-level bitrate
or file-size/duration estimate; missing metadata and dynamic sources use the
floor. The actual current movie's selected window has not been established.

Reviewed live AndroidX DefaultLoadControl and mpv options documentation online.
[mpv cache/hysteresis documentation](https://github.com/mpv-player/mpv/blob/master/DOCS/man/options.rst)
explicitly allows stopping at time/byte limits and resuming after consumption;
its cache-pause-initial notes also acknowledge that demanding prefetch can cause
startup dropped frames. AndroidX combines duration and byte limits (current
generic defaults target 50 s, subject to byte limits). Both references describe
demuxed/sample buffering, not our raw-file disk window; their numeric limits are
not directly transferable.

Our range read-ahead follows the newest consumer and reschedules after reads.
For a full 64 MiB window it ordinarily refills after about 16 MiB is consumed
(`min(32 MiB, max(block size, aheadBytes / 4))`); an uncached waiting reader
bypasses that refill threshold. This is bounded prefetch, not disabled caching.
Untagged response buffering additionally caps its window at a quarter of the
disk quota. Keep the 2 GiB storage ceiling distinct from the forward target.
Recommended next experiment: supplement missing stream bitrate with validated
source metadata/size-duration estimates, then measured consumption where valid,
and compare a duration-based window under network jitter without increasing RAM
retention. A 60–120 s experimental target would be a project policy to validate,
not an Android mandate. No playback settings were changed by this research.

### User-configured disk budget for prefetch — 2026-10-10

The user explicitly requested that forward prefetch use the saved cache budget,
including 2 GiB, instead of the 64 MiB/one-minute policy. This supersedes the
metadata-adaptive proposal above. The source-metadata implementation was built
and tested as an experiment but never installed; its request fields and policy
were removed after this direction, rather than retained as unused architecture.

The backend now reads `effectiveDiskCacheLimitBytes(settings)` for both disk
quota and forward target on every open. The previous compile-time 64 MiB
experiment override was removed from production code. Untagged HTTP response
prefetch also uses this target instead of a quarter-quota cap. Ordinary range
and untagged-response paths still reserve workspace within the disk quota and
stop at file end; HLS segment speculation retains its separate bounded policy.
RAM retention remains 8 MiB, pending transfers retain their existing budget,
and earlier duplicate-read/integrity-snapshot optimizations remain in place.

Regression checks cover saved 2 GiB, 512 MiB and 4 GiB settings across opens and
unchanged RAM/pending limits. A synthetic untagged response is held while disk
prefetch progresses beyond the former quarter-quota limit, then read across a
file larger than the disk budget to exercise reclamation and byte correctness.
A test initially referenced a nonexistent diagnostic key; it was corrected to
assert actual published byte progress. Concurrent Windows Flutter test commands
also encountered a loaded native DLL lock; reruns are serialized.

Final validation: the 28 backend/runtime-policy cases passed in the combined
run; all 11 response cases passed in the corrected serial rerun (39 distinct
cases total). The full-budget response test verified at least 48 MiB published
while its reader was stationary, then read a 96 MiB+37-byte file with byte
checks on one upstream response and disk/RAM peaks within their budgets.
Flutter analysis found no issues. The release-mode armv7 validation APK passed
its native dependency audit and installed/launched on 192.168.0.106:5555.
Artifact: `build/tv-av-sync/Rillight-tv-memory-validation.apk`; SHA256
`7a009391f200f5cfdc0de2649c742847e76b79036f4c2d686ddbbd5b5ceb4485`.
This supersedes the installed 64 MiB/bitrate-aware candidate. User settings are
loaded at playback open; actual TV smoothness with the larger forward target
remains unverified. No commit, push or release tag was made.

### Startup gaps, cache publication and remembered audio — 2026-10-10

The user reports that startup stalls accompany split cache coverage, seeking
into the later cached segment helps, and downloading the configured 2 GiB
budget causes video stutters. Three deterministic regressions were reproduced:

- Verifying one resource discarded other resources' known CRC fingerprints.
  A subsequent snapshot exposed only 4 MiB of a previously verified 12 MiB
  resource. Fingerprint merging now touches only the requested resource's
  tokens and retains a bounded global fingerprint map.
- An untagged response lost all visible byte coverage after partial reclamation.
  Coverage revisions now retract just unavailable ranges synchronously, keeping
  the remaining verified tail. Actual holes are not filled for display.
- A cached distant probe moved read-ahead past a running transfer's next window.
  A synthetic probe at 48 MiB left a hole starting at 32 MiB. Continuous
  read-ahead now finishes its download frontier before following later demand;
  explicit seek/stop still cancels that frontier. The regression verifies the
  complete initial 49 MiB remains available after the probe.

Disposable cache blocks no longer request a physical flush for every block.
The writer still closes a complete temporary file before atomic rename, and
reads retain length/CRC validation. Ownership and protection metadata retain
their existing flush policy. This removes repeated forced flushes during large
downloads; its effect on physical TV frame pacing is not yet measured. The
configured disk budget and the 8 MiB RAM retention limit remain unchanged.

Scoped audio preferences previously saved language/title without the selected
index or exact source identity. Reopening a Japanese track at index 10 restored
index 1 when labels matched. Mobile and desktop now save the index with source
identity and prefer it only for that identical source; other sources retain
portable matching, and missing indices fall back to available tracks. A
controller close/reopen regression reproduces the old failure and passes after
the fix, alongside explicit-source isolation and matcher cases.

The eight focused regression cases pass and Flutter analysis reports no issues.
The broader seven-module run passed 322 cases with one existing Windows skip
(POSIX ctime mutation detection). The release-mode armv7 validation APK passed
its native dependency audit and installed/launched on 192.168.0.106:5555.
Its SHA256 was
`358b646eb94b94741a194244ef46d2db314baf2f99f28fc3e9bc2e0fbd6657ab`.

After the user resumed actual playback, an approximately 14-second sample of
PID 18751 showed an active EAC3 5.1/48 kHz AudioFlinger track. Its reported
underrun-frame counter grew from 137984 to 147968 (+9984); this is a counter
delta, not a calibrated audible-gap duration for compressed output. PSS at the
sample endpoints was 209574 and 180658 KiB, RSS 335176 and 306308 KiB, and swap
zero. Four valid two-second CPU rows ranged from 123 to 173.5 percent where
one core is 100; DartWorker threads were the largest combined contribution.
Three rows contained malformed negative Android top CPU fields and were
excluded, as was the initial lifetime sample. No matched baseline was captured,
so these figures do not establish a performance improvement. The device has
no `media.codec` dumpsys service; this sample does not establish video FPS or
displayed frame pacing. Only allowlisted counters/thread names were saved in
ignored `build/tv-passthrough-stutter/cache-audio-device-sample.json`.

Follow-up code inspection found full cache integrity/index refresh coupled to
the 250 ms speed poll while new bytes keep changing the content revision. A
synthetic growing-cache regression performed seven integrity scans in about
two seconds. Full timeline refresh now runs at most once a second while speed
and eviction observations remain on their original cadence. A new playback
generation or track change resets that throttle. The regression requires
continued speed/coverage updates with at most four integrity scans and passes;
next-episode/seek coverage also passes. This changes optional scan frequency,
not the configured prefetch capacity or media-read scheduling.

Final cadence candidate: all 23 backend tests passed, analysis found no issues,
and the release-mode armv7 APK passed native dependency auditing. Together with
the earlier seven-module run, 345 distinct regression cases passed with one
existing platform skip; this was not a full repository test run. The candidate
was installed and launched in the validation package on 192.168.0.106:5555.
Artifact: `build/tv-av-sync/Rillight-tv-memory-validation.apk`; SHA256
`3767cee1e0159d41353edd6a73a73fb1c2ee8826da1233cae19eb11a4f34adab`.
The final cadence change has not yet had a matched physical playback sample.
The earlier underrun finding must not be represented as resolved by testing
alone. No commit, push or release tag was made.

### Cache bar disappearing during actual startup — 2026-10-10

The user reports that the cadence candidate still alternates between showing
and hiding coverage, and that startup shows separate cached sections near zero
and two minutes. Consecutive ADB screenshots confirm missing byte coverage at
playback position 1:28 with 15 MB/s download displayed, followed by visible
blue coverage at 1:54 (7.8 MB/s), 2:10 (8.2 MB/s), and 2:28 (1.7 MB/s). The
controls and played-position bar remain visible in these comparisons. An
intermediate image had auto-hidden controls and is not evidence of cache
flicker. Captures are under ignored
`build/tv-passthrough-stutter/cache-flicker-capture/`; the captured black native
video layer is not evidence that the physical screen was black.

A reproducible fault was found in the writer/read boundary: `disk-timeout`
from queued publication made existing immutable disk blocks appear absent in
`firstMissingOffset`, hid tagged and untagged byte coverage, and rejected reuse
of the active untagged response. Foreground disk reads and verification already
have independent workers and can still read those blocks. Windows lock-contention
regressions reproduced both coverage loss (a verified 2 MiB+7 range became empty)
and a false miss at offset zero. An end-to-end untagged-response regression
made three origin requests for an already cached 64 KiB range; after repair it
verifies every byte while making only the original request.

Cache planning and retained coverage now recognize immutable blocks during a
transient writer timeout, and active buffered responses continue serving them.
Recent verified byte coverage remains visible with the existing expiry limit.
Permanent disk failures, actual deletion/corruption and representation changes
retain their retraction behavior. This does not merge real holes or reduce the
user's configured cache capacity. The three focused regressions pass, alongside
targeted expiry and external-loss checks. The lock fixture is explicitly
Windows-only because POSIX same-process lock semantics differ; it demonstrates
the code defect, not that a writer timeout was observed directly on the TV.
Final regression, build and device follow-up are recorded below.

The writer-timeout candidate passed 211 regression cases (one existing Windows
skip), static analysis and the local armv7 APK audit. Installed APK SHA256 was
`77aa622f2c0c303b05d4e08d3707d6966813647419116fc321fd05ff444af1c7`.
The user explicitly reproduced the problem again; `after-02.png` shows empty
coverage at 1:21 while downloading at 13 MB/s. This was not device acceptance.

A temporary ignored diagnostic entrypoint sampled numeric cache state during
actual episode 22 playback (PID 21136). All 180 samples reported no cache
degradation. Coverage repeatedly became zero despite growing disk usage: for
example sample 46 had 388,109,511 disk bytes and sample 111 had 904,008,903,
both with `integrityUnavailable`. Other samples recovered hundreds of MiB of
coverage. Thus writer timeout was not the cause of this captured recurrence.
Android truncated long Flutter log lines at 1024 bytes: only complete JSON
fields before truncation were recovered, with an explicit `truncated` marker;
missing range/paint fields must not be inferred from those samples.

A new concurrent-publication regression reproduced a second fault: starting a
write while verifying an existing 64 KiB disk prefix returned null for the whole
snapshot when the new token arrived during verification. Sustained publication
can therefore prevent refresh until the previous display expires. The fix keeps
verified old ranges and excludes only newly published tokens absent from this
scan, unless their bytes are still available in RAM. It preserves real holes,
identity checks, TTL expiry and the configured disk/read-ahead capacity. The
focused regression fails before and passes after the change.

The concurrent-publication candidate passes 212 cache/proxy/buffer regressions
with one existing platform skip; targeted static analysis reports no issues.
The baseline numeric trace contained five transitions from nonempty to empty
coverage and 50 empty samples after coverage first appeared, out of 180 samples.
These are internal coverage observations, not frame-rate or physical-audio
measurements. The candidate device comparison is still pending.

Device follow-up for the concurrent-publication candidate: PID 21912, same
user-selected episode, 180 numeric samples. Once nonempty coverage first
appeared, neither proxy byte coverage nor the backend's painted byte ranges
became empty again (baseline: five disappearances / 50 empty samples after
initial coverage). No cache degradation was recorded. Screenshots at 0:04,
0:53 and 1:38 show visible coverage; files are `candidate-01.png` through
`candidate-03.png` in the capture directory above. This is one startup comparison,
not a guarantee against all flicker or a frame-rate/audio performance result.

The initial split was real byte coverage: approximately 0–70.9 MB and
248.6–282.2 MB of a 5,592,187,249-byte file. By sample 39 (playback 15.430 s),
verified coverage became one continuous range 0–291,640,457. The byte bar does
not prove a playable time interval near two minutes; temporal indexing still
reports `indexBudgetOrReadUnavailable`. Physical startup stutter and the cost
of repeated optional time indexing are not established as fixed by this change.

The temporary diagnostic entrypoint lives only in ignored build files. A fresh
normal-entrypoint release-mode validation APK was built, audited, installed and
launched after collecting the comparison. Its SHA256 is
`168a777e580d25296770d0cecb6f336cd007d62cc04b9e5017a8c000d3079325`.
Signing configuration was removed by the build script. No commit, push or tag
was made in this follow-up. The configured 2 GiB budget remains unchanged.

### Remaining startup blockage and frozen playback — 2026-10-10

After the coverage comparison, the user reports that playback remains blocked
until the two cache islands join, then reports a freeze on the clean candidate.
PID 22390 remained alive and the output menu still responded. Captures
`frozen-01.png` and `frozen-output-02.png` show 0 KB/s and playback advancing
only from about 0:14 to 0:19 during investigation. This is not application-wide
UI deadlock evidence. A 16-second sample showed Thread-4 near one full CPU core,
PSS 461,685 -> 489,864 KiB and Native Heap 370,136 -> 375,420 KiB; the active-track
AudioFlinger filter returned no rows. Those observations do not identify the
busy native worker or establish an audio-routing cause. `debuggerd -b` refused
access because the device is unrooted. The cache-bar repair is not playback
acceptance. Further temporary, bounded native snapshot and Java stack sampling
is being prepared without recording network addresses or credentials.

A scheduler regression confirms that a completed small AVIO read followed by
an uncached distant track was classified as "near" merely because the next
request was at most 1 MiB. A paused transfer at offset zero consequently blocked
64 KiB demand at 24 MiB until the intervening bytes arrived, both with and
without continuous transfers. Both controlled tests time out before the fix;
after removing that exception, demanded bytes arrive while the intervening gap
is deliberately still missing. Cached and genuinely nearby reads retain the
existing connection. The scheduler/proxy regression run passes 183 cases with
one existing platform skip; targeted analysis passes.

An initial native-diagnostic harness incorrectly supplied a deferred player
factory, losing the Android backend's eager player creation required for the
mounted view. Samples from that harness (no surface, no running native core)
are excluded from playback evidence. The replacement temporary harness uses
the unchanged backend constructor and queries existing owners read-only through
a temporary native method. Both diagnostic native patches are restored after
building; neither is a product fix or release change.

### HEVC allocation failure and reboot control — 2026-10-10

The valid native trace reached approximately 2 GiB on disk while
`readAheadReaderWaiting=false`, video queues stayed empty, and actual hardware
remained zero even after video output. Reopening episode 22 without replacing
the APK captured `createComponent(c2.amlogic.hevc.decoder) -- NO_MEMORY` and
MediaCodec error -12 during INITIALIZING (PID 23833). The vendor codec service
repeated two unchanged VDA instance counters; `/proc/meminfo` reported
`CmaFree: 0 kB`, `DriverCma: 202952 kB`, and `MemAvailable: 559104 kB`.
These observations establish hardware allocation failure, not ownership of a
driver leak or proof that the configured disk quota consumed hardware memory.
The TV settings page has no decoder toggle; no persisted preference was read
and no user decoder setting was changed.

With explicit user authorization, the box was rebooted without changing the
installed diagnostic APK. Before playback, CmaFree was 94,772 KiB and
MemAvailable 2,017,396 KiB. Episode 22 with the same 5,592,187,249-byte resource
then reported actualHardware=8 and `Created component [c2.amlogic.hevc.decoder]`
(PID 4298). The user confirmed playback resumed, but still reported stutter
and split coverage. This establishes recovery from the allocation failure;
it does not establish smooth playback or a permanent decoder-lifecycle fix.
The user later closed/reopened playback, so subsequent samples are separate
sessions, even when the process ID stays the same.

The reboot trace had continuous verified coverage from zero through hundreds
of MiB, no read-ahead demand wait in the sampled playback rows, and recurring
`indexBudgetOrReadUnavailable`. A later reopened session retained a metadata
prefix and forward data separated by evicted bytes. A byte-position bar cannot
be interpreted as playable time. Logs/captures remain under ignored
`build/tv-passthrough-stutter/` (`current-codec-log.txt`,
`vendor-codec-allocation.txt`, `reboot-trace-device.jsonl`,
`reopened-baseline-trace.jsonl`). No full network log or credentials were saved.

The progressive MP4 index now resolves track identities before expanding only
the selected sample tables. Unsupported unselected tables no longer invalidate
selected coverage; ambiguous or missing selected IDs remain unknown. A fixture
with an unsupported alternate audio table fails before and passes after the
change. An additional long multi-audio fixture checks early rejection before
sample expansion when selection is ambiguous. Initial index construction may
run cooperatively for up to three seconds, yielding every four milliseconds,
instead of repeatedly discarding all work at 250 ms; range projection retains
its 250 ms deadline. Cancellation checks run at the same checkpoints. Device
acceptance of this index change is pending; the 2 GiB user quota is unchanged.

The index candidate passed 220 focused cache/index/proxy tests (one existing
platform skip), targeted analysis and the local armv7 release APK audit. Clean
APK SHA256: `ccc893e239ed1b285c0bfdcea41e72f97f39236c6a863fac3ba548c7406591b1`.
It was installed after a normal playback exit. The user explicitly reports
that playback works but stutter/split coverage remains. This candidate is not
accepted as fixing the reported performance issue. PID 7585 created HEVC
hardware components successfully; AudioTrack logged two `restartIfDisabled`
underrun recoveries. A short system sample showed app CPU 141–151% (four-core
scale 400%) and vendor audio service 49.5–71.9%. These are unmatched workload
samples, not a before/after improvement measurement.

A profile-mode build of the same code was temporarily installed for function
sampling (PID 8588). VM service enumeration found main, transport, disk,
verifier and block-reader isolates. Main Dart heap usage was 47,337,056 bytes;
process PSS was separately sampled at 294,711 KiB. CPU-sample retrieval timed
out even for a 200 ms interval at reduced sampling frequency. `run-as`
debuggerd still required root, and simpleperf was rejected by the device's
perf hardening. No device security settings were changed; no native function
profile was obtained. A read-only inspection of cache block headers exceeded
its 30-second bound during eviction and produced no usable container evidence.
It must not be represented as a successful metadata diagnosis. The normal
release-mode validation APK above was restored successfully and its activity
launched after this diagnostic attempt; no ADB forwards remain. No commit,
push or tag was made at that point. Physical stutter and split-cache acceptance
remain open.

### v0.1.56 release preparation — 2026-10-11

The accumulated playback changes were committed as `fcd1d42`, then remote main
`5162030` was merged without conflicts. Version 0.1.56+57 retains the configured
disk budget and the unresolved physical TV findings above. Release notes do not
claim that playback stutter or split/flickering coverage is fixed.

The first full Flutter run passed 1,632 tests with two platform skips but failed
the slow recovery-header regression. Explicitly separating response headers
from the body with a detached HTTP socket reproduced premature source renewal:
the header wait was incorrectly included in the opening body-progress timeout.
Successful media response headers now advance the opening progress timer;
error responses do not. The regression preserves the 31-second header delay
and exposes a 750 ms headers/body gap instead of relying on packet timing.

Final release checks: `flutter pub get` succeeded; `dart format lib test`
reported 393 files with no changes; `flutter analyze` reported no issues;
all 23 backend regressions passed; the repeated full `flutter test` run passed
1,633 tests with two platform skips. Logs are retained under ignored
`build/release-v0.1.56-*`. These checks do not change the pending physical TV
acceptance above. The version bump itself has not been installed on the TV.
