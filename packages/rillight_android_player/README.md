# Rillight Android player

Owned Media3 ExoPlayer/HLS/UI **1.11.1** plugin, API 24+, compiled with API 36.
Android native code owns ExoPlayer and PlayerView. Dart owns controller/session
reporting. Desktop players do not initialize this plugin.

## Consumer contract

Use `AndroidVideoBackend` from `lib/player/android_video_backend.dart` with the
existing `PlayerController` and a platform-neutral `PlayerWindow`. Mount
`backend.buildView()` **while loading**, with bounded constraints, below Flutter
controls in a Stack. `open` waits for native ready and the first video frame;
waiting until loading finishes to mount the view would prevent readiness.
The platform view explicitly uses hybrid composition, disables native controls
and does not accept TV focus. Keep the backend instance stable across rebuilds.

The application Activity uses `RenderMode.texture` with its normal opaque
background; Impeller remains enabled. With Flutter 3.47.4, API 36 x86_64
SwiftShader phone emulators reproduced `EGL_BAD_ACCESS (12290)` and a black
Flutter screen after playback route exit followed by screen lock/unlock when
the host used the default SurfaceView. A minimal native view with a Flutter
overlay reproduced it independently of authentication and PlayerController.
TextureView avoids that host surface transition. This is a compatibility
workaround, not a proven engine root-cause fix; physical-device GPU stability
and performance still need separate validation before changing this policy.

`VideoOpenRequest.mediaStreams` supplies server stream metadata. Native mapping
uses media type, unique language and container order; differing track counts
fail explicitly. Server indices never directly address Media3 groups. A track
command succeeds only after native selection confirmation. External SRT/WebVTT
files must be inside application-private storage; PlayerController downloads
them with origin-scoped authorization and bounded redirects. Malformed or
unsupported subtitles fail independently of video playback.

For HLS transcodes, `MediaStreamInfo.deliveryMethod` and `deliveryUrl` preserve
PlaybackInfo's delivery contract: External downloads and awaits native selection,
Hls/Embed maps the manifest track, and Encode keeps server burn-in. Missing
delivery metadata follows the Android advertised SRT/WebVTT External profile.
Only confirmed selections update controller state and playback reports. Desktop
backends keep their existing server burn-in behavior.

`VideoBackendCapabilities.deviceProfile` injects runtime H.264/AAC availability,
8-bit/1080p/stereo constraints and a 20 Mbps ceiling into PlaybackInfo. Unsupported
decoders are not advertised. A direct decoder/container failure permits one HLS
compatibility attempt; a missing server transcode remains a visible error.

Android hosts call `controller.suspendPlayback()` on a true background transition
and `restorePlayback()` on return. These release native resources, end the old
reporting session with existing deadlines, preserve position, verify credentials
and reopen paused with a new native session. Rotation/layout changes only rebind
the view. Hosts still own route lifecycle and snapshot recovery at app startup.
Native audio-focus loss and headphone removal pause playback; returning focus
does not resume. Keep-screen-on follows actual native playback. Native 401/403
emits `authenticationRequired`; the controller stops the connection and exposes
`sessionExpired`. All commands/events preserve a unique owner/session token.

Native HTTP requests explicitly handle redirects. Credential headers are sent
only to the original scheme/host/port, including HLS child resources; cross-origin
URLs strip Emby token parameters. TLS validation remains enabled. HTTPS-to-HTTP
redirects fail. Local files do not bypass the external-subtitle private-path check.

## Development checks

From the app root:

```sh
flutter test packages/rillight_android_player/test test/player/android_video_backend_test.dart
cd android
./gradlew :rillight_android_player:testDebugUnitTest
```

The reproducible isolated wrapper is `python tool/android_release_checks.py
--all-targets`; prerequisites and evidence interpretation are in
[`integration_test/android/README.md`](../../integration_test/android/README.md).
It uses a disposable `.validation` package and restores the normal APK. Generated
protobuf clients/media/evidence stay in ignored `build/`. The real-device
entrypoint is `integration_test/android_player_smoke.dart`.
Prepare `android-tracks.mkv` (H.264, two AAC tracks tagged eng/zho, one SRT track
tagged eng, at least 60 seconds) and `stream.m3u8` plus its H.264/AAC TS segments
in an isolated directory. It does not use a real account or media collection.
For example, use FFmpeg testsrc2 and two sine inputs; mux a synthetic SRT file.

```sh
python packages/rillight_android_player/tool/smoke_server.py build/player-validation/media
adb -s emulator-5554 reverse tcp:8765 tcp:8765
adb -s emulator-5554 reverse tcp:8766 tcp:8766
flutter build apk --debug -t integration_test/android_player_smoke.dart --android-project-arg=rillightValidation=true --dart-define=ANDROID_SMOKE_HOLD_SECONDS=30
adb -s emulator-5554 install --no-streaming -r build/app/outputs/flutter-apk/app-debug.apk
adb -s emulator-5554 logcat -c
adb -s emulator-5554 shell am force-stop com.rillight.rillight.validation
adb -s emulator-5554 shell am start -n com.rillight.rillight.validation/com.rillight.rillight.MainActivity
adb -s emulator-5554 logcat -s flutter
```

Require `RILLIGHT_ANDROID_SMOKE_PASS` within 120 seconds. A FAIL marker, process
failure or missing terminal marker is failure. The native smoke checks real
readiness, pause/seek, both audio tracks, embedded/external subtitle selection,
view reconnection, paused reopening, HLS, cross-origin credential isolation,
401, missing media, and retry. `/__checks` on the fixture exposes request counts
and credential-leak count without logging tokens. The smoke requires leak count
zero and observed requests to both origins before reporting success.

Capture screenshots/recording during embedded-subtitle, external-srt,
external-vtt and surface-reconnected-audio-capture stages. Inspect changing
video pixels and subtitle text, then separately capture actual or emulator
virtual audio. Native callbacks and position alone do not prove displayed frames
or audible output. An emulator result does not establish physical speaker output,
hardware decode performance or long-running GPU stability. After smoke, rebuild
the normal app with `flutter build apk --debug` before installing for normal use.

To isolate the shared-controller HLS/external-subtitle regression, place
`sample.srt` and `sample.vtt` beside the HLS fixture with visible synthetic text
covering the entire clip, leave `missing-subtitle.srt` absent, and build with
`--dart-define=ANDROID_SMOKE_HLS_SUBTITLES_ONLY=true`. This branch uses synthetic
PlaybackInfo metadata with real authenticated HTTP downloads and real Media3;
it checks SRT, WebVTT, failed switching preserving the selected subtitle, and
subtitles off. Capture the `hls-controller-external-srt`,
`hls-controller-external-vtt`, and `hls-controller-failure-preserved-vtt` stages.
Require the same PASS marker and inspect the actual subtitle pixels separately.
