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

`VideoOpenRequest.mediaStreams` supplies server stream metadata. Native mapping
uses media type, unique language and container order; differing track counts
fail explicitly. Server indices never directly address Media3 groups. A track
command succeeds only after native selection confirmation. External SRT/WebVTT
files must be inside application-private storage; PlayerController downloads
them with origin-scoped authorization and bounded redirects. Malformed or
unsupported subtitles fail independently of video playback.

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

The real-device entrypoint is `integration_test/android_player_smoke.dart`.
Prepare `android-tracks.mkv` (H.264, two AAC tracks tagged eng/zho, one SRT track
tagged eng, at least 60 seconds) and `stream.m3u8` plus its H.264/AAC TS segments
in an isolated directory. It does not use a real account or media collection.
For example, use FFmpeg testsrc2 and two sine inputs; mux a synthetic SRT file.

```sh
python packages/rillight_android_player/tool/smoke_server.py build/player-validation/media
adb -s emulator-5554 reverse tcp:8765 tcp:8765
adb -s emulator-5554 reverse tcp:8766 tcp:8766
flutter build apk --debug -t integration_test/android_player_smoke.dart --dart-define=ANDROID_SMOKE_HOLD_SECONDS=30
adb -s emulator-5554 install --no-streaming -r build/app/outputs/flutter-apk/app-debug.apk
adb -s emulator-5554 logcat -c
adb -s emulator-5554 shell am force-stop com.rillight.rillight
adb -s emulator-5554 shell am start -n com.rillight.rillight/.MainActivity
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
