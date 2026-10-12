# Native playback validation

Supported targets: Windows, macOS, Linux, Android phone and TV use
the owned FFmpeg core in `packages/rillight_player`. The Android Studio emulator
and desktop native tests provide only their observed scope. macOS SDK/core
build and remaining GUI playback work are in
[`packages/rillight_player/macos/TESTING_HANDOFF.md`](../packages/rillight_player/macos/TESTING_HANDOFF.md).
The release evidence contract is in
[`tool/player_release_evidence.md`](../tool/player_release_evidence.md); package,
actual changing frames, physical audio and hardware performance are distinct.
See [`android/README.md`](android/README.md) for the current Android harness.

## Three-provider synthetic protocol run

`python tool/provider_acceptance.py --verify` executes production provider clients
against the separate fixtures in `test/emby`, `test/jellyfin` and `test/plex`.
The mandatory loopback tests in `test/provider_acceptance` cover login, catalog,
playback negotiation, progress writes, stop/cleanup, logout and resumed state,
plus the corresponding credential, authorization, permission and transcode
rejections. Plex progress is stored per resource token, so Home users do not
inherit another user's continuation position. Existing adapter and access-boundary
tests run as additional subprocess evidence. These plain HTTP tests do not pump
a full page and are intentionally outside the widget `integration` tag.

Prerequisites are the project Flutter SDK and `flutter pub get`, with no personal
server or native SDK. The script runs Flutter serially; do not concurrently run
another Flutter process on Windows or edit candidate files during verification.
It creates raw logs and `result.json` beneath ignored
`build/provider-acceptance/run-*/`. A nonzero exit is a failed check; a generated
file alone is not a pass. Supplied old reports (`--evidence`) cannot substitute
for a fresh run, even if their hashes and success flags look correct.

All results are synthetic protocol evidence. They do not establish an actual
Jellyfin/Plex version, a real transcode encoder, displayed frames, physical sound,
five-platform installation, or hardware stability. The report lists every real
service/platform combination as unverified; it does not infer platform passes
from the host's Dart VM. UI capture, formal analysis/full-suite validation and
native checks remain separate commands. See the
[evidence contract](../tool/player_release_evidence.md#three-provider-synthetic-acceptance)
for candidate binding, fixture baselines and imported-evidence trust boundaries.

## Native and cache scenarios

Use the owned-core harnesses to test actual texture changes, subtitles, HLS,
interrupted HTTP, seek timelines, audio-clock handoff and orderly shutdown.
Transport/storage tests must retain CRC validation, cancellation, generation
isolation, bounded read-ahead and configured disk budgets. Capture startup,
steady-state and recovery separately.

Keep historical per-machine reports in ignored evidence storage. They do not
validate a new candidate or replace the current source/package checks.
