import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight_player/rillight_player.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final library = Platform.environment['RILLIGHT_TEST_MPV'];
  final media = Platform.environment['RILLIGHT_TEST_MEDIA'];
  final unavailable = library == null || media == null;

  Future<MpvPlayer> create() => MpvPlayer.create(
    libraryPath: library,
    video: false,
    options: {'vo': 'null', 'ao': 'null', 'keep-open': 'no'},
  );

  test(
    'nonblocking surfaces enforce zero early video presentation offset',
    () async {
      final player = await MpvPlayer.create(
        libraryPath: library,
        video: false,
        options: {'vo': 'null', 'ao': 'null', 'video-timing-offset': '0.05'},
      );
      addTearDown(player.dispose);
      expect(await player.getProperty('video-timing-offset'), 0);
      expect(await player.getProperty('video-sync'), 'audio');
    },
    skip: unavailable,
  );

  test(
    'preload surface notifications do not claim a video first frame',
    () async {
      const channel = MethodChannel('rillight_player');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'create') return 42;
        if (call.method == 'detach') return false;
        if (call.method == 'status') return {'frames': 1, 'error': ''};
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final player = await MpvPlayer.create(
        libraryPath: library,
        options: {'vo': 'null', 'ao': 'null'},
      );
      final events = <MpvEvent>[];
      final subscription = player.events.listen(events.add);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(events.where((event) => event.type == 'first-frame'), isEmpty);
      final firstFrame = player.events.firstWhere(
        (event) => event.type == 'first-frame',
      );
      await player.command(['loadfile', media!, 'replace']);
      await firstFrame.timeout(const Duration(seconds: 5));
      await subscription.cancel();
      await player.dispose();
    },
    skip: unavailable,
  );

  test(
    'failed native surface creation requests cleanup before core shutdown',
    () async {
      final calls = <String>[];
      const channel = MethodChannel('rillight_player');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        if (call.method == 'create') {
          throw PlatformException(code: 'render-create');
        }
        if (call.method == 'detach') return false;
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await expectLater(
        MpvPlayer.create(
          libraryPath: library,
          options: {'vo': 'null', 'ao': 'null'},
        ),
        throwsA(isA<PlatformException>()),
      );
      expect(calls, ['create', if (Platform.isLinux) 'detach', 'dispose']);
      final player = await create();
      await player.dispose();
    },
    skip: unavailable,
  );

  test(
    'missing library and invalid option fail creation without a dangling core',
    () async {
      await expectLater(
        MpvPlayer.create(libraryPath: '${library!}.missing', video: false),
        throwsStateError,
      );
      for (var i = 0; i < 3; i++) {
        await expectLater(
          MpvPlayer.create(
            libraryPath: library,
            video: false,
            options: {'not-a-real-option': 'yes'},
          ),
          throwsStateError,
        );
        final player = await create();
        expect(player.nativeVersion, contains('0.41.'));
        await player.dispose();
      }
    },
    skip: unavailable,
  );

  test(
    'real libmpv replies correlate, tracks are copied, and seek is async',
    () async {
      final player = await create();
      addTearDown(player.dispose);
      await player.setProperty('pause', 'yes');
      final loaded = player.events.firstWhere(
        (event) => event.type == 'file-loaded',
      );
      await player.command(['loadfile', media!, 'replace']);
      await loaded.timeout(const Duration(seconds: 5));
      final replies = await Future.wait([
        player.getProperty('duration'),
        player.getProperty('pause'),
        player.getProperty('track-list'),
      ]);
      expect(replies[0], isA<num>());
      expect(replies[1], true);
      expect(replies[2], isA<List>());
      expect(
        (replies[2] as List).any((track) => (track as Map)['type'] == 'video'),
        true,
      );
      await player.command(['seek', '3', 'absolute+exact']);
      await expectLater(
        player.command(['this-command-does-not-exist']),
        throwsStateError,
      );
    },
    skip: unavailable,
  );

  test(
    'load acceptance is not file-loaded; failed file has an error end event',
    () async {
      final player = await create();
      addTearDown(player.dispose);
      final events = <MpvEvent>[];
      final subscription = player.events.listen(events.add);
      addTearDown(subscription.cancel);
      final ended = player.events.firstWhere(
        (event) => event.type == 'end-file',
      );
      await player.command(['loadfile', '${media!}.missing', 'replace']);
      final event = await ended.timeout(const Duration(seconds: 5));
      expect((event.value as Map)['reason'], 4);
      expect((event.value as Map)['error'], lessThan(0));
      expect(events.where((event) => event.type == 'file-loaded'), isEmpty);
    },
    skip: unavailable,
  );

  test(
    'natural EOF differs from stop and repeated disposal is awaitable',
    () async {
      final player = await create();
      final ended = player.events.firstWhere(
        (event) => event.type == 'end-file',
      );
      await player.setProperty('speed', '100');
      await player.command(['loadfile', media!, 'replace']);
      expect(
        ((await ended.timeout(const Duration(seconds: 10))).value
            as Map)['reason'],
        0,
      );
      final first = player.dispose();
      expect(identical(first, player.dispose()), true);
      await first;
      await expectLater(player.getProperty('duration'), throwsStateError);
    },
    skip: unavailable,
  );

  test(
    'stop and dispose interrupt a media load without waiting for HTTP',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requests = <HttpRequest>[];
      final subscription = server.listen(requests.add);
      final player = await create();
      await player.command([
        'loadfile',
        'http://127.0.0.1:${server.port}/never.mp4',
      ]);
      await player.stop().timeout(const Duration(seconds: 3));
      await player.dispose().timeout(const Duration(seconds: 3));
      await subscription.cancel();
      await server.close(force: true);
    },
    skip: unavailable,
  );
}
