import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/player/rillight_video_backend.dart';
import 'package:rillight/player/video_backend.dart';
import 'package:rillight_player/rillight_player.dart';

class _RealHttp extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'Android seek leaves old HTTP reads alive until native timeline changes',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        const channel = MethodChannel('rillight/android_core');
        const events = MethodChannel('rillight/android_core/events');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        final cache = await Directory.systemTemp.createTemp('android-seek-');
        final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final reading = Completer<void>();
        final release = Completer<void>();
        upstream.listen((request) async {
          if (!reading.isCompleted) reading.complete();
          await release.future;
          await request.response.close();
        });
        final client = HttpClient();
        Uri? route;
        int? cancelledAtNativeSeek;
        late RillightVideoBackend backend;
        messenger.setMockMethodCallHandler(events, (_) async => null);
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'open') {
            route = Uri.parse((call.arguments as Map)['url'] as String);
          }
          if (call.method == 'seek') {
            cancelledAtNativeSeek =
                (await backend.diagnostics())['cancelledReads'] as int;
          }
          return <String, Object?>{};
        });
        backend = RillightVideoBackend(
          diskCacheDirectory: cache,
          settingsStore: MemoryPlayerSettingsStore(),
          createPlayer: () async => AndroidCorePlayer(),
        );
        Future<void>? pending;
        try {
          await backend.open(
            VideoOpenRequest(
              sessionId: 1,
              url: Uri.parse('http://127.0.0.1:${upstream.port}/media'),
            ),
          );
          pending = client
              .getUrl(route!)
              .then((request) async {
                final response = await request.close();
                await response.drain<void>();
              })
              .catchError((Object _) {});
          await reading.future.timeout(const Duration(seconds: 5));
          expect((await backend.diagnostics())['cancelledReads'], 0);
          await backend.seek(const Duration(minutes: 5));
          expect(
            cancelledAtNativeSeek,
            0,
            reason: 'Only native seek may cancel the old timeline HTTP read',
          );
        } finally {
          release.complete();
          client.close(force: true);
          await pending;
          await backend.dispose();
          await upstream.close(force: true);
          messenger.setMockMethodCallHandler(channel, null);
          messenger.setMockMethodCallHandler(events, null);
          await cache.delete(recursive: true);
        }
      }, _RealHttp());
    },
  );
}
