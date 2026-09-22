// Real Media3 smoke entrypoint. Build with -t and ANDROID_SMOKE_BASE; failures
// emit RILLIGHT_ANDROID_SMOKE_FAIL, never the success marker. Host tooling must
// separately inspect displayed frames/audio; position is not output evidence.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:rillight/player/android_video_backend.dart';
import 'package:rillight/player/playback_models.dart';
import 'package:rillight/player/video_backend.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(home: _Smoke()));
}

class _Smoke extends StatefulWidget {
  const _Smoke();
  @override
  State<_Smoke> createState() => _SmokeState();
}

class _SmokeState extends State<_Smoke> {
  final backend = AndroidVideoBackend();
  String stage = 'starting';
  bool showView = true;
  int firstFrames = 0;
  int authenticationFailures = 0;
  final errors = <String>[];
  Uri? localMedia;
  late final StreamSubscription<Map<String, dynamic>> native;
  late final StreamSubscription<String> errorSubscription;
  final base = Uri.parse(
    const String.fromEnvironment(
      'ANDROID_SMOKE_BASE',
      defaultValue: 'http://127.0.0.1:8765/',
    ),
  );
  void record(String value) {
    if (mounted) setState(() => stage = value);
    debugPrint(
      'RILLIGHT_ANDROID_SMOKE ${jsonEncode({'stage': value, 'positionMs': backend.position.inMilliseconds, 'durationMs': backend.duration.inMilliseconds, 'frames': firstFrames})}',
    );
  }

  void check(bool condition, String message) {
    if (!condition) throw StateError(message);
  }

