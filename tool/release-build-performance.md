# Release build duration

Measured baseline: [v0.1.42, run 37348213121](https://github.com/sakullla/Rillight/actions/runs/37348213121),
2026-10-05. GitHub job/step timestamps show a 29-minute release.

| Job | Duration |
| --- | ---: |
| Windows | 27m 51s |
| macOS | 12m 27s |
| Android | 4m 49s |
| Linux build + installed regression | 4m 13s + 3m 20s |
| Draft release + publication verification | 15s + 40s |

Windows was the critical path. Its SDK/core build took 17m 22s after a
`windows-media-sdk` cache miss. Flutter setup took 1m 37s, and its post-job cache
save took another 2m 57s. The application build itself took 2m 20s.

Previously only tag releases ran the Windows build. GitHub caches created for
one tag are unavailable to other tags; the cache inventory inspected on
2026-10-07 contained no default-branch Windows SDK entry. A stable cache key
alone therefore did not provide reuse between releases. GitHub documents these
[cache access restrictions](https://docs.github.com/en/actions/using-workflows/caching-dependencies-to-speed-up-workflows#restrictions-for-accessing-a-cache).

The main-branch validation workflow now builds Windows through the same
`.github/actions/windows-build` composite action as releases. This seeds the
default-branch Windows SDK, Flutter and pub caches, which subsequent tags can
restore. Wait for this job to finish before tagging, especially after changing
Flutter, dependency pins, patches or native build inputs. A simultaneous push
and tag can still incur two cold builds. A cache eviction or toolchain change
also requires a new cold build.

The native cache key still includes the installed toolchain and pinned build
inputs, including the subtitle Unicode build helper. The build verifies cached
SDK hashes and provenance, compiles the owned core from the current candidate,
then audits the final Windows DLL closure and loaded versions. Signing and
playback checks on other platforms are unchanged.

Local validation: actionlint, composite YAML/shell validation, Windows SDK
manifest/closure tests, and workflow provisioning tests. A new remote warm-cache
release duration has not yet been measured; the baseline does not establish an
achieved speedup. Existing tags are not rewritten by this workflow change.

## macOS and Linux breakdown

The same successful baseline's macOS job spent 1m 24s setting up Flutter,
2m 20s compiling the sandbox proxy target, 5m 17s in the playback smoke step
(including its own Flutter build), and 1m 40s rebuilding the ordinary entry
point. Its verified native SDK was already cached. These are separate release
sandbox, playback and production targets; omitting one would remove validation
or risk packaging the validation entry point. Windows-style default-branch SDK
warming is already provided by the existing macOS main workflow.

Linux spent 47s installing build dependencies, 55s building/auditing the normal
bundle, 50s compiling the playback target and 33s generating fixtures. The
separate Ubuntu 24.04 job spent 45s installing the package and 2m 6s checking
native window pixels and virtual audio. The SDK cache also hit. The clean
installation and native output checks are retained; their runtime is useful
validation, rather than an uncached SDK rebuild.

On 2026-10-07, macOS and Linux release checks failed after a rate change because
switching items copied a transient native `playing=false` into the new item's
pause request. The first controller fix passed that stage in PR run
[37642299543](https://github.com/sakullla/Rillight/actions/runs/37642299543),
then macOS exposed the same issue during consecutive opens before the playing
event arrived. The follow-up preserves explicit pause intent across both
transitions, with playing/paused regression cases. Native verification of that
follow-up is pending; GitHub's
[Git operations / PR / Actions incident](https://stspg.io/96smrcth8bpg)
prevented its initial push. Failed runs are not evidence of improved build
duration or successful playback.
