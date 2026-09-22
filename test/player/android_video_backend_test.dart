import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/player/android_video_backend.dart';
import 'package:rillight/player/playback_models.dart';
import 'package:rillight/player/video_backend.dart';
import 'package:rillight_android_player/rillight_android_player.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('android-backend-test');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  for (final stale in {
    'position': 90000,
    'playing': true,
    'error': 'old media failed',
    'authenticationRequired': 401,
  }.entries) {
    test(
      'queued ${stale.key} cannot cross the adapter microtask handoff',
      () async {
        final source = StreamController<dynamic>.broadcast();
        final player = AndroidPlayer(channel: channel, events: source.stream);
        final backend = AndroidVideoBackend(player: player);
        messenger.setMockMethodCallHandler(
          channel,
          (call) async => {'sessionId': (call.arguments as Map)['sessionId']},
        );
        final received = <VideoBackendEvent>[];
        final sub = backend.events.listen(received.add);
        await backend.open(
          VideoOpenRequest(sessionId: 1, url: Uri.parse('https://test/old')),
        );
        source.add({
          'owner': player.owner,
          'sessionId': player.session,
          'kind': stale.key,
          'value': stale.value,
        });
        final next = Completer<void>();
        scheduleMicrotask(() {
          backend
              .open(
                VideoOpenRequest(
                  sessionId: 2,
                  url: Uri.parse('https://test/new'),
                  start: const Duration(seconds: 5),
                ),
              )
              .then(next.complete, onError: next.completeError);
        });
        await next.future;
        await Future<void>.delayed(Duration.zero);
        expect(received, isEmpty);
        expect(backend.position, const Duration(seconds: 5));
        expect(backend.isPlaying, isFalse);
        await backend.dispose();
        await sub.cancel();
        await source.close();
      },
    );
  }
  test(
    'open remains unready until native reply; maps tracks and stops late events',
    () async {
      final source = StreamController<dynamic>.broadcast();
      final opened = Completer<Map>();
      final player = AndroidPlayer(channel: channel, events: source.stream);
      final backend = AndroidVideoBackend(player: player);
      Map<dynamic, dynamic>? request;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'open') {
          request = call.arguments as Map;
          return opened.future;
        }
        return {'sessionId': player.session, 'audioIndex': 19};
      });
      final events = <VideoBackendEvent>[];
      final sub = backend.events.listen(events.add);
      var ready = false;
      final pending = backend
          .open(
            VideoOpenRequest(
              sessionId: 42,
              url: Uri.parse('https://test/media'),
              mediaStreams: const [MediaStreamInfo(index: 19, type: 'Audio')],
            ),
          )
          .then((_) => ready = true);
      await Future<void>.delayed(Duration.zero);
      expect(ready, isFalse);
      expect(backend.isPlaying, isFalse);
      expect((request!['streams'] as List).single['index'], 19);
      source.add({
        'owner': player.owner,
        'sessionId': player.session,
        'kind': 'position',
        'value': 1250,
      });
      source.add({
        'owner': player.owner,
        'sessionId': player.session,
        'kind': 'playing',
        'value': true,
      });
      opened.complete({'sessionId': player.session, 'audioIndex': 19});
      await pending;
      await Future<void>.delayed(Duration.zero);
      expect(backend.position, const Duration(milliseconds: 1250));
      expect(events.every((e) => e.sessionId == 42), isTrue);
      expect(backend.selectedAudioIndex, 19);
      await backend.stop();
      source.add({
        'owner': player.owner,
        'sessionId': player.session,
        'kind': 'playing',
        'value': true,
      });
      await Future<void>.delayed(Duration.zero);
      expect(backend.isPlaying, isFalse);
      await backend.stop();
      await backend.dispose();
      await backend.dispose();
      await sub.cancel();
      await source.close();
    },
  );
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));
}