  Future<void> waitFor(bool Function() condition, String message) async {
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) throw StateError(message);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  VideoOpenRequest request(
    int id, {
    String file = 'android-tracks.mkv',
    bool paused = false,
  }) => VideoOpenRequest(
    sessionId: id,
    url: file == 'android-tracks.mkv'
        ? localMedia ?? base.resolve(file)
        : base.resolve(file),
    credentialOrigin: base,
    credentialHeaders: const {'X-Emby-Token': 'synthetic-android-smoke'},
    startPaused: paused,
    mediaStreams: const [
      MediaStreamInfo(index: 8, type: 'Video', codec: 'h264'),
      MediaStreamInfo(index: 11, type: 'Audio', codec: 'aac', language: 'eng'),
      MediaStreamInfo(index: 19, type: 'Audio', codec: 'aac', language: 'zho'),
      MediaStreamInfo(
        index: 27,
        type: 'Subtitle',
        codec: 'srt',
        language: 'eng',
      ),
    ],
  );
  @override
  void initState() {
    super.initState();
    native = backend.nativeEvents.listen((event) {
      if (event['kind'] == 'firstFrame') firstFrames++;
      if (event['kind'] == 'authenticationRequired') authenticationFailures++;
    });
    errorSubscription = backend.errorStream.listen(errors.add);
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(run()));
  }

  Future<void> run() async {
    try {
      if (const bool.fromEnvironment('ANDROID_SMOKE_LOCAL')) {
        final http = HttpClient();
        final download = await http.getUrl(base.resolve('android-tracks.mkv'));
        download.headers.set('X-Emby-Token', 'synthetic-android-smoke');
        final response = await download.close();
        final file = File(
          '${Directory.systemTemp.path}/android-smoke-local.mkv',
        );
        await response.pipe(file.openWrite());
        http.close();
        localMedia = file.uri;
      }
      final profile = await backend.deviceProfile(8000000);
      check(
        (profile['DirectPlayProfiles'] as List).isNotEmpty,
        'Baseline decoder missing',
      );
      await backend.open(request(1));
      check(firstFrames > 0, 'open completed without actual first frame');
      await waitFor(
        () => backend.position > const Duration(seconds: 1),
        'Playback did not advance',
      );
      await backend.setAudioIndex(19);
      check(backend.selectedAudioIndex == 19, 'Second audio was not selected');
      await backend.setAudioIndex(11);
      check(backend.selectedAudioIndex == 11, 'First audio was not selected');
      await backend.setSubtitleIndex(27);
      check(
        backend.selectedSubtitleIndex == 27,
        'Embedded subtitle was not selected',
      );
      record('embedded-subtitle');
      await Future<void>.delayed(const Duration(seconds: 3));
      await backend.pause();
      await waitFor(() => !backend.isPlaying, 'Pause did not settle');
      final paused = backend.position;
      await Future<void>.delayed(const Duration(milliseconds: 600));
      check(
        (backend.position - paused).abs() < const Duration(milliseconds: 300),
        'Pause position advanced',
      );
      await backend.seek(const Duration(seconds: 4));
      await waitFor(
        () =>
            (backend.position - const Duration(seconds: 4)).abs() <
            const Duration(milliseconds: 500),
        'Seek did not settle',
      );
      final directory = await Directory.systemTemp.createTemp(
        'android-subtitle-smoke-',
      );
      final srt = File('${directory.path}/smoke.srt');
      await srt.writeAsString(
        '1\n00:00:00,000 --> 00:01:00,000\nANDROID EXTERNAL SRT\n',
      );
      await backend.setSubtitleUri(srt.uri, title: 'SRT');
      await backend.play();
      record('external-srt');
      await Future<void>.delayed(const Duration(seconds: 3));
      final vtt = File('${directory.path}/smoke.vtt');
      await vtt.writeAsString(
        'WEBVTT\n\n00:00.000 --> 01:00.000\nANDROID EXTERNAL WEBVTT\n',
      );
      await backend.setSubtitleUri(vtt.uri, title: 'WebVTT');
      record('external-vtt');
      await Future<void>.delayed(const Duration(seconds: 3));
      var invalidFailed = false;
      try {
        await backend.setAudioIndex(999);
      } catch (_) {
        invalidFailed = true;
      }
      check(invalidFailed, 'Invalid audio selection falsely succeeded');
      final invalid = File('${directory.path}/invalid.srt');
      await invalid.writeAsString('<html>not subtitles</html>');
      invalidFailed = false;
      try {
        await backend.setSubtitleUri(invalid.uri);
      } catch (_) {
        invalidFailed = true;
      }
      check(invalidFailed, 'Invalid subtitle falsely succeeded');
      check(errors.isEmpty, 'Track error poisoned video playback: $errors');
      await backend.setSubtitleOff();
      await backend.seek(Duration.zero);
      final framesBeforeRebind = firstFrames;
      setState(() => showView = false);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      setState(() => showView = true);
      await waitFor(
        () => firstFrames > framesBeforeRebind,
        'Surface did not reconnect',
      );
      record('surface-reconnected-audio-capture');
      // Host can capture emulator virtual audio and displayed changing frames.
      await Future<void>.delayed(
        const Duration(
          seconds: int.fromEnvironment(
            'ANDROID_SMOKE_HOLD_SECONDS',
            defaultValue: 10,
          ),
        ),
      );
      await backend.stop();
      await backend.stop();
      record('restoring-paused-session');
      await backend.open(request(2, paused: true));
      check(!backend.isPlaying, 'Restored session auto-played');
      await backend.play();
      await waitFor(() => backend.isPlaying, 'Restore could not resume');
      await backend.stop();
      record('opening-hls');
      await backend.open(request(3, file: 'stream.m3u8'));
      record('hls-ready');
      await Future<void>.delayed(const Duration(seconds: 2));
      await backend.stop();
      await backend.open(request(31, file: 'redirect.mkv'));
      record('cross-origin-redirect-ready');
      await backend.stop();
      await backend.open(request(32, file: 'cross-origin.m3u8'));
      record('cross-origin-hls-ready');
      await Future<void>.delayed(const Duration(seconds: 2));
      await backend.stop();
      invalidFailed = false;
      try {
        await backend.open(request(33, file: 'unauthorized.mp4'));
      } catch (_) {
        invalidFailed = true;
      }
      check(invalidFailed, 'Unauthorized media falsely succeeded');
      await waitFor(
        () => authenticationFailures > 0,
        '401 did not request authentication',
      );
      await backend.stop();
      invalidFailed = false;
      try {
        await backend.open(request(4, file: 'missing.mp4'));
      } catch (_) {
        invalidFailed = true;
      }
      check(invalidFailed, 'Missing media falsely succeeded');
      await backend.stop();
      await backend.open(request(5));
      await waitFor(() => backend.isPlaying, 'Failed session poisoned retry');
      await backend.dispose();
      await backend.dispose();
      final http = HttpClient();
      final response = await (await http.getUrl(
        base.resolve('__checks'),
      )).close();
      final checks =
          jsonDecode(await response.transform(utf8.decoder).join()) as Map;
      http.close();
      check(
        checks['leaks'] == 0 &&
            (checks['cross_origin'] as int) > 0 &&
            (checks['authorized'] as int) > 0,
        'Native HTTP credential checks failed',
      );
      record('RILLIGHT_ANDROID_SMOKE_PASS');
    } catch (error, stack) {
      record('RILLIGHT_ANDROID_SMOKE_FAIL: $error');
      debugPrintStack(stackTrace: stack);
      await backend.dispose();
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    body: Stack(
      children: [
        if (showView) Positioned.fill(child: backend.buildView()),
        Positioned(
          top: 35,
          left: 20,
          child: ColoredBox(
            color: Colors.black87,
            child: Text(
              stage,
              style: const TextStyle(color: Colors.white, fontSize: 16),
            ),
          ),
        ),
      ],
    ),
  );
  @override
  void dispose() {
    unawaited(native.cancel());
    unawaited(errorSubscription.cancel());
    unawaited(backend.dispose());
    super.dispose();
  }
}
