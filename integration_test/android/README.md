# Android device validation

Use Flutter 3.47.4, Android SDK API 36/build-tools 36, JDK 17+ and FFmpeg on PATH.
Install Python dependencies in a virtual environment:

```sh
python -m venv build/android-validation/python
# Activate this environment using Scripts/Activate.ps1 or bin/activate.
python -m pip install grpcio==1.78.0 grpcio-tools==1.78.0 Pillow==12.1.1
python tool/android_release_checks_test.py
python tool/android_release_checks.py --all-targets
# Or a single device for development:
python tool/android_release_checks.py --serial emulator-5554
```

Windows also has `tool/android_smoke.ps1 -AllTargets -Ffmpeg PATH`. The wrapper
uses the current Python interpreter; activate the environment first. All-targets
requires running AVDs with a 360dp phone, a 412dp phone and a Leanback TV.
Start each emulator with `-grpc PORT -grpc-use-token` using a different port.
For headless virtual-output checks, add `-audio none`: this disables the host
audio backend while emulator gRPC still observes decoded guest output. On this
Windows/TV AVD, the default host backend repeatedly produced only about 0.37 s of
near-silent captured PCM during 6 s of playing video, including with the old
minimal player and old capture client. With `-audio none`, that same minimal
player produced 5.93 s of valid signal. This isolates a usable validation setup;
it does not prove a general emulator root cause or physical audio output.
Later repeated runs still exposed intermittent capture failures with this flag;
do not treat changing the host backend alone as a verified fix. The observer
requires six seconds of actual PCM after the application confirms playing.
Failed samples remain failed and are retained; no automatic retry converts them
into a successful sample. Independent page/native checks continue so each result
is visible, but a device and the overall run cannot pass with failed audio.
The verifier discovers the matching serial and token locally, never logs the
token, disables host microphone input, and captures the emulator's output PCM.
Keep media volume audible. Phone captures request 44100 Hz, TV 48000 Hz; raw
format, duration, RMS and peak remain in each run's audio JSON/WAV. These rates
reflect tested AVD behavior, not a proven explanation for earlier capture failures.

The additional Google TV API 36 x86_64 revision 4 image was checked using the
same application/native APKs, fixture and thresholds as the Android TV image.
Its first run captured 5.70 s of non-silent PCM. This is a separate successful
observation, not proof that changing images fixes the intermittent failure.
Keep the failing Android TV results alongside successful device runs.
Repeated captures also reproduced the short PCM symptom on a phone AVD;
the observation is not specific to TV. Image identity is saved per device.

The tools generate testsrc2 video, two synthetic AAC sine tracks and subtitles.
Ports 8784, 8865 and 8866 must be free for loopback fixtures; 18799 is used for
an adb-forwarded observer. No personal Emby server is needed. HTTP fixtures cover
login, views, 51-item pagination, search, seasons, playback metadata and reports.
POST `/__control` accepts `offline`, `expired`, `auth_fail`, `empty`, `report_fail`,
`media_fail`, `subtitle_delay_ms` and `catalog_delay_ms`; GET `/__state` exposes
sanitized request paths and synthetic reports. Use both expired/auth_fail to
exercise unrecoverable authentication, since normal synthetic refresh succeeds.

Validation builds set `--android-project-arg=rillightValidation=true`. They use
`com.rillight.rillight.validation`; only this disposable package is cleared.
The ordinary application package is never cleared or replaced. The application
probe invokes `lib/main.dart` and only observes visible widgets/controller state
through a loopback endpoint; navigation, taps, Android Back and input enter via
adb. It is not a production entrypoint. The native smoke separately checks
Media3 first-frame readiness, pause/seek, audio tracks, embedded/external
subtitles, surface recreation, HLS, redirect credential isolation, 401, missing
media and retry. Both produce screenshots; the application flow separately
captures virtual audio. Black/static frames,
silent/truncated audio, missing terminal markers and unavailable devices fail.

`build/android-validation/runs/TIMESTAMP/` retains immutable APK copies/hashes,
build logs, device input events, screenshots, native logs, PCM and `result.json`.
The verifier restores and audits an ordinary `lib/main.dart` debug APK even after
failure. Supplying explicit `--app-apk`/`--native-apk` reuses development artifacts;
do not claim those reused APKs as proof of a newer source candidate.

TV application navigation uses real D-pad/confirm/Back/media keys. Automated IME
typing uses adb text injection and is explicitly marked `tv_osk_only: false`.
For the OSK-only check, enter server URL, username, password and search using only
the TV input method's direction/confirm keys, record all keys and capture field,
dialog and returned focus. Do not classify injected text as this manual check.

Inspect the saved subtitle screenshots for actual text independently of track
selection status. A frame delta establishes changing colored pixels in the
video region, not lack of flicker. Virtual PCM is not physical speaker output.
AVD SwiftShader/WHPX runs do not establish hardware performance or GPU stability.
Build CI uploads a debug APK and runs native unit/host contracts; it does not run
the three-AVD audio/UI matrix. Configured CI is not an executed native result.

Desktop checks remain separate: `flutter build windows --release`,
`powershell -NoProfile -File tool/player_smoke.ps1`, Linux build/ELF/install/window
checks in `linux/packaging/README.md`, and macOS native build/bundle verification
on a macOS host. Python contract tests do not replace a native build or playback.
The desktop smoke observes the controller's actual external-subtitle download
and injects a delayed invalid response. Pause, seek, volume and superseding
selection must remain responsive, and the failed download must never add a
native subtitle. The separate native package test still exercises a real pending
libmpv `sub-add` timeout; these are distinct paths.
